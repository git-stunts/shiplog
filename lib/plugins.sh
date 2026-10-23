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

# shiplog_plugins_canonical_file PATH
# Follows symlinks (bounded) and prints the physical path of the regular file
# PATH resolves to; fails when it is not a regular file. Stock tools only:
# `readlink` without -f is enough because the loop does the walking.
shiplog_plugins_canonical_file() {
  local path="$1" hops=0 target dir
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    target=$(readlink "$path") || return 1
    case "$target" in
      /*) path="$target" ;;
      *) path="$(dirname "$path")/$target" ;;
    esac
  done
  [ -f "$path" ] || return 1
  dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s' "$dir" "$(basename "$path")"
}

# Discovery rule (docs/plugins.md): every entry of the stage directory that is
# an executable regular file, or a symlink to one, runs. Any name counts; the
# resolved file must live inside the plugins directory. Entries run in
# lexicographic order of their names.
shiplog_plugins_list() {
  local stage="$1"
  local dir
  dir=$(shiplog_plugins_stage_dir "$stage") || return 1
  [ -d "$dir" ] || return 0

  local plugins_root
  plugins_root=$(cd "$(shiplog_plugins_dir)" 2>/dev/null && pwd -P) || return 1

  find "$dir" -maxdepth 1 -mindepth 1 \( -type f -o -type l \) 2>/dev/null | sort | while IFS= read -r plugin; do
    local canonical
    if ! canonical=$(shiplog_plugins_canonical_file "$plugin"); then
      printf 'shiplog: ignoring plugin %s: not a regular file\n' "$plugin" >&2
      continue
    fi
    if [ ! -x "$canonical" ]; then
      continue
    fi
    case "$canonical/" in
      "$plugins_root/"*)
        printf '%s\n' "$plugin"
        ;;
      *)
        printf 'shiplog: ignoring plugin outside plugins dir: %s -> %s\n' "$plugin" "$canonical" >&2
        ;;
    esac
  done
}

# shiplog_plugins_trailer_intact MESSAGE
# True when MESSAGE still carries a parseable JSON-object trailer.
shiplog_plugins_trailer_intact() {
  local message="$1" json
  json=$(printf '%s\n' "$message" | shiplog_extract_trailer)
  [ -n "$json" ] || return 1
  printf '%s\n' "$json" | jq -e 'type == "object"' >/dev/null 2>&1
}

shiplog_plugins_filter() {
  local stage="$1" input="$2"
  local tmp_output="$input"
  local plugin
  while IFS= read -r plugin; do
    [ -n "$plugin" ] || continue
    # Here-string rather than a pipe: a plugin that exits without reading its
    # input must not turn into a SIGPIPE failure under pipefail.
    tmp_output=$("$plugin" "$stage" <<<"$tmp_output") || {
      printf 'shiplog: plugin %s failed during stage %s\n' "$plugin" "$stage" >&2
      return 1
    }
    # A plugin that exits 0 with empty or mangled output must not erase the
    # structured trailer (SLT.BUG.LIB.009).
    if ! shiplog_plugins_trailer_intact "$tmp_output"; then
      printf 'shiplog: plugin %s removed the structured trailer during stage %s\n' "$(basename "$plugin")" "$stage" >&2
      return 1
    fi
  done < <(shiplog_plugins_list "$stage")
  printf '%s' "$tmp_output"
}
