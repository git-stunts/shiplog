# shellcheck shell=bash
# Policy resolution helpers (jq-powered, JSON policy files)

validate_jq_and_file() {
  local src="$1"
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq command not found" >&2; return 1; }
  [ -r "$src" ] || { echo "ERROR: Cannot read policy file: $src" >&2; return 1; }
}

extract_policy_fields() {
  local src="$1" env="$2"
  jq -r --arg env "$env" '
    {
      require_signed: (
        if (.deployment_requirements[$env] | type == "object" and has("require_signed"))
        then .deployment_requirements[$env].require_signed
        else .require_signed
        end),
      allowed_signers_file: .allow_ssh_signers_file,
      notes_ref: .notes_ref,
      journals_prefix: .journals_ref_prefix,
      anchors_prefix: .anchors_ref_prefix
    }
    | to_entries
    | map(select(.value != null and .value != ""))
    | .[]
    | "\(.key)=\(.value)"
  ' "$src" 2>/dev/null
}

build_authors_list() {
  local env="$1" src="$2"
  jq -r --arg env "$env" '
    [
      (.authors.default_allowlist // []),
      (.authors.env_overrides.default // []),
      (.authors.env_overrides[$env] // [])
    ]
    | flatten
    | map(select(. != null and . != ""))
    | unique
    | join(" ")
  ' "$src" 2>/dev/null
}

resolve_signers_path() {
  local raw="$1" candidate="$1"
  local git_resolved
  git_resolved=$(git config --path gpg.ssh.allowedSignersFile 2>/dev/null || true)
  if [ -n "$git_resolved" ]; then
    candidate="$git_resolved"
  fi
  case "$candidate" in
    ~/*)
      candidate="$HOME/${candidate#~/}"
      ;;
  esac
  case "$candidate" in
    /*|[A-Za-z]:[\\/]*|\\\\\\\\*) ;;
    *)
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local repo_root
        repo_root=$(git rev-parse --show-toplevel)
        candidate="$repo_root/$candidate"
      fi
      ;;
  esac
  if command -v realpath >/dev/null 2>&1; then
    candidate=$(realpath "$candidate" 2>/dev/null || true)
  elif command -v readlink >/dev/null 2>&1; then
    candidate=$(readlink -f "$candidate" 2>/dev/null || true)
  fi
  [ -n "$candidate" ] || return 1
  printf '%s' "$candidate"
}

parse_policy_json() {
  local env="$1" src="$2"
  validate_jq_and_file "$src" || return 1

  local fields authors
  if ! fields=$(extract_policy_fields "$src" "$env"); then
    echo "ERROR: failed to parse policy fields from $src" >&2
    return 1
  fi
  if [ -n "$fields" ]; then
    printf '%s\n' "$fields"
  fi

  if ! authors=$(build_authors_list "$env" "$src"); then
    echo "ERROR: failed to assemble authors list from $src" >&2
    return 1
  fi
  if [ -n "$authors" ]; then
    printf 'authors=%s\n' "$authors"
  fi
}

apply_policy_pairs() {
  POLICY_REQUIRE_SIGNED=""
  POLICY_ALLOWED_SIGNERS_FILE=""
  POLICY_ALLOWED_AUTHORS=""
  POLICY_NOTES_REF=""
  POLICY_JOURNALS_PREFIX=""
  POLICY_ANCHORS_PREFIX=""

  while IFS='=' read -r key value; do
    case "$key" in
      require_signed) POLICY_REQUIRE_SIGNED="$value" ;;
      allowed_signers_file) POLICY_ALLOWED_SIGNERS_FILE="$value" ;;
      authors) POLICY_ALLOWED_AUTHORS="$value" ;;
      notes_ref) POLICY_NOTES_REF="$value" ;;
      journals_prefix) POLICY_JOURNALS_PREFIX="$value" ;;
      anchors_prefix) POLICY_ANCHORS_PREFIX="$value" ;;
    esac
  done
}

load_policy_content() {
  local env="$1"
  local from_ref=0
  local parsed

  if git rev-parse --verify "$POLICY_REF" >/dev/null 2>&1; then
    local tmp
    tmp=$(mktemp)
    if git show "$POLICY_REF:.shiplog/policy.json" 2>/dev/null > "$tmp"; then
      if parsed=$(parse_policy_json "$env" "$tmp"); then
        apply_policy_pairs <<<"$parsed"
        POLICY_SOURCE="policy-ref:$POLICY_REF"
        from_ref=1
        rm -f "$tmp"
        return 0
      fi
    fi
    rm -f "$tmp"
  fi

  if [ -f ".shiplog/policy.json" ]; then
    if parsed=$(parse_policy_json "$env" ".shiplog/policy.json"); then
      apply_policy_pairs <<<"$parsed"
      POLICY_SOURCE="policy-file:.shiplog/policy.json"
      return 0
    fi
  fi

  if [ "$from_ref" -eq 1 ]; then
    return 0
  fi
  return 1
}

resolve_policy() {
  if [ "${SHIPLOG_POLICY_INITIALIZED:-0}" -eq 1 ]; then
    return
  fi
  SHIPLOG_POLICY_INITIALIZED=1

  ALLOWED_AUTHORS_EFFECTIVE="${SHIPLOG_AUTHORS:-}"
  SIGNERS_FILE_EFFECTIVE="${SHIPLOG_ALLOWED_SIGNERS:-}"
  SHIPLOG_SIGN_EFFECTIVE="${SHIPLOG_SIGN:-}"

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    [ -z "$SHIPLOG_SIGN_EFFECTIVE" ] && SHIPLOG_SIGN_EFFECTIVE=0
    return
  fi

  if load_policy_content "$DEFAULT_ENV"; then
    :
  fi

  if [ -n "$POLICY_ALLOWED_AUTHORS" ] && [ -z "${SHIPLOG_AUTHORS:-}" ]; then
    ALLOWED_AUTHORS_EFFECTIVE="$POLICY_ALLOWED_AUTHORS"
  elif authors_cfg=$(git config --get shiplog.policy.allowedAuthors 2>/dev/null); then
    ALLOWED_AUTHORS_EFFECTIVE="$authors_cfg"
    [ -z "$POLICY_SOURCE" ] && POLICY_SOURCE="git-config:shiplog.policy.allowedAuthors"
  fi

  if [ -n "$POLICY_ALLOWED_SIGNERS_FILE" ] && [ -z "${SHIPLOG_ALLOWED_SIGNERS:-}" ]; then
    SIGNERS_FILE_EFFECTIVE="$POLICY_ALLOWED_SIGNERS_FILE"
  elif signers_cfg=$(git config --get shiplog.policy.allowedSignersFile 2>/dev/null); then
    SIGNERS_FILE_EFFECTIVE="$signers_cfg"
    [ -z "$POLICY_SOURCE" ] && POLICY_SOURCE="git-config:shiplog.policy.allowedSignersFile"
  elif [ -z "$SIGNERS_FILE_EFFECTIVE" ]; then
    SIGNERS_FILE_EFFECTIVE="$ALLOWED_SIGNERS_FILE"
  fi

  local sign_mode="${SHIPLOG_SIGN:-}"
  if [ -z "$sign_mode" ]; then
    if [ -n "$POLICY_REQUIRE_SIGNED" ]; then
      sign_mode="$POLICY_REQUIRE_SIGNED"
    else
      sign_mode=$(git config --bool shiplog.policy.requireSigned 2>/dev/null || echo "")
      [ -n "$sign_mode" ] && [ -z "$POLICY_SOURCE" ] && POLICY_SOURCE="git-config:shiplog.policy.requireSigned"
    fi
  fi

  case "$sign_mode" in
    0|false|no|off) SHIPLOG_SIGN_EFFECTIVE=0 ;;
    1|true|yes|on) SHIPLOG_SIGN_EFFECTIVE=1 ;;
    "") SHIPLOG_SIGN_EFFECTIVE=0 ;;
    *) SHIPLOG_SIGN_EFFECTIVE=0 ;;
  esac

  if [ "${SHIPLOG_SIGN_EFFECTIVE:-1}" != "0" ]; then
    if [ -n "$SIGNERS_FILE_EFFECTIVE" ]; then
      if ! SIGNERS_FILE_EFFECTIVE=$(resolve_signers_path "$SIGNERS_FILE_EFFECTIVE"); then
        die "shiplog: unable to resolve allowed signers path from '$SIGNERS_FILE_EFFECTIVE'"
      fi
    fi
    if [ -z "$SIGNERS_FILE_EFFECTIVE" ]; then
      die "shiplog: signing is required but no allowed signers file is configured"
    fi
    if [ ! -r "$SIGNERS_FILE_EFFECTIVE" ]; then
      die "shiplog: allowed signers file '$SIGNERS_FILE_EFFECTIVE' not found or unreadable"
    fi
  fi

  if [ -n "$POLICY_NOTES_REF" ]; then
    NOTES_REF="$POLICY_NOTES_REF"
  fi

  if [ -n "${SHIPLOG_AUTHORS:-}" ] && [ -z "$POLICY_SOURCE" ] && [ -n "$ALLOWED_AUTHORS_EFFECTIVE" ]; then
    POLICY_SOURCE="env:SHIPLOG_AUTHORS"
  fi

  if [ -z "$POLICY_SOURCE" ]; then
    POLICY_SOURCE="default"
  fi
}
