# shellcheck shell=bash
# lib/trust-verify.sh — the one trust verification module.
#
# Sourced by:
#   - contrib/hooks/pre-receive.shiplog   (server-side enforcement)
#   - scripts/shiplog-verify-trust.sh     (CI / required-check verifier)
#   - scripts/shiplog-trust-sign.sh       (payload builder for attestations)
#   - scripts/shiplog-bootstrap-trust.sh  (genesis attestation)
#
# Rules implemented here (see docs/TRUST.md and ROADMAP.md decision D1):
#   * A trust update is verified against the PRIOR roster (OLD commit). Only the
#     genesis push (OLD = zero OID) is verified against its own content.
#   * Quorum counts distinct, unrevoked maintainer KEYS. Identity is the public
#     key that verified the signature (fingerprint), bound to a principal by
#     `ssh-keygen -Y find-principals`; the principal must name an unrevoked
#     maintainer in trust.json. Filenames and wildcard principals never count.
#   * sig_mode=attestation is the only N-of-M mode. sig_mode=chain means one
#     signed trust commit and supports threshold 1 only.
#   * SHIPLOG_REQUIRE_SIGNED_TRUST decides only whether the trust commit itself
#     must carry a maintainer signature; the quorum always applies.
#
# Contract: every public function returns non-zero on failure and prints a
# "❌ shiplog: ..." line to stderr. Nothing here calls exit. Callers set
# TRUST_VERIFY_TMP to a trap-cleaned directory, or call trust_verify_tmp_init
# and trust_verify_cleanup themselves.
#
# Dependencies: bash, git, jq (JQ_BIN or SHIPLOG_JQ_BIN), ssh-keygen (OpenSSH
# 8.2+ for -Y find-principals / verify).

TV_ZERO_OID="0000000000000000000000000000000000000000"
TV_NAMESPACE="${SHIPLOG_TRUST_NAMESPACE:-shiplog-trust}"
TV_SIG_DIR=".shiplog/trust_sigs"
TRUST_VERIFY_TMP="${TRUST_VERIFY_TMP:-}"
TRUST_VERIFY_LIB_VERSION="1"

# Outputs of trust_verify_load_trust_json
TV_TRUST_JSON=""
TV_THRESHOLD=""
TV_SIG_MODE=""
TV_TRUST_ID=""

tv_jq() {
  "${JQ_BIN:-${SHIPLOG_JQ_BIN:-jq}}" "$@"
}

tv_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

tv_debug_enabled() {
  tv_truthy "${SHIPLOG_DEBUG_SSH_VERIFY:-0}"
}

tv_dbg() {
  if tv_debug_enabled; then
    echo "shiplog[debug]: $*" >&2
  fi
  return 0
}

tv_fail() {
  echo "❌ shiplog: $*" >&2
  return 1
}

tv_warn() {
  echo "⚠️  shiplog: WARNING: $*" >&2
  return 0
}

trust_verify_tmp_init() {
  if [ -z "$TRUST_VERIFY_TMP" ]; then
    TRUST_VERIFY_TMP=$(mktemp -d) || return 1
  fi
  [ -d "$TRUST_VERIFY_TMP" ] || return 1
  return 0
}

trust_verify_cleanup() {
  if [ -n "$TRUST_VERIFY_TMP" ] && [ -d "$TRUST_VERIFY_TMP" ]; then
    rm -rf "$TRUST_VERIFY_TMP"
  fi
  return 0
}

# tv_tmpfile <label> — print a fresh path under TRUST_VERIFY_TMP.
tv_tmpfile() {
  trust_verify_tmp_init || { tv_fail "cannot create temporary directory"; return 1; }
  local path
  path=$(mktemp "$TRUST_VERIFY_TMP/${1:-tv}.XXXXXX") || { tv_fail "cannot create temporary file"; return 1; }
  printf '%s' "$path"
}

tv_is_wildcard_principal() {
  case "$1" in
    *'*'*|*'?'*|'') return 0 ;;
    *) return 1 ;;
  esac
}

tv_blob_exists() {
  git cat-file -e "$1:$2" 2>/dev/null
}

# trust_verify_load_trust_json <commit> <ref>
# Sets TV_TRUST_JSON, TV_THRESHOLD, TV_SIG_MODE (lowercase), TV_TRUST_ID.
trust_verify_load_trust_json() {
  local commit="$1" ref="${2:-trust ref}"
  TV_TRUST_JSON=""; TV_THRESHOLD=""; TV_SIG_MODE=""; TV_TRUST_ID=""
  [ -n "$commit" ] || { tv_fail "trust commit not specified"; return 1; }
  if ! TV_TRUST_JSON=$(git show "$commit:trust.json" 2>/dev/null) || [ -z "$TV_TRUST_JSON" ]; then
    tv_fail "trust ref $ref is missing trust.json at $commit"
    return 1
  fi
  if ! printf '%s' "$TV_TRUST_JSON" | tv_jq -e '
      type == "object" and
      .version == 1 and
      (.threshold | type == "number" and . >= 1 and . == floor) and
      (.maintainers | type == "array" and length >= 1) and
      ((.sig_mode == null) or (.sig_mode | type == "string"))
    ' >/dev/null 2>&1; then
    tv_fail "trust.json failed validation at $commit (need version 1, integer threshold >= 1, non-empty maintainers)"
    return 1
  fi
  TV_THRESHOLD=$(printf '%s' "$TV_TRUST_JSON" | tv_jq -r '.threshold') || return 1
  TV_SIG_MODE=$(printf '%s' "$TV_TRUST_JSON" | tv_jq -r '.sig_mode // "chain"' | tr '[:upper:]' '[:lower:]') || return 1
  TV_TRUST_ID=$(printf '%s' "$TV_TRUST_JSON" | tv_jq -r '.id // "shiplog-trust-root"') || return 1
  case "$TV_SIG_MODE" in
    chain|attestation) ;;
    *) tv_fail "trust.json at $commit has unknown sig_mode: $TV_SIG_MODE (expected chain|attestation)"; return 1 ;;
  esac
  return 0
}

# trust_verify_write_signers <commit> <outfile>
# Writes the allowed_signers blob of <commit> to <outfile> (mode 600).
# Returns 1 when the commit has no allowed_signers blob.
trust_verify_write_signers() {
  local commit="$1" out="$2"
  tv_blob_exists "$commit" "allowed_signers" || return 1
  git show "$commit:allowed_signers" > "$out" 2>/dev/null || return 1
  chmod 600 "$out" 2>/dev/null || true
  if tv_debug_enabled; then
    local principals
    principals=$(awk 'NF >= 2 && $1 !~ /^#/ {print $1}' "$out" | paste -sd, - 2>/dev/null || true)
    tv_dbg "allowed_signers@${commit:0:12}: principals=[${principals}]"
  fi
  return 0
}

# trust_verify_base_tree <commit>
# Prints the OID of the canonical base tree: trust.json plus allowed_signers
# when present, nothing else (the trust_sigs directory is excluded so the
# payload does not depend on the signatures that sign it).
trust_verify_base_tree() {
  local commit="$1" oid_trust oid_sigs
  oid_trust=$(git rev-parse -q --verify "$commit:trust.json" 2>/dev/null) || { tv_fail "trust.json missing at $commit"; return 1; }
  oid_sigs=$(git rev-parse -q --verify "$commit:allowed_signers" 2>/dev/null || true)
  if [ -n "$oid_sigs" ]; then
    printf '100644 blob %s\ttrust.json\n100644 blob %s\tallowed_signers\n' "$oid_trust" "$oid_sigs" | git mktree
  else
    printf '100644 blob %s\ttrust.json\n' "$oid_trust" | git mktree
  fi
}

# trust_verify_payload_from_parts <base_tree_oid> <trust_id> <threshold> [prior_oid]
# The one attestation payload builder. Exactly five lines, each newline-terminated.
# <prior_oid> is the trust commit this document replaces (the zero OID at genesis):
# an attestation approves one transition, so it cannot be replayed onto another
# history to restore an earlier roster.
trust_verify_payload_from_parts() {
  printf 'shiplog-trust-tree-v2\n%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "${4:-$TV_ZERO_OID}"
}

# trust_verify_payload <commit> [prior_oid]
# Prints the attestation payload for the trust document stored in <commit>
# replacing <prior_oid> (default: the zero OID, i.e. genesis).
trust_verify_payload() {
  local commit="$1" prior="${2:-$TV_ZERO_OID}" base trust_json trust_id threshold
  base=$(trust_verify_base_tree "$commit") || return 1
  trust_json=$(git show "$commit:trust.json" 2>/dev/null) || { tv_fail "trust.json missing at $commit"; return 1; }
  trust_id=$(printf '%s' "$trust_json" | tv_jq -r '.id // "shiplog-trust-root"') || return 1
  threshold=$(printf '%s' "$trust_json" | tv_jq -r '.threshold // 1') || return 1
  tv_dbg "attestation payload: base_tree=$base trust_id=$trust_id threshold=$threshold prior=$prior"
  trust_verify_payload_from_parts "$base" "$trust_id" "$threshold" "$prior"
}

# trust_verify_principal_is_maintainer <trust_json> <principal>
# 0 when <principal> names an unrevoked maintainer (by email or principal field).
trust_verify_principal_is_maintainer() {
  local trust_json="$1" principal="$2"
  if tv_is_wildcard_principal "$principal"; then
    return 1
  fi
  printf '%s' "$trust_json" | tv_jq -e --arg p "$principal" '
    [ .maintainers[]
      | select(type == "object")
      | select(.revoked != true)
      | select((.email == $p) or (.principal == $p))
    ] | length > 0
  ' >/dev/null 2>&1
}

# trust_verify_fpr_is_maintainer <trust_json> <fingerprint>
# 0 when an unrevoked maintainer lists this OpenPGP fingerprint (case-insensitive).
trust_verify_fpr_is_maintainer() {
  local trust_json="$1" fpr
  fpr=$(printf '%s' "$2" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
  [ -n "$fpr" ] || return 1
  printf '%s' "$trust_json" | tv_jq -e --arg f "$fpr" '
    [ .maintainers[]
      | select(type == "object")
      | select(.revoked != true)
      | select((.pgp_fpr // "" | gsub(" "; "") | ascii_upcase) == $f)
    ] | length > 0
  ' >/dev/null 2>&1
}

# tv_roster_lines <signers_file>
# Prints the line numbers of roster entries that can bind a signature to a
# maintainer: non-blank, not a comment, and whose principal field contains no
# wildcard. `ssh-keygen -Y find-principals` reports only the FIRST matching
# roster line, so binding is done one roster line at a time to stay exact.
tv_roster_lines() {
  awk 'NF >= 3 && $1 !~ /^#/ && $1 !~ /[*?]/ {print NR}' "$1" 2>/dev/null
}

# tv_roster_line_principals <signers_file> <line_no>
# Prints the principal(s) of that roster line, one per line (comma-separated
# lists are split).
tv_roster_line_principals() {
  sed -n "${2}p" "$1" | awk '{print $1}' | tr ',' '\n' | sed '/^$/d'
}

# tv_key_from_sshkeygen_output <text> — the SHA256:... fingerprint ssh-keygen printed.
tv_key_from_sshkeygen_output() {
  printf '%s\n' "$1" | sed -n 's/^.* with [^ ]* key \([^ ]*\).*$/\1/p' | head -n1
}

# tv_commit_signature_kind <commit> → prints ssh | gpg | none
tv_commit_signature_kind() {
  local header
  header=$(git cat-file commit "$1" 2>/dev/null | grep -m1 '^gpgsig ' || true)
  case "$header" in
    '') printf 'none' ;;
    *'BEGIN SSH SIGNATURE'*) printf 'ssh' ;;
    *) printf 'gpg' ;;
  esac
}

# trust_verify_commit_bindings <commit> <signers_file>
# Verifies the commit signature and prints every binding of the signing key to
# a roster principal, one per line:
#   <kind>\t<key_id>\t<principal>
# kind=ssh: key_id is the SSH key fingerprint; one line per non-wildcard roster
#           principal whose key verifies the signature (never the author e-mail,
#           never a wildcard line).
# kind=gpg: key_id is the OpenPGP fingerprint, principal is empty.
# Returns 1 when the commit is unsigned, invalid, or not bound to any roster key.
trust_verify_commit_bindings() {
  local commit="$1" signers="${2:-}" out status=0 kind
  kind=$(tv_commit_signature_kind "$commit")
  case "$kind" in
    none)
      tv_dbg "commit ${commit:0:12} carries no signature"
      return 1
      ;;
    gpg)
      out=$(git verify-commit --raw "$commit" 2>&1) || status=$?
      if [ "$status" -ne 0 ]; then
        tv_dbg "git verify-commit failed for ${commit:0:12}:"
        tv_dbg "$out"
        return 1
      fi
      local fpr
      fpr=$(printf '%s\n' "$out" | grep -m1 '^\[GNUPG:\] VALIDSIG ' | awk '{print $3}')
      if [ -z "$fpr" ]; then
        tv_dbg "OpenPGP signature verified but no VALIDSIG fingerprint was reported"
        return 1
      fi
      printf 'gpg\t%s\t\n' "$fpr"
      return 0
      ;;
  esac
  # SSH: bind per roster line.
  if [ -z "$signers" ] || [ ! -f "$signers" ]; then
    tv_dbg "commit ${commit:0:12} is SSH-signed but no roster is available"
    return 1
  fi
  local linefile found=0 lineno principal key
  linefile=$(tv_tmpfile roster-line) || return 1
  while IFS= read -r lineno; do
    [ -n "$lineno" ] || continue
    sed -n "${lineno}p" "$signers" > "$linefile"
    status=0
    out=$(git -c gpg.ssh.allowedSignersFile="$linefile" verify-commit --raw "$commit" 2>&1) || status=$?
    [ "$status" -eq 0 ] || continue
    key=$(tv_key_from_sshkeygen_output "$out")
    if [ -z "$key" ]; then
      tv_dbg "roster line $lineno verified ${commit:0:12} but the key fingerprint could not be parsed: $out"
      continue
    fi
    while IFS= read -r principal; do
      [ -n "$principal" ] || continue
      printf 'ssh\t%s\t%s\n' "$key" "$principal"
      found=1
    done < <(tv_roster_line_principals "$signers" "$lineno")
  done < <(tv_roster_lines "$signers")
  rm -f "$linefile"
  if [ "$found" -eq 0 ]; then
    tv_dbg "commit ${commit:0:12}: signature does not verify against any non-wildcard roster line"
    if tv_debug_enabled; then
      git -c gpg.ssh.allowedSignersFile="$signers" verify-commit --raw "$commit" 2>&1 | sed 's/^/shiplog[debug]: verify-commit: /' >&2 || true
    fi
    return 1
  fi
  return 0
}

# trust_verify_commit_roster_signature <commit> <signers_file>
# Plain roster check: the commit carries a valid signature from a key in the
# roster (any principal). Used for journal entries.
trust_verify_commit_roster_signature() {
  local commit="$1" signers="${2:-}"
  if [ -n "$signers" ] && [ -f "$signers" ]; then
    git -c gpg.ssh.allowedSignersFile="$signers" verify-commit "$commit" >/dev/null 2>&1
  else
    git verify-commit "$commit" >/dev/null 2>&1
  fi
}

# trust_verify_commit_signer_not_revoked <commit> <signers_file> <trust_json>
# Defense in depth for journal entries: fails when every roster binding of the
# commit's signing key belongs to a maintainer marked revoked in <trust_json>
# (for example, revoked but its allowed_signers line was not removed). Keys that
# are not bound to any named principal are left to the roster signature check.
trust_verify_commit_signer_not_revoked() {
  local commit="$1" signers="${2:-}" trust_json="$3" bindings kind key principal revoked=0 other=0
  bindings=$(trust_verify_commit_bindings "$commit" "$signers") || return 0
  while IFS=$'\t' read -r kind key principal; do
    [ -n "$kind" ] || continue
    if [ "$kind" = gpg ]; then
      if printf '%s' "$trust_json" | tv_jq -e --arg f "$(printf '%s' "$key" | tr -d ' ' | tr '[:lower:]' '[:upper:]')" '
          [ .maintainers[] | select(type == "object") | select(.revoked == true)
            | select((.pgp_fpr // "" | gsub(" "; "") | ascii_upcase) == $f) ] | length > 0' >/dev/null 2>&1; then
        revoked=1
      else
        other=1
      fi
    elif printf '%s' "$trust_json" | tv_jq -e --arg p "$principal" '
        [ .maintainers[] | select(type == "object") | select(.revoked == true)
          | select((.email == $p) or (.principal == $p)) ] | length > 0' >/dev/null 2>&1; then
      revoked=1
    else
      other=1
    fi
  done <<<"$bindings"
  if [ "$revoked" -eq 1 ] && [ "$other" -eq 0 ]; then
    tv_fail "commit $commit is signed by a revoked maintainer's key; remove its allowed_signers line"
    return 1
  fi
  return 0
}

# trust_verify_commit_by_maintainer <commit> <signers_file> <trust_json> [what]
# The commit must carry a valid signature whose key maps to an unrevoked
# maintainer of <trust_json>: SSH keys via the roster principal, OpenPGP keys
# via maintainers[].pgp_fpr. Prints "<kind> <key_id> <principal>" on success.
trust_verify_commit_by_maintainer() {
  local commit="$1" signers="${2:-}" trust_json="$3" what="${4:-commit}"
  local bindings kind key principal seen=""
  if ! bindings=$(trust_verify_commit_bindings "$commit" "$signers"); then
    case "$(tv_commit_signature_kind "$commit")" in
      none) tv_fail "$what $commit has missing or invalid signature" ;;
      *) tv_fail "$what $commit signature is not accepted by the current roster (wildcard roster principals never count)" ;;
    esac
    return 1
  fi
  while IFS=$'\t' read -r kind key principal; do
    [ -n "$kind" ] || continue
    case "$kind" in
      ssh)
        seen="$seen $principal"
        if trust_verify_principal_is_maintainer "$trust_json" "$principal"; then
          tv_dbg "$what ${commit:0:12} signed by maintainer kind=ssh key=$key principal=$principal"
          printf 'ssh %s %s\n' "$key" "$principal"
          return 0
        fi
        ;;
      gpg)
        seen="$seen $key"
        if trust_verify_fpr_is_maintainer "$trust_json" "$key"; then
          tv_dbg "$what ${commit:0:12} signed by maintainer kind=gpg fingerprint=$key"
          printf 'gpg %s\n' "$key"
          return 0
        fi
        ;;
    esac
  done <<<"$bindings"
  tv_fail "$what $commit is not signed by a current maintainer (signer bound to:${seen:- nothing}; revoked or unlisted in trust.json)"
  return 1
}

# trust_verify_attestations <new_commit> <signers_file> <roster_trust_json> <threshold> [prior_oid]
# Counts detached attestations under .shiplog/trust_sigs/ in <new_commit> that
# verify over the canonical payload of <new_commit> replacing <prior_oid>, come from a key listed in
# <signers_file> under a non-wildcard principal, and whose principal names an
# unrevoked maintainer of <roster_trust_json>. Distinct keys are counted once.
# Prints the count. Returns 0 when count >= threshold, 1 otherwise.
trust_verify_attestations() {
  local commit="$1" signers="${2:-}" trust_json="$3" threshold="$4" prior="${5:-$TV_ZERO_OID}"
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    tv_fail "ssh-keygen not available; cannot verify attestations"
    printf '0\n'
    return 1
  fi
  if [ -z "$signers" ] || [ ! -f "$signers" ]; then
    tv_fail "allowed_signers missing in the roster; cannot verify attestations"
    printf '0\n'
    return 1
  fi
  local payload sigfile
  payload=$(tv_tmpfile payload) || { printf '0\n'; return 1; }
  sigfile=$(tv_tmpfile sig) || { printf '0\n'; return 1; }
  if ! trust_verify_payload "$commit" "$prior" > "$payload"; then
    printf '0\n'
    return 1
  fi
  if tv_debug_enabled && command -v sha256sum >/dev/null 2>&1; then
    tv_dbg "attestation payload sha256=$(sha256sum "$payload" | awk '{print $1}')"
  fi

  local -a sigs=()
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    sigs+=("$path")
  done < <(git ls-tree -r --name-only "$commit" -- "$TV_SIG_DIR" 2>/dev/null | grep '\.sig$' || true)
  tv_dbg "attestation: found ${#sigs[@]} signature file(s) under $TV_SIG_DIR"

  local linefile
  linefile=$(tv_tmpfile roster-line) || { printf '0\n'; return 1; }
  local -a roster_lines=()
  local lineno
  while IFS= read -r lineno; do
    [ -n "$lineno" ] || continue
    roster_lines+=("$lineno")
  done < <(tv_roster_lines "$signers")
  if [ "${#roster_lines[@]}" -eq 0 ]; then
    tv_dbg "attestation: roster has no non-wildcard principal lines; nothing can count toward quorum"
  fi

  local verified=0 keys_seen=" "
  for path in "${sigs[@]}"; do
    if ! git show "$commit:$path" > "$sigfile" 2>/dev/null || [ ! -s "$sigfile" ]; then
      tv_dbg "attestation: cannot read $path"
      continue
    fi
    local bound=0 counted=0
    # Bind the signature to roster keys one line at a time: find-principals
    # reports only the first matching line of a file, and wildcard lines are
    # skipped entirely (they cannot name a maintainer).
    for lineno in "${roster_lines[@]}"; do
      sed -n "${lineno}p" "$signers" > "$linefile"
      ssh-keygen -Y find-principals -s "$sigfile" -f "$linefile" >/dev/null 2>&1 || continue
      bound=1
      local principal
      while IFS= read -r principal; do
        [ -n "$principal" ] || continue
        if ! trust_verify_principal_is_maintainer "$trust_json" "$principal"; then
          tv_dbg "attestation: $path roster line $lineno principal $principal is not an unrevoked maintainer"
          continue
        fi
        local vout vstatus=0
        vout=$(ssh-keygen -Y verify -n "$TV_NAMESPACE" -f "$linefile" -I "$principal" -s "$sigfile" < "$payload" 2>&1) || vstatus=$?
        if [ "$vstatus" -ne 0 ]; then
          tv_dbg "attestation: $path failed verification for principal $principal: $vout"
          continue
        fi
        local key
        key=$(tv_key_from_sshkeygen_output "$vout")
        if [ -z "$key" ]; then
          tv_dbg "attestation: $path verified but key fingerprint could not be parsed; not counted"
          continue
        fi
        case "$keys_seen" in
          *" $key "*)
            tv_dbg "attestation: $path duplicates key $key; counted once"
            ;;
          *)
            keys_seen="$keys_seen$key "
            verified=$((verified + 1))
            counted=1
            tv_dbg "attestation: $path counts (principal=$principal key=$key)"
            ;;
        esac
        break
      done < <(tv_roster_line_principals "$signers" "$lineno")
      if [ "$counted" -eq 1 ]; then
        break
      fi
    done
    if [ "$bound" -eq 0 ]; then
      tv_dbg "attestation: $path was not made by a non-wildcard roster key"
    fi
  done
  rm -f "$payload" "$sigfile" "$linefile"
  tv_dbg "attestation: verified=$verified distinct maintainer key(s); threshold=$threshold"
  printf '%s\n' "$verified"
  [ "$verified" -ge "$threshold" ]
}

# trust_verify_update <old_oid> <new_oid> <ref>
# Full verification of one update of the trust ref. Returns 0 on acceptance.
trust_verify_update() {
  local old="${1:-$TV_ZERO_OID}" new="$2" ref="${3:-refs/_shiplog/trust/root}"
  [ -n "$old" ] || old="$TV_ZERO_OID"
  [ -n "$new" ] || { tv_fail "trust update: new commit not specified"; return 1; }
  git cat-file -e "$new^{commit}" 2>/dev/null || { tv_fail "trust update: $new is not a commit"; return 1; }

  local genesis=0
  if [ "$old" = "$TV_ZERO_OID" ]; then
    genesis=1
  else
    git cat-file -e "$old^{commit}" 2>/dev/null || { tv_fail "trust update: prior commit $old is not available"; return 1; }
    git merge-base --is-ancestor "$old" "$new" >/dev/null 2>&1 || { tv_fail "$ref is not a fast-forward update"; return 1; }
  fi

  local require_signers="${SHIPLOG_REQUIRE_SEPARATE_SIGNERS:-1}"

  # 1) The NEW document must be well-formed on its own.
  trust_verify_load_trust_json "$new" "$ref" || return 1
  local new_threshold="$TV_THRESHOLD" new_sig_mode="$TV_SIG_MODE"
  local new_signers
  new_signers=$(tv_tmpfile signers-new) || return 1
  if ! trust_verify_write_signers "$new" "$new_signers"; then
    rm -f "$new_signers"; new_signers=""
    if [ "$require_signers" = "1" ]; then
      tv_fail "trust ref $ref missing allowed_signers at $new"
      return 1
    fi
  fi

  # 2) The roster that must approve this update: OLD for rotations, NEW at genesis.
  local roster_commit roster_json roster_threshold roster_sig_mode roster_signers
  if [ "$genesis" -eq 1 ]; then
    roster_commit="$new"
    roster_json="$TV_TRUST_JSON"; roster_threshold="$new_threshold"; roster_sig_mode="$new_sig_mode"
    roster_signers="$new_signers"
    tv_dbg "trust update: genesis push; verifying $new against its own roster"
  else
    roster_commit="$old"
    if ! trust_verify_load_trust_json "$old" "$ref"; then
      tv_fail "prior trust commit $old cannot be used as a roster; a server admin must repair $ref"
      return 1
    fi
    roster_json="$TV_TRUST_JSON"; roster_threshold="$TV_THRESHOLD"; roster_sig_mode="$TV_SIG_MODE"
    roster_signers=$(tv_tmpfile signers-roster) || return 1
    if ! trust_verify_write_signers "$old" "$roster_signers"; then
      rm -f "$roster_signers"; roster_signers=""
    fi
    tv_dbg "trust update: rotation; prior roster at ${old:0:12} (sig_mode=$roster_sig_mode threshold=$roster_threshold) approves ${new:0:12}"
  fi

  local unenforced=0
  if [ "${SHIPLOG_ALLOW_TRUST_THRESHOLD_UNENFORCED:-0}" = "1" ]; then
    unenforced=1
    tv_warn "SHIPLOG_ALLOW_TRUST_THRESHOLD_UNENFORCED=1: trust quorum is NOT enforced for $ref ($new). Remove this override as soon as possible."
  fi
  if [ -n "${SHIPLOG_REQUIRE_SIGNED_TRUST_MODE:-}" ]; then
    tv_warn "SHIPLOG_REQUIRE_SIGNED_TRUST_MODE is ignored: the gate only decides whether the trust commit must be signed; the quorum always applies (decision D1)"
  fi

  # 3) Gate: must the trust commit itself be signed by a current maintainer?
  local gate=0
  if tv_truthy "${SHIPLOG_REQUIRE_SIGNED_TRUST:-0}"; then
    gate=1
  fi
  local commit_checked=0
  if [ "$gate" -eq 1 ]; then
    trust_verify_commit_by_maintainer "$new" "$roster_signers" "$roster_json" "trust commit" >/dev/null || return 1
    commit_checked=1
  fi

  # 4) Quorum against the roster.
  case "$roster_sig_mode" in
    chain)
      if [ "$roster_threshold" -gt 1 ]; then
        if [ "$unenforced" -eq 1 ]; then
          tv_warn "chain mode threshold $roster_threshold cannot be satisfied by a single commit; accepted only because SHIPLOG_ALLOW_TRUST_THRESHOLD_UNENFORCED=1"
        else
          tv_fail "sig_mode=chain supports threshold 1 only (a Git commit carries one signature); roster threshold is $roster_threshold. Use sig_mode=attestation for N-of-M approval (see docs/TRUST.md)"
          return 1
        fi
      fi
      if [ "$genesis" -eq 0 ] && [ "$commit_checked" -eq 0 ]; then
        # The single signed commit IS the quorum for a rotation.
        trust_verify_commit_by_maintainer "$new" "$roster_signers" "$roster_json" "trust commit" >/dev/null || {
          tv_fail "trust rotation $new must be signed by a current maintainer of the prior roster ($old)"
          return 1
        }
      fi
      ;;
    attestation)
      local verified=0 astatus=0
      verified=$(trust_verify_attestations "$new" "$roster_signers" "$roster_json" "$roster_threshold" "$old") || astatus=$?
      if [ "$astatus" -ne 0 ]; then
        if [ "$unenforced" -eq 1 ]; then
          tv_warn "attestation quorum not met (verified ${verified:-0} of $roster_threshold); accepted only because SHIPLOG_ALLOW_TRUST_THRESHOLD_UNENFORCED=1"
        else
          tv_fail "verified ${verified:-0} distinct maintainer attestation(s) for $new; threshold is $roster_threshold (roster at ${roster_commit:0:12})"
          return 1
        fi
      fi
      ;;
    *)
      tv_fail "unknown sig_mode: $roster_sig_mode"
      return 1
      ;;
  esac

  # 5) Advisory checks on the NEW document.
  if [ "$new_sig_mode" = "chain" ] && [ "$new_threshold" -gt 1 ]; then
    tv_warn "new trust.json sets sig_mode=chain with threshold $new_threshold; the next rotation will be rejected unless sig_mode becomes attestation"
  fi
  if [ -n "$new_signers" ]; then rm -f "$new_signers"; fi
  if [ -n "$roster_signers" ] && [ "$roster_signers" != "$new_signers" ]; then rm -f "$roster_signers"; fi
  tv_dbg "trust update accepted: $ref $old -> $new"
  return 0
}
