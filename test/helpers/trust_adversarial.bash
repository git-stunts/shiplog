#!/usr/bin/env bash
# Helpers for test/27_trust_adversarial.bats.
#
# These build hostile and legitimate trust/policy commits by hand so the tests
# do not depend on the CLI's own (possibly buggy) trust tooling. The attestation
# payload is computed exactly the way scripts/shiplog-verify-trust.sh and the
# hook fallback compute it:
#
#   shiplog-trust-tree-v2\n<base_tree_oid>\n<trust_id>\n<threshold>\n<prior_oid>\n
#
# where <base_tree_oid> is the tree holding only trust.json and allowed_signers
# and <prior_oid> is the trust commit being replaced (zero OID at genesis).
#
# Conventions:
#   - Keys are named (A, B, C, K ...) and live under $ADV_KEYS_DIR/<name>/id_ed25519.
#   - Principals are e-mails; the roster maps principal -> key name.
#   - All functions print their result on stdout and return non-zero on failure.

ADV_ZERO_OID="0000000000000000000000000000000000000000"
ADV_TRUST_REF="refs/_shiplog/trust/root"
ADV_POLICY_REF="refs/_shiplog/policy/current"
ADV_TRUST_ID="shiplog-trust-root"
ADV_TAB=$'\t'

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

adv_keys_init() {
  ADV_KEYS_DIR="$(mktemp -d)"
  export ADV_KEYS_DIR
}

adv_keys_cleanup() {
  if [ -n "${ADV_KEYS_DIR:-}" ] && [ -d "$ADV_KEYS_DIR" ]; then
    rm -rf "$ADV_KEYS_DIR"
  fi
  unset ADV_KEYS_DIR
}

# adv_keygen <name> [comment]
adv_keygen() {
  local name="$1" comment="${2:-$1}"
  mkdir -p "$ADV_KEYS_DIR/$name"
  ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$ADV_KEYS_DIR/$name/id_ed25519"
}

# adv_key_priv <name> -> path to private key
adv_key_priv() {
  printf '%s' "$ADV_KEYS_DIR/$1/id_ed25519"
}

# adv_key_pub <name> -> "ssh-ed25519 AAAA..."
adv_key_pub() {
  ssh-keygen -y -f "$(adv_key_priv "$1")"
}

# adv_signers_line <principal> <keyname> -> one allowed_signers line
adv_signers_line() {
  printf '%s %s\n' "$1" "$(adv_key_pub "$2")"
}

# adv_signers <principal=keyname>... -> a complete allowed_signers document
adv_signers() {
  local spec
  for spec in "$@"; do
    adv_signers_line "${spec%%=*}" "${spec#*=}"
  done
}

# adv_use_signing_key <keyname>
# Configure the current (client) repo to sign commits with this SSH key.
adv_use_signing_key() {
  git config gpg.format ssh
  git config user.signingkey "$(adv_key_priv "$1")"
}

# ---------------------------------------------------------------------------
# Documents
# ---------------------------------------------------------------------------

# adv_trust_json <threshold> <sig_mode|-> <maintainer...>
# A maintainer is "email" or "email:revoked". Pass "-" as sig_mode to omit it
# (the verifier then defaults to chain mode).
adv_trust_json() {
  local threshold="$1" sig_mode="$2"
  shift 2
  local spec email revoked maintainers='[]'
  for spec in "$@"; do
    email="${spec%%:*}"
    revoked=false
    case "$spec" in
      *:revoked) revoked=true ;;
    esac
    maintainers=$(jq -c --arg e "$email" --argjson r "$revoked" \
      '. + [{name: $e, email: $e, role: "root", revoked: $r}]' <<<"$maintainers")
  done
  jq -n --argjson t "$threshold" --arg mode "$sig_mode" --argjson m "$maintainers" --arg id "$ADV_TRUST_ID" '
    {version: 1, id: $id, threshold: $t, maintainers: $m}
    + (if $mode == "-" then {} else {sig_mode: $mode} end)
  '
}

# adv_policy_json <require_signed:true|false> [author...]
adv_policy_json() {
  local rs="$1"
  shift
  local authors='[]' a
  for a in "$@"; do
    authors=$(jq -c --arg a "$a" '. + [$a]' <<<"$authors")
  done
  jq -n --argjson rs "$rs" --argjson a "$authors" \
    '{version: "1.0.0", require_signed: $rs, authors: {default_allowlist: $a}}'
}

# ---------------------------------------------------------------------------
# Attestations
# ---------------------------------------------------------------------------

# adv_base_tree <trust_blob_oid> <signers_blob_oid> -> tree oid
adv_base_tree() {
  printf "100644 blob %s${ADV_TAB}trust.json\n100644 blob %s${ADV_TAB}allowed_signers\n" "$1" "$2" | git mktree
}

# adv_attest_payload <base_tree> <trust_id> <threshold> [prior_oid]
adv_attest_payload() {
  printf 'shiplog-trust-tree-v2\n%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "${4:-$ADV_ZERO_OID}"
}

# adv_attest_sign <keyname> <base_tree> <trust_id> <threshold> [prior_oid] -> signature blob oid
adv_attest_sign() {
  local key="$1" tmp
  tmp="$(mktemp)"
  adv_attest_payload "$2" "$3" "$4" "${5:-}" >"$tmp"
  if ! ssh-keygen -Y sign -q -f "$(adv_key_priv "$key")" -n shiplog-trust "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp" "$tmp.sig"
    echo "ERROR: ssh-keygen -Y sign failed for key $key" >&2
    return 1
  fi
  git hash-object -w "$tmp.sig"
  rm -f "$tmp" "$tmp.sig"
}

# ---------------------------------------------------------------------------
# Commits
# ---------------------------------------------------------------------------

# adv_commit_tree <tree> <parent|""> <sign_keyname|""> <message> [email]
# Unsigned commits pass --no-gpg-sign so a global commit.gpgsign cannot sneak a
# signature in (the signing CI matrix sets it).
adv_commit_tree() {
  local tree="$1" parent="$2" sign_key="$3" msg="$4" email="${5:-trust@shiplog.test}"
  local -a cmd=(git)
  if [ -n "$sign_key" ]; then
    cmd+=(-c gpg.format=ssh -c "user.signingkey=$(adv_key_priv "$sign_key")")
  fi
  cmd+=(commit-tree "$tree")
  if [ -n "$parent" ]; then
    cmd+=(-p "$parent")
  fi
  if [ -n "$sign_key" ]; then
    cmd+=(-S)
  else
    cmd+=(--no-gpg-sign)
  fi
  cmd+=(-m "$msg")
  GIT_AUTHOR_NAME="Shiplog Adversarial" GIT_AUTHOR_EMAIL="$email" \
  GIT_COMMITTER_NAME="Shiplog Adversarial" GIT_COMMITTER_EMAIL="$email" \
    "${cmd[@]}"
}

# adv_assert_commit_signed <commit>
# Fails unless the commit object carries a gpgsig header (any format).
adv_assert_commit_signed() {
  if ! git cat-file commit "$1" | grep -q '^gpgsig '; then
    echo "ERROR: commit $1 carries no signature" >&2
    return 1
  fi
}

# adv_trust_commit [-p parent] [-S keyname] [-e author_email] [-m msg]
#                  [--sig principal=keyname]... [--sig-blob principal=oid]...
#                  <trust_json> <allowed_signers_text>
# Builds the trust tree (trust.json, allowed_signers, optional
# .shiplog/trust_sigs/<principal>.sig) and prints the commit oid.
# --sig signs the canonical payload (prior = the -p parent, or the zero OID) with the named key.
# --sig-blob stores an arbitrary pre-made blob under that principal's name.
adv_trust_commit() {
  local parent="" sign_key="" msg="shiplog: trust update" email=""
  local -a sigs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) parent="$2"; shift 2 ;;
      -S) sign_key="$2"; shift 2 ;;
      -e) email="$2"; shift 2 ;;
      -m) msg="$2"; shift 2 ;;
      --sig|--sig-blob) sigs+=("$2"); shift 2 ;;
      *) break ;;
    esac
  done
  local trust_json="$1" signers="$2"
  local oid_trust oid_sigs base trust_id threshold root_tree
  oid_trust=$(printf '%s\n' "$trust_json" | git hash-object -w --stdin)
  oid_sigs=$(printf '%s' "$signers" | git hash-object -w --stdin)
  base=$(adv_base_tree "$oid_trust" "$oid_sigs")
  trust_id=$(jq -r '.id // "shiplog-trust-root"' <<<"$trust_json")
  threshold=$(jq -r '.threshold // 1' <<<"$trust_json")

  if [ "${#sigs[@]}" -eq 0 ]; then
    root_tree="$base"
  else
    local entries="" spec principal key oid ts_tree dot_tree
    for spec in "${sigs[@]}"; do
      principal="${spec%%=*}"
      key="${spec#*=}"
      if [[ "$key" =~ ^[0-9a-f]{40}$ ]] || [[ "$key" =~ ^[0-9a-f]{64}$ ]]; then
        oid="$key"
      else
        oid=$(adv_attest_sign "$key" "$base" "$trust_id" "$threshold" "${parent:-$ADV_ZERO_OID}") || return 1
      fi
      entries+="100644 blob ${oid}${ADV_TAB}${principal}.sig"$'\n'
    done
    ts_tree=$(printf '%s' "$entries" | git mktree)
    dot_tree=$(printf "040000 tree %s${ADV_TAB}trust_sigs\n" "$ts_tree" | git mktree)
    root_tree=$(printf "100644 blob %s${ADV_TAB}trust.json\n100644 blob %s${ADV_TAB}allowed_signers\n040000 tree %s${ADV_TAB}.shiplog\n" \
      "$oid_trust" "$oid_sigs" "$dot_tree" | git mktree)
  fi

  if [ -z "$email" ]; then
    email=$(jq -r '.maintainers[0].email // "trust@shiplog.test"' <<<"$trust_json")
  fi
  adv_commit_tree "$root_tree" "$parent" "$sign_key" "$msg" "$email"
}

# adv_policy_commit [-p parent] [-S keyname] [-e email] [--empty] <policy_json>
# Builds a commit whose tree is .shiplog/policy.json (or an empty tree).
adv_policy_commit() {
  local parent="" sign_key="" empty=0 email="policy@shiplog.test"
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) parent="$2"; shift 2 ;;
      -S) sign_key="$2"; shift 2 ;;
      -e) email="$2"; shift 2 ;;
      --empty) empty=1; shift ;;
      *) break ;;
    esac
  done
  local json="${1:-}" tree blob sub
  if [ "$empty" -eq 1 ]; then
    tree=$(git mktree </dev/null)
  else
    blob=$(printf '%s\n' "$json" | git hash-object -w --stdin)
    sub=$(printf "100644 blob %s${ADV_TAB}policy.json\n" "$blob" | git mktree)
    tree=$(printf "040000 tree %s${ADV_TAB}.shiplog\n" "$sub" | git mktree)
  fi
  adv_commit_tree "$tree" "$parent" "$sign_key" "shiplog: policy update" "$email"
}

# ---------------------------------------------------------------------------
# Server side
# ---------------------------------------------------------------------------

# adv_install_hook <bare_repo_dir> [VAR=VALUE ...]
# Installs contrib/hooks/pre-receive.shiplog behind a bash wrapper. The wrapper
# hides the global git config (GIT_CONFIG_GLOBAL=/dev/null) so the server never
# has a gpg.ssh.allowedSignersFile unless the hook supplies one itself, pins
# SHIPLOG_HOME to the checkout under test, and exports any VAR=VALUE given.
adv_install_hook() {
  local remote="$1"
  shift
  local hook_source="${SHIPLOG_HOOK_PATH:-$SHIPLOG_PROJECT_ROOT/contrib/hooks/pre-receive.shiplog}"
  mkdir -p "$remote/hooks"
  cp "$hook_source" "$remote/hooks/pre-receive.real"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export GIT_CONFIG_GLOBAL=/dev/null\n'
    printf 'export SHIPLOG_HOME=%q\n' "$SHIPLOG_PROJECT_ROOT"
    printf 'export SHIPLOG_DEBUG_SSH_VERIFY=1\n'
    local kv
    for kv in "$@"; do
      printf 'export %q\n' "$kv"
    done
    printf 'exec bash "$0.real" "$@"\n'
  } >"$remote/hooks/pre-receive"
  chmod 0755 "$remote/hooks/pre-receive" "$remote/hooks/pre-receive.real"
}

# adv_remote_ref <bare_repo_dir> <ref> -> oid or empty
adv_remote_ref() {
  git --git-dir="$1" rev-parse -q --verify "$2" 2>/dev/null || true
}

# adv_server_signers_config <bare_repo_dir>
# Prints the bare repo's own gpg.ssh.allowedSignersFile setting (empty if none).
adv_server_signers_config() {
  git --git-dir="$1" config --get gpg.ssh.allowedSignersFile 2>/dev/null || true
}

# adv_fake_home_with_recording_verifier <sentinel_path> -> fake SHIPLOG_HOME dir
# Copies scripts/ and lib/ from the checkout and replaces the shared verifier
# with a wrapper that appends its argv to <sentinel_path> before running the
# real verifier. Used to prove the hook invoked the shared verifier.
adv_fake_home_with_recording_verifier() {
  local sentinel="$1" home
  home="$(mktemp -d)"
  cp -R "$SHIPLOG_PROJECT_ROOT/scripts" "$home/scripts"
  cp -R "$SHIPLOG_PROJECT_ROOT/lib" "$home/lib"
  chmod -R go-w "$home"
  mv "$home/scripts/shiplog-verify-trust.sh" "$home/scripts/shiplog-verify-trust.real"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> %q\n' "$sentinel"
    printf 'exec bash "$(dirname "${BASH_SOURCE[0]}")/shiplog-verify-trust.real" "$@"\n'
  } >"$home/scripts/shiplog-verify-trust.sh"
  chmod 0755 "$home/scripts/shiplog-verify-trust.sh" "$home/scripts/shiplog-verify-trust.real"
  printf '%s' "$home"
}
