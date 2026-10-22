#!/usr/bin/env bash
set -euo pipefail

REPO_URL=${SHIPLOG_REPO_URL:-https://github.com/flyingrobots/shiplog.git}
INSTALL_DIR=${SHIPLOG_HOME:-$HOME/.shiplog}
PROFILE_FILE=${SHIPLOG_PROFILE:-}
FORCE_CLONE=0
DRY_RUN=0
SILENT=0
SKIP_PROFILE=0

# Shared path guard (also used by scripts/uninstall-shiplog.sh). The installer
# runs from a checkout, so the guard lives next to it; fail closed if missing.
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_LIB="$INSTALLER_DIR/lib/install-guard.sh"
if [ -f "$GUARD_LIB" ]; then
  # shellcheck source=scripts/lib/install-guard.sh
  . "$GUARD_LIB"
else
  echo "install-shiplog: missing $GUARD_LIB (run the installer from a Shiplog checkout)" >&2
  exit 1
fi
SHIPLOG_GUARD_LABEL="shiplog-install"

usage() {
  cat <<'USAGE'
Shiplog bootstrap installer

Usage: install-shiplog.sh [options]

Options:
  --force         replace an existing Shiplog checkout at the install directory
  --profile FILE  shell profile to update (default: auto-detect)
  --dry-run       show what would happen without making changes
  --silent        reduce logging
  --no-profile    do not modify any shell profile (print instructions instead)
  -h, --help      show this help

Environment:
  SHIPLOG_HOME           install directory (default: $HOME/.shiplog)
  SHIPLOG_REPO_URL       repository to clone (default: upstream Shiplog)
  SHIPLOG_ALLOWED_BASES  colon-separated bases the install dir must live under
                         (default: $HOME:/opt/shiplog)

The installer never resets or removes a directory unless it is strictly inside
an allowed base, is not a symlink, contains bin/git-shiplog and has
remote.origin.url pointing at SHIPLOG_REPO_URL.
USAGE
}

log() { [ "$SILENT" -eq 1 ] || echo "[shiplog-install] $*"; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@" || return $?
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE_CLONE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --silent) SILENT=1 ;;
    --no-profile) SKIP_PROFILE=1 ;;
    --profile)
      shift || { usage; exit 1; }
      PROFILE_FILE="$1"
      ;;
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

# Path guard: canonicalize, deny-list, allowed bases, symlink rule. Any
# refusal exits non-zero, also under --dry-run.
if ! RESOLVED_INSTALL_DIR=$(shiplog_guard_install_dir "$INSTALL_DIR" path "$REPO_URL"); then
  exit 1
fi
INSTALL_DIR="$RESOLVED_INSTALL_DIR"
log "Install dir: $INSTALL_DIR"

if [ -e "$INSTALL_DIR" ]; then
  if [ ! -d "$INSTALL_DIR" ]; then
    echo "Error: $INSTALL_DIR exists and is not a directory" >&2
    exit 1
  fi
  # Destructive operations (rm -rf, reset --hard) require evidence that the
  # directory is a Shiplog checkout: bin/git-shiplog plus a matching origin URL.
  if ! shiplog_guard_install_dir "$INSTALL_DIR" destructive "$REPO_URL" >/dev/null; then
    echo "Error: refusing to modify $INSTALL_DIR (not a Shiplog checkout cloned from $REPO_URL)." >&2
    echo "       Point SHIPLOG_HOME at an empty path or remove the directory manually." >&2
    exit 1
  fi
  if [ "$FORCE_CLONE" -eq 1 ]; then
    log "Removing existing Shiplog checkout"
    run rm -rf "$INSTALL_DIR"
    log "Cloning repo from $REPO_URL"
    run git clone "$REPO_URL" "$INSTALL_DIR"
  else
    log "Directory already exists; pulling latest"
    default_branch=$(git -C "$INSTALL_DIR" remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
    if [ -z "$default_branch" ]; then
      for candidate in main master; do
        if git -C "$INSTALL_DIR" show-ref --verify --quiet "refs/remotes/origin/$candidate"; then
          default_branch="$candidate"
          break
        fi
      done
    fi
    if [ -z "$default_branch" ]; then
      echo "Error: unable to determine origin default branch for $INSTALL_DIR" >&2
      exit 1
    fi
    run git -C "$INSTALL_DIR" fetch origin "$default_branch"
    run git -C "$INSTALL_DIR" reset --hard "origin/$default_branch"
  fi
else
  log "Cloning repo from $REPO_URL"
  run git clone "$REPO_URL" "$INSTALL_DIR"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  log "Running dependency installer"
  if [ ! -f "$INSTALL_DIR/install-shiplog-deps.sh" ]; then
    log "Error: install-shiplog-deps.sh not found in $INSTALL_DIR"
    exit 1
  fi
  # Basic validation of the dependency installer
  if [ ! -x "$INSTALL_DIR/install-shiplog-deps.sh" ]; then
    echo "Error: install-shiplog-deps.sh is not executable" >&2
    exit 1
  fi
  # Check it's actually a file, not a symlink to something dangerous
  if [ -L "$INSTALL_DIR/install-shiplog-deps.sh" ]; then
    echo "Error: install-shiplog-deps.sh is a symlink - security risk" >&2
    exit 1
  fi
  deps_args=()
  [ "$SILENT" -eq 1 ] && deps_args+=(--silent)
  (cd "$INSTALL_DIR" && ./install-shiplog-deps.sh ${deps_args[@]+"${deps_args[@]}"})
  if [ -x "$INSTALL_DIR/scripts/bosun" ]; then
    log "Linking bosun helper into bin/"
    mkdir -p "$INSTALL_DIR/bin"
    ln -sf "$INSTALL_DIR/scripts/bosun" "$INSTALL_DIR/bin/bosun"
  fi
  # Refresh tool-owned Shiplog refs inside the installer repo (never mutate the caller's repo)
  if git -C "$INSTALL_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "Fetching Shiplog refs from origin into $INSTALL_DIR (force)"
    # Tool refs are disposable; refresh with force to avoid non-FF issues
    if ! run git -C "$INSTALL_DIR" fetch origin '+refs/_shiplog/*:refs/_shiplog/*'; then
      log "Warning: unable to fetch installer refs/_shiplog/*"
    fi
  else
    log "(Skipping installer refs fetch; $INSTALL_DIR is not a git worktree)"
  fi
else
  log "Would run dependency installer"
  if [ -x "$INSTALL_DIR/scripts/bosun" ]; then
    log "Would link $INSTALL_DIR/scripts/bosun -> $INSTALL_DIR/bin/bosun"
  fi
fi

BIN_LINE="export PATH=\"$INSTALL_DIR/bin:\$PATH\""
HOME_LINE="export SHIPLOG_HOME=\"$INSTALL_DIR\""
PROFILE_UPDATED=0

if [ "$SKIP_PROFILE" -eq 0 ] && [ -n "$PROFILE_FILE" ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    touch "$PROFILE_FILE"
    if [ ! -f "$PROFILE_FILE.bak" ]; then
      log "Creating backup $PROFILE_FILE.bak"
      cp "$PROFILE_FILE" "$PROFILE_FILE.bak"
    fi
    if ! grep -E "^[[:space:]]*export[[:space:]]+SHIPLOG_HOME=" "$PROFILE_FILE" >/dev/null 2>&1; then
      log "Updating $PROFILE_FILE"
      printf '\n# Shiplog\nexport SHIPLOG_HOME="%s"\nexport PATH="%s/bin:$PATH"\n' "$INSTALL_DIR" "$INSTALL_DIR" >> "$PROFILE_FILE"
      PROFILE_UPDATED=1
    else
      log "$PROFILE_FILE already references SHIPLOG_HOME; skipping"
    fi
  else
    log "Would append env vars to $PROFILE_FILE"
  fi
else
  log "No shell profile updated; export vars manually:"
  log "  $HOME_LINE"
  log "  $BIN_LINE"
fi

cat <<INFO

Shiplog installed!
Reload your shell or run:
  $HOME_LINE
  $BIN_LINE
Then test with:
  git shiplog --help
INFO

if [ "$PROFILE_UPDATED" -eq 1 ]; then
  echo "(Appended PATH setup to $PROFILE_FILE)"
fi
