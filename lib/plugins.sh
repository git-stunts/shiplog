# shellcheck shell=bash
# Plugin support for Shiplog (experimental)

shiplog_plugins_dir() {
  # Plugins live under the repository root, not the caller's cwd (SLT.BUG.LIB.007).
  local repo_root
  repo_root=$(shiplog_repo_root 2>/dev/null || printf '%s' "$PWD")
  local root="${SHIPLOG_PLUGINS_DIR:-$repo_root/.shiplog/plugins}"
  printf '%s' "$root"
}

shiplog_plugins_stage_dir() {
  local stage="$1"
  [ -n "$stage" ] || { printf 'shiplog: stage argument required\n' >&2; return 1; }
  local base
  base=$(shiplog_plugins_dir) || return 1
  printf '%s/%s.d' "$base" "$stage"
}

shiplog_plugins_list() {
  local stage="$1"
  local dir
  dir=$(shiplog_plugins_stage_dir "$stage") || return 1
  [ -d "$dir" ] || return 0

  local plugins_root
  plugins_root=$(cd "$(shiplog_plugins_dir)" 2>/dev/null && pwd -P) || return 1

  find "$dir" -maxdepth 1 -type f -perm -u+x -name '*.sh' 2>/dev/null | sort | while IFS= read -r plugin; do
    local canonical
    canonical=$(cd "$(dirname "$plugin")" 2>/dev/null && pwd -P)
    if [ -z "$canonical" ]; then
      printf 'shiplog: failed to resolve canonical path for %s\n' "$plugin" >&2
      continue
    fi
    case "$canonical/" in
      "$plugins_root/"*)
        printf '%s\n' "$plugin"
        ;;
      *)
        printf 'shiplog: ignoring plugin outside plugins dir: %s\n' "$plugin" >&2
        ;;
    esac
  done
}

shiplog_plugins_filter() {
  local stage="$1" input="$2"
  local tmp_output="$input"
  local plugin
  while IFS= read -r plugin; do
    [ -n "$plugin" ] || continue
    tmp_output=$(printf '%s' "$tmp_output" | "$plugin" "$stage") || {
      printf 'shiplog: plugin %s failed during stage %s\n' "$plugin" "$stage" >&2
      return 1
    }
  done < <(shiplog_plugins_list "$stage")
  printf '%s' "$tmp_output"
}
