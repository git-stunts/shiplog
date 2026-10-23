# shellcheck shell=bash
# Shared path guard for the Shiplog installer and uninstaller.
#
# Sourced (not executed) by scripts/install-shiplog.sh and
# scripts/uninstall-shiplog.sh. Pure bash plus git; no external binaries.
#
#   shiplog_guard_install_dir DIR MODE [REPO_URL]
#
#   MODE
#     path         DIR is canonicalized and checked against the deny-list, the
#                  allowed bases (SHIPLOG_ALLOWED_BASES, default "$HOME:/opt/shiplog")
#                  and the symlink rule. Use before creating DIR (git clone).
#     destructive  Everything in "path", plus evidence that DIR is a Shiplog
#                  checkout: DIR/bin/git-shiplog exists and
#                  remote.origin.url in DIR/.git/config matches REPO_URL after
#                  normalizing scheme, user, ".git" suffix and trailing slash.
#                  Use before `git reset --hard`, `rm -rf` and similar.
#
#   On success prints the canonical path on stdout and returns 0.
#   On refusal prints a reason on stderr and returns 1. Callers must treat any
#   non-zero status as "do nothing", including under --dry-run.
#
# Set SHIPLOG_GUARD_SKIP_CHECKOUT_CHECK=1 to skip only the checkout-evidence
# part of "destructive" (the uninstaller's --force-unsafe). The deny-list, base
# and symlink rules are never skipped.

shiplog_guard_resolve_path() {
  local raw="$1"
  [ -n "$raw" ] || return 1

  local path="$raw"
  case "$path" in
    "~") path="$HOME" ;;
    "~"/*) path="$HOME/${path#"~"/}" ;;
  esac

  if [ "${path#/}" = "$path" ]; then
    path="$PWD/$path"
  fi

  local current="/"
  local suffix="${path#/}"
  local IFS='/'
  # shellcheck disable=SC2206
  local parts=( $suffix )
  local part candidate

  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ''|.)
        continue
        ;;
      ..)
        current="${current%/*}"
        [ -n "$current" ] || current="/"
        continue
        ;;
    esac

    if [ "$current" = "/" ]; then
      candidate="/$part"
    else
      candidate="$current/$part"
    fi

    if [ -d "$candidate" ]; then
      current="$(cd "$candidate" 2>/dev/null && pwd -P)" || return 1
    else
      current="$candidate"
    fi
  done

  printf '%s' "$current"
}

# Normalize a git remote URL so ssh/https/file forms of the same repository
# compare equal: strips scheme, user@, ".git" suffix and trailing "/", and turns
# the scp-like "host:path" into "host/path".
shiplog_guard_normalize_url() {
  local url="$1"
  [ -n "$url" ] || return 1
  case "$url" in
    *://*) url="${url#*://}" ;;
  esac
  case "$url" in
    /*) : ;;
    *@*) url="${url#*@}" ;;
  esac
  # scp-like syntax: host:path (only when the first path component holds a colon)
  case "$url" in
    /*) : ;;
    *)
      local head="${url%%/*}"
      case "$head" in
        *:*) url="${head%%:*}/${head#*:}${url#"$head"}" ;;
      esac
      ;;
  esac
  url="${url%/}"
  url="${url%.git}"
  url="${url%/}"
  printf '%s' "$url"
}

shiplog_guard_install_dir() {
  local raw_dir="${1:-}" mode="${2:-path}" repo_url="${3:-}"
  local label="${SHIPLOG_GUARD_LABEL:-shiplog}"

  case "$mode" in
    path|destructive) ;;
    *)
      echo "$label: internal error: unknown guard mode '$mode'" >&2
      return 1
      ;;
  esac

  if [ -z "$raw_dir" ]; then
    echo "$label: refusing: SHIPLOG_HOME (install directory) must not be empty" >&2
    return 1
  fi

  local expanded="$raw_dir"
  case "$expanded" in
    "~") expanded="$HOME" ;;
    "~"/*) expanded="$HOME/${expanded#"~"/}" ;;
  esac
  if [ -L "$expanded" ]; then
    echo "$label: refusing: $raw_dir is a symlink; remove it manually first" >&2
    return 1
  fi

  local dir
  dir=$(shiplog_guard_resolve_path "$raw_dir") || dir=""
  if [ -z "$dir" ]; then
    echo "$label: refusing: unable to resolve install path '$raw_dir'" >&2
    return 1
  fi

  local home_resolved=""
  if [ -n "${HOME:-}" ]; then
    home_resolved=$(shiplog_guard_resolve_path "$HOME" 2>/dev/null || true)
  fi

  case "$dir" in
    /|/root)
      echo "$label: refusing to operate on $dir" >&2
      return 1
      ;;
  esac
  if [ -n "$home_resolved" ] && [ "$dir" = "$home_resolved" ]; then
    echo "$label: refusing to operate on \$HOME ($dir)" >&2
    return 1
  fi

  local allowed_bases="${SHIPLOG_ALLOWED_BASES:-${HOME:-}:/opt/shiplog}"
  local allowed_ok=0 base resolved_base
  local bases=()
  IFS=':' read -r -a bases <<< "$allowed_bases"
  for base in ${bases[@]+"${bases[@]}"}; do
    [ -n "$base" ] || continue
    resolved_base=$(shiplog_guard_resolve_path "$base" 2>/dev/null || true)
    [ -n "$resolved_base" ] || continue
    if [ "$dir" = "$resolved_base" ]; then
      echo "$label: refusing to operate on allowed base itself ($dir)" >&2
      return 1
    fi
    case "$resolved_base" in
      /) [ "${dir#/}" != "$dir" ] && allowed_ok=1 ;;
      *) case "$dir" in "$resolved_base"/*) allowed_ok=1 ;; esac ;;
    esac
  done
  if [ "$allowed_ok" -ne 1 ]; then
    echo "$label: refusing: $dir is outside permitted bases ($allowed_bases)" >&2
    return 1
  fi

  if [ "$mode" = "destructive" ] && [ "${SHIPLOG_GUARD_SKIP_CHECKOUT_CHECK:-0}" != "1" ]; then
    if [ ! -f "$dir/bin/git-shiplog" ]; then
      echo "$label: not a Shiplog checkout: $dir (missing bin/git-shiplog)" >&2
      return 1
    fi
    # Evidence must come from DIR itself: read DIR/.git/config directly so an
    # enclosing repository, an exported GIT_DIR or GIT_CONFIG_* cannot vouch
    # for a directory that is not itself a Shiplog clone.
    if [ -L "$dir/.git" ] || [ ! -d "$dir/.git" ] || [ ! -f "$dir/.git/config" ]; then
      echo "$label: not a Shiplog checkout: $dir (no .git directory of its own)" >&2
      return 1
    fi
    local origin_url
    origin_url=$(git config --file "$dir/.git/config" --get remote.origin.url 2>/dev/null || true)
    if [ -z "$origin_url" ]; then
      echo "$label: not a Shiplog checkout: $dir (no remote.origin.url)" >&2
      return 1
    fi
    local want have
    want=$(shiplog_guard_normalize_url "$repo_url" 2>/dev/null || true)
    have=$(shiplog_guard_normalize_url "$origin_url" 2>/dev/null || true)
    if [ -z "$want" ] || [ "$want" != "$have" ]; then
      echo "$label: not a Shiplog checkout: $dir (origin is '$origin_url', expected '$repo_url')" >&2
      return 1
    fi
  fi

  printf '%s' "$dir"
  return 0
}
