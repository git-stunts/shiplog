#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_LIB="$SCRIPT_ROOT/lib/common.sh"
if [ -f "$COMMON_LIB" ]; then
  # shellcheck disable=SC1090
  . "$COMMON_LIB"
else
  echo "uninstall-shiplog: missing $COMMON_LIB" >&2
  exit 1
fi

GUARD_LIB="$SCRIPT_ROOT/scripts/lib/install-guard.sh"
if [ -f "$GUARD_LIB" ]; then
  # shellcheck source=scripts/lib/install-guard.sh
  . "$GUARD_LIB"
else
  echo "uninstall-shiplog: missing $GUARD_LIB" >&2
  exit 1
fi
SHIPLOG_GUARD_LABEL="shiplog-uninstall"

REPO_URL=${SHIPLOG_REPO_URL:-https://github.com/flyingrobots/shiplog.git}
INSTALL_DIR=${SHIPLOG_HOME:-$HOME/.shiplog}
PROFILE_FILE=${SHIPLOG_PROFILE:-}
DRY_RUN=0
SILENT=0
NO_BACKUP=0
FORCE=0
FORCE_UNSAFE=0

REMOTE_NAME=$(shiplog_remote_name)

usage() {
  cat <<'USAGE'
Shiplog uninstaller

Usage: uninstall-shiplog.sh [options]

Options:
  --dry-run       show actions without performing them (runs the same safety checks)
  --silent        reduce logging
  --no-backup     do not create profile backups before editing
  --profile FILE  explicit profile to edit (default: auto-detect)
  --force         proceed even if local refs are ahead of origin
  --force-unsafe  skip the "is this a Shiplog checkout" check on SHIPLOG_HOME
                  (the deny-list, allowed-base and symlink checks still apply)
  -h, --help      show this help

Environment:
  SHIPLOG_HOME           install directory to remove (default: $HOME/.shiplog)
  SHIPLOG_REPO_URL       expected remote.origin.url of the checkout
  SHIPLOG_ALLOWED_BASES  colon-separated bases the install dir must live under
                         (default: $HOME:/opt/shiplog)
USAGE
}

log() { [ "$SILENT" -eq 1 ] || echo "[shiplog-uninstall] $*"; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@" || return $?
}

sanitize_profile() {
  local profile="$1" install_dir="$2"
  local tmp
  tmp=$(mktemp) || return 1
  if ! awk -v dir="$install_dir" '
    {
      stripped=$0
      sub(/^[[:space:]]+/, "", stripped)
      sub(/[[:space:]]+$/, "", stripped)
      if (stripped == "# Shiplog") next
      if (index($0, dir) > 0) {
        if (stripped ~ /^export[[:space:]]+SHIPLOG_HOME=/) next
        if (stripped ~ /^export[[:space:]]+PATH=/ && index($0, dir "/bin") > 0) next
      }
      print $0
    }
  ' "$profile" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$profile"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --silent) SILENT=1 ;;
    --no-backup) NO_BACKUP=1 ;;
    --profile)
      shift || { usage; exit 1; }
      PROFILE_FILE="$1"
      ;;
    --force) FORCE=1 ;;
    --force-unsafe) FORCE_UNSAFE=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift || break
done

if [ -z "$PROFILE_FILE" ]; then
  if [ -n "${ZDOTDIR:-}" ] && [ -f "$ZDOTDIR/.zshrc" ]; then
    PROFILE_FILE="$ZDOTDIR/.zshrc"
  elif [ -f "$HOME/.zshrc" ]; then
    PROFILE_FILE="$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then
    PROFILE_FILE="$HOME/.bashrc"
  elif [ -f "$HOME/.bash_profile" ]; then
    PROFILE_FILE="$HOME/.bash_profile"
  elif [ -f "$HOME/.profile" ]; then
    PROFILE_FILE="$HOME/.profile"
  fi
fi

# ---------------------------------------------------------------------------
# Safety gate: decide up front whether SHIPLOG_HOME may be removed. Nothing is
# mutated before this point, and a refusal exits non-zero under --dry-run too.
# ---------------------------------------------------------------------------
if ! RESOLVED_INSTALL_DIR=$(shiplog_guard_install_dir "$INSTALL_DIR" path "$REPO_URL"); then
  exit 1
fi
INSTALL_DIR="$RESOLVED_INSTALL_DIR"

REMOVE_INSTALL_DIR=0
if [ -e "$INSTALL_DIR" ]; then
  if [ ! -d "$INSTALL_DIR" ]; then
    echo "shiplog-uninstall: refusing: $INSTALL_DIR exists and is not a directory" >&2
    exit 1
  fi
  if [ "$FORCE_UNSAFE" -eq 1 ]; then
    log "Warning: --force-unsafe given; skipping Shiplog checkout verification for $INSTALL_DIR"
    export SHIPLOG_GUARD_SKIP_CHECKOUT_CHECK=1
  fi
  if ! shiplog_guard_install_dir "$INSTALL_DIR" destructive "$REPO_URL" >/dev/null; then
    echo "shiplog-uninstall: refusing to remove $INSTALL_DIR (not a Shiplog checkout cloned from $REPO_URL)." >&2
    echo "                   Set SHIPLOG_HOME to the Shiplog install directory, or remove it manually." >&2
    exit 1
  fi
  REMOVE_INSTALL_DIR=1
fi

git_config_remove_refspec() {
  local key="$1" target="$2"
  local values=()
  mapfile -t values < <(git config --get-all "$key" 2>/dev/null || true)
  [ ${#values[@]} -gt 0 ] || return 0

  local keep=()
  for val in "${values[@]}"; do
    if [ "$val" != "$target" ]; then
      keep+=("$val")
    fi
  done

  if [ ${#keep[@]} -eq ${#values[@]} ]; then
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "+ git config --unset-all $key"
    for val in ${keep[@]+"${keep[@]}"}; do
      echo "+ git config --add $key '$val'"
    done
    return
  fi

  git config --unset-all "$key" || true
  for val in ${keep[@]+"${keep[@]}"}; do
    git config --add "$key" "$val"
  done
}

# git ls-remote bounded by `timeout` only when that (non-POSIX) tool exists;
# otherwise rely on git's own transport timeouts. Prints the remote tip (or
# nothing when the ref is absent) and returns ls-remote's exit status, so the
# caller can tell "ref not on remote" from "remote unreachable".
ls_remote_tip() {
  local remote="$1" ref="$2"
  local out rc=0
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout 30 git ls-remote "$remote" "$ref" 2>/dev/null) || rc=$?
  else
    out=$(git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 ls-remote "$remote" "$ref" 2>/dev/null) || rc=$?
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out" | awk 'NR==1 {print $1}'
}

git_config_remove_refspec "remote.${REMOTE_NAME}.fetch" "+refs/_shiplog/*:refs/_shiplog/*"
git_config_remove_refspec "remote.${REMOTE_NAME}.push" "refs/_shiplog/*:refs/_shiplog/*"

unpublished_refs=()
unknown_refs=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git config --get "remote.${REMOTE_NAME}.url" >/dev/null 2>&1; then
  if command -v ssh >/dev/null 2>&1; then
    if ! run git fetch "$REMOTE_NAME" 'refs/_shiplog/*:refs/_shiplog/*'; then
      log "Warning: unable to fetch refs/_shiplog/*"
    fi
  else
    log "Warning: ssh client not available; skipping remote refs sync"
  fi
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    local_tip=$(git rev-parse "$ref" 2>/dev/null || echo "")
    [ -n "$local_tip" ] || continue
    remote_tip=""
    if ! remote_tip=$(ls_remote_tip "$REMOTE_NAME" "$ref"); then
      log "Warning: remote $REMOTE_NAME unreachable while checking $ref; publication state unknown"
      unknown_refs+=("$ref")
      continue
    fi
    if [ -z "$remote_tip" ]; then
      unpublished_refs+=("$ref")
      continue
    fi
    if [ "$local_tip" = "$remote_tip" ]; then
      continue
    fi
    if git merge-base --is-ancestor "$remote_tip" "$local_tip" >/dev/null 2>&1; then
      unpublished_refs+=("$ref")
    fi
  done < <(git for-each-ref --format='%(refname)' refs/_shiplog)
fi

if [ ${#unpublished_refs[@]} -gt 0 ] && [ "$FORCE" -eq 0 ]; then
  log "Aborting uninstall: local Shiplog refs not pushed to $REMOTE_NAME:"
  for ref in "${unpublished_refs[@]}"; do
    echo "  $ref"
  done
  log "Push them with: git push --no-verify $REMOTE_NAME <ref> (or rerun with --force)."
  exit 1
fi

if [ ${#unpublished_refs[@]} -gt 0 ] && [ "$FORCE" -eq 1 ] && [ "$SILENT" -ne 1 ]; then
  log "Proceeding despite unpushed refs: ${unpublished_refs[*]}"
fi

if [ ${#unknown_refs[@]} -gt 0 ] && [ "$SILENT" -ne 1 ]; then
  log "Could not verify publication of: ${unknown_refs[*]} (remote unreachable). Local refs in this repository are not removed by the uninstaller."
fi

# same_content A B: both are regular files with identical bytes. Uses git (a hard
# dependency) rather than cmp, which minimal arch/fedora images do not ship.
same_content() {
  [ -f "$1" ] && [ -f "$2" ] || return 1
  local a b
  a=$(git hash-object --no-filters -- "$1" 2>/dev/null) || return 1
  b=$(git hash-object --no-filters -- "$2" 2>/dev/null) || return 1
  [ -n "$a" ] && [ "$a" = "$b" ]
}

GIT_SHIPLOG_TARGET="$INSTALL_DIR/bin/git-shiplog"
BOSUN_TARGET="$INSTALL_DIR/scripts/bosun"

if [ -e "/usr/local/bin/git-shiplog" ]; then
  if [ -L "/usr/local/bin/git-shiplog" ] && [ "$(readlink "/usr/local/bin/git-shiplog")" = "$GIT_SHIPLOG_TARGET" ]; then
    log "Removing /usr/local/bin/git-shiplog"
    run rm -f /usr/local/bin/git-shiplog
  elif same_content "/usr/local/bin/git-shiplog" "$GIT_SHIPLOG_TARGET"; then
    log "Removing /usr/local/bin/git-shiplog (matching installed copy)"
    run rm -f /usr/local/bin/git-shiplog
  else
    log "Skipping removal of /usr/local/bin/git-shiplog (custom install detected)"
  fi
fi

for shim in shiplog bosun; do
  if command -v "$shim" >/dev/null 2>&1; then
    shim_path="$(command -v "$shim")"
    target="$GIT_SHIPLOG_TARGET"
    [ "$shim" = "bosun" ] && target="$BOSUN_TARGET"
    if [ -L "$shim_path" ] && [ "$(readlink "$shim_path")" = "$target" ]; then
      log "Removing $shim shim at $shim_path"
      run rm -f "$shim_path"
    elif same_content "$shim_path" "$target"; then
      log "Removing $shim shim at $shim_path (matching installed copy)"
      run rm -f "$shim_path"
    fi
  fi
done

if [ "$REMOVE_INSTALL_DIR" -eq 1 ]; then
  log "Removing $INSTALL_DIR"
  run rm -rf "$INSTALL_DIR"
else
  log "Install directory $INSTALL_DIR not found"
fi

if [ -n "$PROFILE_FILE" ] && [ -f "$PROFILE_FILE" ]; then
  if [ "$DRY_RUN" -eq 0 ] && [ "$NO_BACKUP" -eq 0 ]; then
    if [ ! -f "$PROFILE_FILE.shiplog.bak" ]; then
      log "Creating backup $PROFILE_FILE.shiplog.bak"
      cp "$PROFILE_FILE" "$PROFILE_FILE.shiplog.bak"
    fi
  fi
  log "Cleaning Shiplog lines from $PROFILE_FILE"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "+ removing Shiplog entries from $PROFILE_FILE"
  else
    if ! sanitize_profile "$PROFILE_FILE" "$INSTALL_DIR"; then
      log "Error: failed to clean $PROFILE_FILE; leaving original in place."
    fi
  fi
else
  log "Profile file not found or unspecified; remove PATH/SHIPLOG_HOME entries manually if needed."
fi

log "Shiplog uninstall complete"
if [ "$SILENT" -ne 1 ]; then
  echo "Remote refs under refs/_shiplog/* were left intact on your remotes; remove them manually only if you intend to delete history."
fi
