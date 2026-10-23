# shellcheck shell=bash
# Common utility functions for Shiplog CLI

die() {
  echo "❌ $*" >&2
  exit 1
}

# shiplog_parse_bool VALUE
# Prints 1 for 1|true|yes|on and 0 for 0|false|no|off (case-insensitive).
# Returns 2 (and prints nothing) for anything else. Every boolean that Shiplog
# reads from the environment, git config, flags or the policy document goes
# through this function so that an unrecognized spelling can never be mistaken
# for "off".
shiplog_parse_bool() {
  local raw="${1:-}"
  case "${raw,,}" in
    1|true|yes|on) printf '1'; return 0 ;;
    0|false|no|off) printf '0'; return 0 ;;
    *) return 2 ;;
  esac
}

# shiplog_bool_var VARNAME LABEL VALUE [DEFAULT]
# Stores the parsed boolean (1/0) in VARNAME. An empty VALUE yields DEFAULT
# (0 when omitted). An unrecognized VALUE dies naming LABEL and the value so a
# typo in a security switch fails closed instead of silently disabling it.
shiplog_bool_var() {
  local __shiplog_dest="$1" label="$2" raw="${3:-}" default="${4:-0}" parsed
  if [ -z "$raw" ]; then
    printf -v "$__shiplog_dest" '%s' "$default"
    return 0
  fi
  if ! parsed=$(shiplog_parse_bool "$raw"); then
    die "shiplog: $label must be a boolean (1|true|yes|on|0|false|no|off), got '$raw'"
  fi
  printf -v "$__shiplog_dest" '%s' "$parsed"
}

is_boring() {
  local v
  shiplog_bool_var v SHIPLOG_BORING "${SHIPLOG_BORING:-}" 0
  [ "$v" = 1 ]
}

# shiplog_repo_root
# Prints the repository root that `.shiplog/*` artifacts resolve against.
# bin/git-shiplog exports SHIPLOG_REPO_ROOT once; this helper recomputes it when
# a library is used outside the CLI entry point. Prints nothing (status 1) when
# no repository can be found.
shiplog_repo_root() {
  if [ -n "${SHIPLOG_REPO_ROOT:-}" ]; then
    printf '%s' "$SHIPLOG_REPO_ROOT"
    return 0
  fi
  local root
  if root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ]; then
    printf '%s' "$root"
    return 0
  fi
  local git_dir
  if git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$git_dir" ]; then
    # Bare repository: fall back to the directory that holds GIT_DIR.
    printf '%s' "$(dirname "$git_dir")"
    return 0
  fi
  return 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

shiplog_version() {
  if [ -n "${SHIPLOG_VERSION:-}" ]; then
    printf '%s' "$SHIPLOG_VERSION"
    return
  fi

  local repo
  repo="${SHIPLOG_HOME:-$(pwd)}"
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local desc
    desc=$(git -C "$repo" describe --tags --always 2>/dev/null || true)
    if [ -n "$desc" ]; then
      printf '%s' "$desc"
      return
    fi
    desc=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || true)
    if [ -n "$desc" ]; then
      printf '%s' "$desc"
      return
    fi
  fi

  printf '%s' "unknown"
}

shiplog_bosun_bin() {
  printf '%s' "${SHIPLOG_BOSUN_BIN:-bosun}"
}

shiplog_have_bosun() {
  command -v "$(shiplog_bosun_bin)" >/dev/null 2>&1
}

shiplog_require_bosun() {
  shiplog_have_bosun || die "Missing dependency: $(shiplog_bosun_bin)"
}

shiplog_can_use_bosun() {
  if is_boring; then
    return 1
  fi
  shiplog_have_bosun
}

shiplog_remote_name() {
  if [ -n "${SHIPLOG_REMOTE:-}" ]; then
    printf '%s' "$SHIPLOG_REMOTE"
    return
  fi
  local cfg
  cfg=$(git config shiplog.remote 2>/dev/null || true)
  if [ -n "$cfg" ]; then
    printf '%s' "$cfg"
    return
  fi
  printf '%s' "origin"
}

shiplog_is_dry_run() {
  local v
  shiplog_bool_var v SHIPLOG_DRY_RUN "${SHIPLOG_DRY_RUN:-}" 0
  [ "$v" = 1 ]
}

shiplog_dry_run_notice() {
  local message="${1:-}"
  if [ -z "$message" ]; then
    message="Dry-run: no changes performed"
  fi
  if shiplog_can_use_bosun; then
    local bosun
    bosun=$(shiplog_bosun_bin)
    "$bosun" style --title "Dry Run" -- "$message"
  else
    printf 'ℹ️ dry-run: %s\n' "$message"
  fi
}

shiplog_log_structured() {
  printf '%s\n' "$1" >&2
}

fmt_ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

escape_json_string() {
  local input="$1"
  command -v jq >/dev/null 2>&1 || die "shiplog: jq is required for structured logging"
  jq -Rn --arg value "$input" '$value'
}

_validate_env_var_name() {
  local name="$1"
  [ -n "$name" ] || die "Environment variable name cannot be empty"
  if [[ ! "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    die "Invalid environment variable name: $name (use uppercase letters, digits, underscores)"
  fi
  case "$name" in
    PATH|IFS|HOME|LANG|TZ|PWD|SHELL|USER|LOGNAME)
      die "Refusing to override reserved environment variable: $name"
      ;;
  esac
}

_log_prompt_interaction() {
  local field="$1" prompt="$2" result="$3" mode="${4:-string}"
  local escaped_prompt escaped_result
  escaped_prompt=$(escape_json_string "$prompt")
  case "$mode" in
    raw) escaped_result="$result" ;;
    string) escaped_result=$(escape_json_string "$result") ;;
    *) die "Unknown log mode: $mode" ;;
  esac
  printf '{"%s":%s,"value":%s}\n' "$field" "$escaped_prompt" "$escaped_result" >&2
}

shiplog_prompt_input() {
  [ $# -ge 2 ] || die "shiplog_prompt_input requires at least 2 arguments"
  local placeholder="$1"
  local env_var="$2"
  local fallback="${3:-}"

  _validate_env_var_name "$env_var"

  local value="${!env_var:-$fallback}"
  if is_boring; then
    printf '%s\n' "$value"
  else
    local result=""
    if shiplog_have_bosun; then
      local bosun
      bosun=$(shiplog_bosun_bin)
      if result=$("$bosun" input --placeholder "$placeholder" --value "$value" 2>/dev/null); then
        printf '%s\n' "$result"
        _log_prompt_interaction prompt "$placeholder" "$result"
        return
      fi
    fi
    # Fallback to POSIX prompt
    printf '%s ' "$placeholder" >&2
    IFS= read -r result || result="$value"
    [ -n "$result" ] || result="$value"
    printf '%s\n' "$result"
    _log_prompt_interaction prompt "$placeholder" "$result"
  fi
}

shiplog_prompt_choice() {
  [ $# -ge 3 ] || die "shiplog_prompt_choice requires header, env_var, and at least one option"
  local header="$1"
  local env_var="$2"
  shift 2
  local options=("$@")
  [ ${#options[@]} -gt 0 ] || die "At least one option required"
  local fallback="${options[0]:-}"
  _validate_env_var_name "$env_var"
  local value="${!env_var:-$fallback}"
  if [ -z "$value" ]; then
    value="$fallback"
  fi
  if is_boring; then
    printf '%s\n' "$value"
  else
    local result=""
    if shiplog_have_bosun; then
      local bosun
      bosun=$(shiplog_bosun_bin)
      if [ -n "$value" ]; then
        result=$("$bosun" choose --header "$header" --default "$value" "${options[@]}" 2>/dev/null) || true
      else
        result=$("$bosun" choose --header "$header" "${options[@]}" 2>/dev/null) || true
      fi
    fi
    if [ -z "$result" ]; then
      # Fallback: print options and read a line
      printf '%s [%s] ' "$header" "${options[*]}" >&2
      IFS= read -r result || result="$value"
      [ -n "$result" ] || result="$value"
    fi
    printf '%s\n' "$result"
    _log_prompt_interaction prompt "$header" "$result"
  fi
}

shiplog_confirm() {
  [ $# -ge 1 ] || die "shiplog_confirm requires a prompt argument"
  local prompt="$1"
  if is_boring || [ "${SHIPLOG_ASSUME_YES:-0}" = "1" ]; then
    return 0
  fi
  _log_prompt_interaction confirmation "$prompt" null raw
  if shiplog_have_bosun && "$(shiplog_bosun_bin)" confirm "$prompt"; then
    _log_prompt_interaction confirmation "$prompt" true raw
    return 0
  fi
  # Fallback
  printf '%s [y/N] ' "$prompt" >&2
  local ans
  IFS= read -r ans || ans=""
  case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
    y|yes) _log_prompt_interaction confirmation "$prompt" true raw; return 0 ;;
  esac
  _log_prompt_interaction confirmation "$prompt" false raw
  return 1
}
