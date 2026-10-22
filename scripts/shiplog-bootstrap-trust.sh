#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIPLOG_HOME="${SHIPLOG_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

COMMON_LIB="$SHIPLOG_HOME/lib/common.sh"
if [ -f "$COMMON_LIB" ]; then
  # shellcheck disable=SC1090
  . "$COMMON_LIB"
else
  echo "shiplog-bootstrap-trust: missing $COMMON_LIB" >&2
  exit 1
fi
TRUST_VERIFY_LIB="${SHIPLOG_TRUST_VERIFY_LIB:-$SHIPLOG_HOME/lib/trust-verify.sh}"
if [ -f "$TRUST_VERIFY_LIB" ]; then
  # shellcheck disable=SC1090
  . "$TRUST_VERIFY_LIB"
else
  echo "shiplog-bootstrap-trust: missing $TRUST_VERIFY_LIB" >&2
  exit 1
fi

BOSUN_BIN="${SHIPLOG_BOSUN_BIN:-$SHIPLOG_HOME/scripts/bosun}"
if command -v "$BOSUN_BIN" >/dev/null 2>&1; then
  BOSUN_AVAILABLE=1
else
  if command -v bosun >/dev/null 2>&1; then
    BOSUN_BIN="$(command -v bosun)"
    BOSUN_AVAILABLE=1
  else
    BOSUN_AVAILABLE=0
  fi
fi

usage() {
  cat <<'USAGE'
shiplog-bootstrap-trust.sh

Bootstraps the signer roster for refs/_shiplog/trust/root by gathering maintainer metadata,
writing .shiplog/trust.json and .shiplog/allowed_signers, building the genesis commit, and
(optionally) pushing it to the configured remote (defaults to origin).

Usage: shiplog-bootstrap-trust.sh [--force] [--no-push] [--yes] [--plain]
       shiplog-bootstrap-trust.sh [TRUST_OPTIONS...] [--force] [--no-push]

Options:
  --force     overwrite existing trust files or refs/_shiplog/trust/root
  --no-push   generate the trust commit but skip the final git push
  --yes       assume yes for confirmations (or set SHIPLOG_ASSUME_YES=1)
  --plain     disable Bosun UI; use plain prompts (or set SHIPLOG_PLAIN=1)
  -h, --help  show this help and exit

Trust (non-interactive) options:
  --trust-id ID
  --trust-threshold N
  --trust-maintainer "name=<n>,email=<e>,key=<ssh_pub_path>[,principal=<p>][,role=<r>][,revoked=<yes|no>][,pgp=<fpr>]"
                     May be provided multiple times.
  --trust-message "Commit message" (default: shiplog: trust root v1 (GENESIS))
USAGE
}

ASSUME_YES="${SHIPLOG_ASSUME_YES:-0}"
PLAIN_UI="${SHIPLOG_PLAIN:-0}"

prompt_input() {
  local prompt="$1" default="${2:-}" value=""
  if [ "$PLAIN_UI" -ne 1 ] && [ "$BOSUN_AVAILABLE" -eq 1 ] && [ -t 0 ] && [ -t 1 ]; then
    value=$("$BOSUN_BIN" input --placeholder "$prompt" --value "$default")
  else
    # Non-interactive or plain mode without TTY: do NOT block on read; return default
    if [ -t 0 ] && [ -t 1 ]; then
      if [ -n "$default" ]; then
        printf '%s [%s]: ' "$prompt" "$default"
      else
        printf '%s: ' "$prompt"
      fi
      read -r value || value=""
      if [ -z "$value" ]; then
        value="$default"
      fi
    else
      value="$default"
    fi
  fi
  printf '%s\n' "$value"
}

prompt_confirm() {
  local prompt="$1" default_yes="${2:-1}"
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  if [ "$PLAIN_UI" -ne 1 ] && [ "$BOSUN_AVAILABLE" -eq 1 ] && [ -t 0 ] && [ -t 1 ]; then
    if [ "$default_yes" -eq 1 ]; then
      "$BOSUN_BIN" confirm --default-yes "$prompt"
    else
      "$BOSUN_BIN" confirm "$prompt"
    fi
    return $?
  fi
  # Non-interactive or no TTY: do NOT block; return default
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    [ "$default_yes" -eq 1 ] && return 0 || return 1
  fi
  local fallback
  if [ "$default_yes" -eq 1 ]; then
    printf '%s [Y/n]: ' "$prompt"
    read -r fallback || fallback=""
    case "${fallback:-y}" in
      y|Y|yes|YES) return 0 ;;
      *) return 1 ;;
    esac
  else
    printf '%s [y/N]: ' "$prompt"
    read -r fallback || fallback=""
    case "${fallback:-n}" in
      y|Y|yes|YES) return 0 ;;
      *) return 1 ;;
    esac
  fi
}

die() {
  printf '❌ %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

json_quote() {
  jq -Rn --arg v "$1" '$v'
}

FORCE=0
DO_PUSH=1
CLI_TRUST=0
CLI_TRUST_ID=""
CLI_TRUST_THRESHOLD=""
CLI_TRUST_MESSAGE=""
CLI_TRUST_SIG_MODE=""
declare -a CLI_MAINTS
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --no-push) DO_PUSH=0 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --plain) PLAIN_UI=1 ;;
    --trust-id)
      shift; CLI_TRUST_ID="${1:-}" ;;
    --trust-id=*)
      CLI_TRUST_ID="${1#*=}" ;;
    --trust-threshold)
      shift; CLI_TRUST_THRESHOLD="${1:-}" ;;
    --trust-threshold=*)
      CLI_TRUST_THRESHOLD="${1#*=}" ;;
    --trust-message)
      shift; CLI_TRUST_MESSAGE="${1:-}" ;;
    --trust-message=*)
      CLI_TRUST_MESSAGE="${1#*=}" ;;
    --trust-maintainer)
      shift; [ -n "${1:-}" ] || { echo "missing value for --trust-maintainer" >&2; exit 2; }; CLI_MAINTS+=("$1") ;;
    --trust-maintainer=*)
      CLI_MAINTS+=("${1#*=}") ;;
    --trust-sig-mode)
      shift; CLI_TRUST_SIG_MODE="${1:-}" ;;
    --trust-sig-mode=*)
      CLI_TRUST_SIG_MODE="${1#*=}" ;;
    --no-color) NO_COLOR=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  shift || true
done

need git
need jq
# Sign the genesis trust commit by default when a signing key is configured.
# SHIPLOG_SIGN_TRUST=1|0 overrides; SHIPLOG_TRUST_SIGN is a deprecated alias.
if [ -n "${SHIPLOG_TRUST_SIGN:-}" ] && [ -z "${SHIPLOG_SIGN_TRUST:-}" ]; then
  echo "WARN: SHIPLOG_TRUST_SIGN is deprecated; use SHIPLOG_SIGN_TRUST" >&2
fi
SIGN_TRUST_RAW="${SHIPLOG_SIGN_TRUST:-${SHIPLOG_TRUST_SIGN:-}}"
SIGN_TRUST_HINT=0
sign_trust_default() {
  if [ -n "$(git config user.signingkey 2>/dev/null || true)" ]; then
    SIGN_TRUST=1
  else
    SIGN_TRUST=0
    SIGN_TRUST_HINT=1
  fi
}
case "$(printf '%s' "$SIGN_TRUST_RAW" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" in
  1|true|yes|on) SIGN_TRUST=1 ;;
  0|false|no|off) SIGN_TRUST=0 ;;
  "") sign_trust_default ;;
  *) echo "WARN: invalid SHIPLOG_SIGN_TRUST='$SIGN_TRUST_RAW'; deciding from user.signingkey" >&2; sign_trust_default ;;
esac

CWD=$(pwd -P 2>/dev/null || pwd)
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "shiplog-bootstrap-trust: $CWD is not inside a git repository"
fi
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || die "shiplog-bootstrap-trust: unable to determine repository root from $CWD"
if ! REPO_ROOT=$(cd "$REPO_ROOT" 2>/dev/null && pwd -P); then
  die "shiplog-bootstrap-trust: repository root path is not accessible: $REPO_ROOT"
fi
[ -d "$REPO_ROOT" ] || die "shiplog-bootstrap-trust: repository root is not a directory: $REPO_ROOT"

SHIPLOG_REMOTE_NAME="$(shiplog_remote_name)"

TRUST_REF="refs/_shiplog/trust/root"
if git show-ref --verify --quiet "$TRUST_REF" && [ "$FORCE" -ne 1 ]; then
  die "$TRUST_REF already exists. Use --force to overwrite it."
fi

# Optional non-interactive mode via env vars

non_interactive_bootstrap="0"
# Prefer CLI trust options when provided (guard for unset array under set -u)
has_cli_maint=0
if declare -p CLI_MAINTS >/dev/null 2>&1; then
  # Use parameter expansion to avoid unbound error under set -u
  if [ "${CLI_MAINTS+set}" = "set" ] && [ ${#CLI_MAINTS[@]} -gt 0 ]; then
    has_cli_maint=1
  fi
fi
if [ "$has_cli_maint" -eq 1 ] || [ -n "${CLI_TRUST_ID:-}" ] || [ -n "${CLI_TRUST_THRESHOLD:-}" ] || [ -n "${CLI_TRUST_MESSAGE:-}" ]; then
  non_interactive_bootstrap="2"
fi
if [ -n "${SHIPLOG_TRUST_COUNT:-}" ]; then
  if printf '%s' "$SHIPLOG_TRUST_COUNT" | grep -Eq '^[1-9][0-9]*$'; then
    # Only set to env-driven mode if CLI mode not already selected
    [ "$non_interactive_bootstrap" = "0" ] && non_interactive_bootstrap="1"
  else
    die "SHIPLOG_TRUST_COUNT must be a positive integer"
  fi
fi

trust_id=""
declare -a maint_names maint_emails maint_roles maint_fprs maint_revoked maint_principals maint_keys
threshold=""
commit_message=""

if [ "$non_interactive_bootstrap" = "2" ]; then
  # CLI-driven non-interactive
  trust_id="${CLI_TRUST_ID:-shiplog-trust-root}"
  sig_mode="${CLI_TRUST_SIG_MODE:-chain}"
  case "$(printf '%s' "$sig_mode" | tr '[:upper:]' '[:lower:]')" in
    chain|attestation) : ;;
    *) die "invalid --trust-sig-mode: $sig_mode (expected chain|attestation)" ;;
  esac
  has_cli_maint=0
  if declare -p CLI_MAINTS >/dev/null 2>&1; then
    if [ "${CLI_MAINTS+set}" = "set" ] && [ ${#CLI_MAINTS[@]} -gt 0 ]; then
      has_cli_maint=1
    fi
  fi
  if [ "$has_cli_maint" -ne 1 ]; then
    die "at least one --trust-maintainer is required when using CLI trust options"
  fi
  for spec in "${CLI_MAINTS[@]}"; do
    # Parse key=value tokens separated by commas
    name_val="" email_val="" key_path_val="" principal_val="" role_val="root" revoked_val="no" fpr_val=""
    IFS=',' read -r -a toks <<< "$spec"
    for tok in "${toks[@]}"; do
      key="${tok%%=*}"; val="${tok#*=}"
      case "$key" in
        name) name_val="$val" ;;
        email) email_val="$val" ;;
        key) key_path_val="$val" ;;
        principal) principal_val="$val" ;;
        role) role_val="$val" ;;
        revoked) revoked_val="$val" ;;
        pgp|pgp_fpr|fpr) fpr_val="$val" ;;
        *) echo "WARN: unknown token in --trust-maintainer: $key" >&2 ;;
      esac
    done
    [ -n "$name_val" ] || die "--trust-maintainer requires name=..."
    [ -n "$email_val" ] || die "--trust-maintainer requires email=..."
    [ -n "$key_path_val" ] || die "--trust-maintainer requires key=PATH to SSH .pub"
    [ -r "$key_path_val" ] || die "cannot read SSH key: $key_path_val"
    key_line=$(awk 'NR==1 {print; exit}' "$key_path_val")
    [ -n "$key_line" ] || die "empty SSH key: $key_path_val"
    [ -n "$principal_val" ] || principal_val="$email_val"
    case "$revoked_val" in
      y|Y|yes|YES|true|TRUE|1) revoked_val=true ;;
      *) revoked_val=false ;;
    esac
    maint_names+=("$name_val")
    maint_emails+=("$email_val")
    maint_roles+=("$role_val")
    maint_fprs+=("$fpr_val")
    maint_revoked+=("$revoked_val")
    maint_principals+=("$principal_val")
    maint_keys+=("$key_line")
  done
  threshold="${CLI_TRUST_THRESHOLD:-${#maint_names[@]}}"
  if ! printf '%s' "$threshold" | grep -Eq '^[1-9][0-9]*$' || [ "$threshold" -gt "${#maint_names[@]}" ]; then
    die "invalid --trust-threshold: $threshold (maintainers=${#maint_names[@]})"
  fi
  commit_message="${CLI_TRUST_MESSAGE:-shiplog: trust root v1 (GENESIS)}"
elif [ "$non_interactive_bootstrap" = "1" ]; then
  trust_id="${SHIPLOG_TRUST_ID:-shiplog-trust-root}"
  sig_mode="${SHIPLOG_TRUST_SIG_MODE:-chain}"
  case "$(printf '%s' "$sig_mode" | tr '[:upper:]' '[:lower:]')" in
    chain|attestation) : ;;
    *) die "invalid SHIPLOG_TRUST_SIG_MODE: $sig_mode (expected chain|attestation)" ;;
  esac
  count="$SHIPLOG_TRUST_COUNT"
  i=1
  while [ "$i" -le "$count" ]; do
    name_var="SHIPLOG_TRUST_${i}_NAME"
    email_var="SHIPLOG_TRUST_${i}_EMAIL"
    role_var="SHIPLOG_TRUST_${i}_ROLE"
    fpr_var="SHIPLOG_TRUST_${i}_PGP_FPR"
    key_path_var="SHIPLOG_TRUST_${i}_SSH_KEY_PATH"
    principal_var="SHIPLOG_TRUST_${i}_PRINCIPAL"
    revoked_var="SHIPLOG_TRUST_${i}_REVOKED"

    eval name_val="\${$name_var:-}"
    eval email_val="\${$email_var:-}"
    eval role_val="\${$role_var:-root}"
    eval fpr_val="\${$fpr_var:-}"
    eval key_path_val="\${$key_path_var:-}"
    eval principal_val="\${$principal_var:-}"
    eval revoked_val="\${$revoked_var:-no}"

    [ -n "$name_val" ]   || die "missing $name_var"
    [ -n "$email_val" ]  || die "missing $email_var"
    [ -n "$key_path_val" ] || die "missing $key_path_var (path to SSH .pub)"
    [ -r "$key_path_val" ] || die "cannot read SSH key: $key_path_val"
    key_line=$(awk 'NR==1 {print; exit}' "$key_path_val")
    [ -n "$key_line" ] || die "empty SSH key: $key_path_val"
    if [ -z "$principal_val" ]; then
      principal_val="$email_val"
    fi
    case "$revoked_val" in
      y|Y|yes|YES|true|TRUE|1) revoked_val=true ;;
      *) revoked_val=false ;;
    esac

    maint_names+=("$name_val")
    maint_emails+=("$email_val")
    maint_roles+=("$role_val")
    maint_fprs+=("$fpr_val")
    maint_revoked+=("$revoked_val")
    maint_principals+=("$principal_val")
    maint_keys+=("$key_line")
    i=$((i+1))
  done
  threshold="${SHIPLOG_TRUST_THRESHOLD:-$count}"
  if ! printf '%s' "$threshold" | grep -Eq '^[1-9][0-9]*$' || [ "$threshold" -gt "$count" ]; then
    die "invalid SHIPLOG_TRUST_THRESHOLD: $threshold (count=$count)"
  fi
  commit_message="${SHIPLOG_TRUST_COMMIT_MESSAGE:-shiplog: trust root v1 (GENESIS)}"
else
  # If not running in a TTY and no non-interactive inputs provided, fail fast
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    die "non-interactive trust bootstrap requires SHIPLOG_TRUST_* environment variables; run in a TTY or provide envs"
  fi
  if ! prompt_confirm "Proceed with interactive trust bootstrap?" 1; then
    echo "Aborted." >&2
    exit 1
  fi

  maint_count=""
  while :; do
    maint_count=$(prompt_input "Number of maintainers" "2")
    if printf '%s' "$maint_count" | grep -Eq '^[1-9][0-9]*$'; then
      break
    fi
    echo "Please enter a positive integer." >&2
  done

  trust_id=$(prompt_input "Trust identifier" "shiplog-trust-root")
  sig_mode=$(prompt_input "Signing mode [chain|attestation]" "chain")
  case "$(printf '%s' "$sig_mode" | tr '[:upper:]' '[:lower:]')" in
    chain|attestation) : ;;
    *) echo "Invalid signing mode; defaulting to chain" >&2; sig_mode="chain" ;;
  esac

  index=1
  while [ "$index" -le "$maint_count" ]; do
    echo "--- Maintainer $index ---"
    name=""
    while [ -z "$name" ]; do
      name=$(prompt_input "Full name" "")
      [ -n "$name" ] || echo "Name cannot be empty" >&2
    done

    email=""
    while [ -z "$email" ]; do
      email=$(prompt_input "Email address" "")
      [ -n "$email" ] || echo "Email cannot be empty" >&2
    done

    role=$(prompt_input "Role" "root")
    fpr=$(prompt_input "OpenPGP fingerprint (optional)" "")

    key_line=""
    while [ -z "$key_line" ]; do
      key_path=$(prompt_input "SSH public key path" "")
      if [ -z "$key_path" ]; then
        echo "Path cannot be empty" >&2
        continue
      fi
      if [ ! -f "$key_path" ]; then
        echo "File not found: $key_path" >&2
        continue
      fi
      key_line=$(awk 'NR==1 {print; exit}' "$key_path")
      if [ -z "$key_line" ]; then
        echo "Unable to read SSH key from $key_path" >&2
      fi
    done

    principal=""
    while [ -z "$principal" ]; do
      principal=$(prompt_input "Signer principal" "$email")
      [ -n "$principal" ] || echo "Principal cannot be empty" >&2
    done

    revoked_answer=$(prompt_input "Revoked? (yes/no)" "no")
    case "$revoked_answer" in
      y|Y|yes|YES|true|TRUE) revoked=true ;;
      *) revoked=false ;;
    esac

    maint_names+=("$name")
    maint_emails+=("$email")
    maint_roles+=("$role")
    maint_fprs+=("$fpr")
    maint_revoked+=("$revoked")
    maint_principals+=("$principal")
    maint_keys+=("$key_line")

    index=$((index + 1))
  done

  threshold=""
  while :; do
    threshold=$(prompt_input "Signature threshold" "$maint_count")
    if printf '%s' "$threshold" | grep -Eq '^[1-9][0-9]*$'; then
      if [ "$threshold" -le "$maint_count" ]; then
        break
      fi
      echo "Threshold cannot exceed maintainer count ($maint_count)." >&2
    else
      echo "Please enter a positive integer." >&2
    fi
  done

  commit_message=$(prompt_input "Trust genesis commit message" "shiplog: trust root v1 (GENESIS)")
fi

# End non-interactive/interactive branching

# Normalize once; the verifier compares sig_mode case-sensitively.
sig_mode=$(printf '%s' "${sig_mode:-chain}" | tr '[:upper:]' '[:lower:]')

summary="Trust ID: $trust_id\nThreshold: $threshold\nSigning mode: $sig_mode\nMaintainers:"
for i in "${!maint_names[@]}"; do
summary+=$'\n  - '
  summary+="${maint_names[$i]} <${maint_emails[$i]}> (role: ${maint_roles[$i]}, revoked: ${maint_revoked[$i]})"
done

if [ "$BOSUN_AVAILABLE" -eq 1 ] && [ -t 0 ] && [ -t 1 ]; then
  "$BOSUN_BIN" style --title "Trust Bootstrap" -- "$summary"
else
  printf '\n%s\n\n' "$summary"
fi

if ! prompt_confirm "Continue with these settings?" 1; then
  echo "Aborted." >&2
  exit 1
fi

mkdir -p "$REPO_ROOT/.shiplog"
trust_path="$REPO_ROOT/.shiplog/trust.json"
signers_path="$REPO_ROOT/.shiplog/allowed_signers"

if [ -e "$trust_path" ] && [ "$FORCE" -ne 1 ]; then
  prompt_confirm "Overwrite existing $trust_path?" 0 || die "Refusing to overwrite $trust_path"
fi

if [ -e "$signers_path" ] && [ "$FORCE" -ne 1 ]; then
  prompt_confirm "Overwrite existing $signers_path?" 0 || die "Refusing to overwrite $signers_path"
fi

# Build trust.json with jq so every value is quoted correctly (a previous
# version wrote literal "\n" sequences and produced invalid JSON).
maintainers_json='[]'
for i in "${!maint_names[@]}"; do
  maintainers_json=$(jq -c \
    --arg name "${maint_names[$i]}" \
    --arg email "${maint_emails[$i]}" \
    --arg fpr "${maint_fprs[$i]}" \
    --arg role "${maint_roles[$i]}" \
    --arg principal "${maint_principals[$i]}" \
    --argjson revoked "${maint_revoked[$i]}" \
    '. + [{
      name: $name,
      email: $email,
      pgp_fpr: (if $fpr == "" then null else $fpr end),
      role: $role,
      revoked: $revoked
    } + (if $principal != "" and $principal != $email then {principal: $principal} else {} end)]' \
    <<<"$maintainers_json")
done

jq -n \
  --arg id "$trust_id" \
  --arg sig_mode "$sig_mode" \
  --argjson threshold "$threshold" \
  --argjson maintainers "$maintainers_json" \
  '{version: 1, id: $id, sig_mode: $sig_mode, threshold: $threshold, maintainers: $maintainers}' \
  > "$trust_path"

tmp_signers=""
for i in "${!maint_principals[@]}"; do
  tmp_signers+="${maint_principals[$i]} ${maint_keys[$i]}"$'\n'
done
printf '%s' "$tmp_signers" > "$signers_path"

OID_TRUST=$(git hash-object -w "$trust_path")
OID_SIGS=$(git hash-object -w "$signers_path")
BASE_TREE=$(printf '100644 blob %s\ttrust.json\n100644 blob %s\tallowed_signers\n' "$OID_TRUST" "$OID_SIGS" | git mktree)
TREE="$BASE_TREE"

# Attestation mode: the genesis commit must already carry the bootstrapping
# maintainer's attestation under .shiplog/trust_sigs/<principal>.sig, signed over
# the canonical payload (lib/trust-verify.sh builds it; the hook verifies it).
if [ "$sig_mode" = "attestation" ]; then
  attest_key="$(git config user.signingkey 2>/dev/null || true)"
  attest_format="$(git config gpg.format 2>/dev/null || echo openpgp)"
  attest_principal=""
  attest_pub=""
  case "$attest_key" in
    ~/*) attest_key="$HOME/${attest_key#~/}" ;;
  esac
  if [ -n "$attest_key" ] && [ "$attest_format" = "ssh" ] && [ -r "$attest_key" ] && command -v ssh-keygen >/dev/null 2>&1; then
    attest_pub="$(ssh-keygen -y -f "$attest_key" 2>/dev/null | awk '{print $1" "$2}' || true)"
  fi
  if [ -n "$attest_pub" ]; then
    for i in "${!maint_keys[@]}"; do
      if [ "$(printf '%s' "${maint_keys[$i]}" | awk '{print $1" "$2}')" = "$attest_pub" ]; then
        attest_principal="${maint_principals[$i]}"
        break
      fi
    done
  fi
  if [ -n "$attest_principal" ]; then
    attest_tmp=$(mktemp -d)
    trust_verify_payload_from_parts "$BASE_TREE" "$trust_id" "$threshold" > "$attest_tmp/payload"
    if ssh-keygen -Y sign -f "$attest_key" -n "${SHIPLOG_TRUST_NAMESPACE:-shiplog-trust}" - < "$attest_tmp/payload" > "$attest_tmp/sig" 2>/dev/null; then
      mkdir -p "$REPO_ROOT/.shiplog/trust_sigs"
      cp "$attest_tmp/sig" "$REPO_ROOT/.shiplog/trust_sigs/$attest_principal.sig"
      OID_ASIG=$(git hash-object -w "$attest_tmp/sig")
      SIGS_TREE=$(printf '100644 blob %s\t%s.sig\n' "$OID_ASIG" "$attest_principal" | git mktree)
      DOT_TREE=$(printf '040000 tree %s\ttrust_sigs\n' "$SIGS_TREE" | git mktree)
      TREE=$(printf '100644 blob %s\ttrust.json\n100644 blob %s\tallowed_signers\n040000 tree %s\t.shiplog\n' "$OID_TRUST" "$OID_SIGS" "$DOT_TREE" | git mktree)
      printf '✅ Wrote genesis attestation .shiplog/trust_sigs/%s.sig\n' "$attest_principal"
    else
      echo "WARN: ssh-keygen -Y sign failed; genesis commit carries no attestation" >&2
    fi
    rm -rf "$attest_tmp"
  else
    echo "WARN: attestation mode but no SSH signing key matching a maintainer is configured (git config gpg.format ssh; user.signingkey <private key path>); the genesis commit carries no attestation and a hook enforcing threshold $threshold will reject it. Add attestations with scripts/shiplog-trust-sign.sh before pushing." >&2
  fi
fi

AUTHOR_NAME="${GIT_AUTHOR_NAME:-$(git config user.name || echo "Shiplog Trust")}" \
AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$(git config user.email || echo "trust@local")}" \
COMMITTER_NAME="${GIT_COMMITTER_NAME:-$AUTHOR_NAME}" \
COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$AUTHOR_EMAIL}"

if [ -z "$AUTHOR_NAME" ] || [ -z "$AUTHOR_EMAIL" ]; then
  die "git config user.name and user.email are required to sign the trust commit"
fi

commit_flags=()
if [ "$SIGN_TRUST" != "0" ]; then
  commit_flags+=( -S )
  # Validate signing is properly configured
  if ! git config user.signingkey >/dev/null 2>&1; then
    die "SHIPLOG_SIGN_TRUST=1 requested a signed trust commit but git config user.signingkey is not set"
  fi
else
  if [ "$SIGN_TRUST_HINT" -eq 1 ]; then
    echo "hint: no signing key configured (git config user.signingkey); the genesis trust commit will be UNSIGNED. Configure a key and set SHIPLOG_SIGN_TRUST=1 to sign it; servers with SHIPLOG_REQUIRE_SIGNED_TRUST=1 reject unsigned trust commits." >&2
  else
    echo "hint: SHIPLOG_SIGN_TRUST=0; the genesis trust commit will be unsigned." >&2
  fi
fi
if ! GENESIS=$(printf '%s\n' "$commit_message" | \
  GIT_AUTHOR_NAME="$AUTHOR_NAME" \
  GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
  GIT_COMMITTER_NAME="$COMMITTER_NAME" \
  GIT_COMMITTER_EMAIL="$COMMITTER_EMAIL" \
  git commit-tree "$TREE" ${commit_flags:+"${commit_flags[@]}"} 2>&1); then
  die "failed to create trust commit: $GENESIS"
fi

git update-ref "$TRUST_REF" "$GENESIS"

printf '✅ Wrote %s and %s\n' "$trust_path" "$signers_path"
printf '✅ Created trust commit %s\n' "$GENESIS"

if [ "$DO_PUSH" -eq 1 ]; then
  if prompt_confirm "Push $TRUST_REF to $SHIPLOG_REMOTE_NAME now?" 1; then
    git push --no-verify "$SHIPLOG_REMOTE_NAME" "$TRUST_REF"
  else
    echo "Skipped push; run 'git push --no-verify $SHIPLOG_REMOTE_NAME $TRUST_REF' when ready." >&2
  fi
else
  echo "Skipping push as requested (use git push when ready)."
fi

echo "Run ./scripts/shiplog-trust-sync.sh to distribute the allowed signers file on other machines."
