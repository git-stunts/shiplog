#!/usr/bin/env bash
set -euo pipefail

# shiplog-migrate-ref-root.sh
# Safely mirror all Shiplog refs from one root to another and optionally push.
#
# Usage:
#   shiplog-migrate-ref-root.sh --to refs/heads/_shiplog [--from refs/_shiplog] [--remove-old] [--push] [--dry-run]
#
# Defaults:
#   --from is taken from SHIPLOG_REF_ROOT or git config shiplog.refRoot, else refs/_shiplog
#   --to must be provided explicitly
#
# Every ref kind under the root moves: journal/<env>, anchors/<env>, policy/current,
# trust/root and notes/logs. Enumeration uses a prefix match (no glob) because
# `git for-each-ref 'ROOT/*'` is path-aware and never descends into nested refs.

usage() {
  cat <<'USAGE'
shiplog-migrate-ref-root.sh

Mirror all Shiplog refs from one root to another (e.g., refs/_shiplog -> refs/heads/_shiplog).

Options:
  --to ROOT         Destination root (required), e.g. refs/heads/_shiplog
  --from ROOT       Source root (default: SHIPLOG_REF_ROOT or git config shiplog.refRoot or refs/_shiplog)
  --remove-old      Delete old refs after mirroring
  --push            Push mirrored refs to the configured remote (defaults to origin)
  --dry-run         Print the plan without making changes
  -h, --help        Show this help

Notes:
  - Every ref under the source root is mirrored (journal/*, anchors/*, policy/current,
    trust/root, notes/logs), including nested names.
  - Uses git update-ref to write new refs atomically.
  - Writes `git config shiplog.refRoot <TO>` so the CLI uses the new root afterwards
    (SHIPLOG_REF_ROOT in the environment still takes precedence; update or unset it).
  - With --push, runs: git push --no-verify <remote> '<TO>/*:<TO>/*' (remote defaults to origin or SHIPLOG_REMOTE)
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIPLOG_HOME="${SHIPLOG_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
GIT_LIB="$SHIPLOG_HOME/lib/git.sh"
if [ -f "$GIT_LIB" ]; then
  # lib/git.sh sources lib/common.sh and provides shiplog_normalize_ref_root
  # and shiplog_remote_name.
  # shellcheck disable=SC1090
  . "$GIT_LIB"
else
  echo "shiplog-migrate-ref-root: missing $GIT_LIB" >&2
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }

DRY=0 REMOVE_OLD=0 DO_PUSH=0 FROM_ROOT="" TO_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) shift; TO_ROOT="${1:-}" ;;
    --to=*) TO_ROOT="${1#*=}" ;;
    --from) shift; FROM_ROOT="${1:-}" ;;
    --from=*) FROM_ROOT="${1#*=}" ;;
    --remove-old) REMOVE_OLD=1 ;;
    --push) DO_PUSH=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift || true
done

need git
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Run inside a git repo." >&2; exit 1; }

if [ -z "$FROM_ROOT" ]; then
  FROM_ROOT="${SHIPLOG_REF_ROOT:-}"
fi
if [ -z "$FROM_ROOT" ]; then
  FROM_ROOT="$(git config --get shiplog.refRoot 2>/dev/null || true)"
fi
FROM_ROOT="${FROM_ROOT:-refs/_shiplog}"

if [ -z "$TO_ROOT" ]; then
  echo "--to is required (e.g., --to refs/heads/_shiplog)" >&2
  exit 1
fi

if ! FROM_ROOT=$(shiplog_normalize_ref_root "$FROM_ROOT"); then
  echo "--from must be a ref prefix starting with refs/ (e.g. refs/_shiplog)" >&2
  exit 1
fi
if ! TO_ROOT=$(shiplog_normalize_ref_root "$TO_ROOT"); then
  echo "--to must be a ref prefix starting with refs/ (e.g. refs/heads/_shiplog)" >&2
  exit 1
fi

if [ "$FROM_ROOT" = "$TO_ROOT" ]; then
  echo "Source and destination roots are identical; nothing to do." >&2
  exit 0
fi
case "$TO_ROOT" in
  "$FROM_ROOT"/*)
    echo "Destination root $TO_ROOT is nested under source root $FROM_ROOT; refusing to migrate into itself." >&2
    exit 1
    ;;
esac

echo "Source root:      $FROM_ROOT"
echo "Destination root: $TO_ROOT"
echo

# Collect source refs. A bare prefix (no glob) matches every ref below it,
# nested names included; 'ROOT/*' would stop at the first slash.
refs=()
while IFS= read -r line; do
  [ -n "$line" ] && refs+=("$line")
done < <(git for-each-ref --format='%(refname) %(objectname)' "$FROM_ROOT")
if [ ${#refs[@]} -eq 0 ]; then
  echo "No refs under $FROM_ROOT to migrate."
  exit 0
fi

actions=()
for line in "${refs[@]}"; do
  src_ref="${line% *}"
  oid="${line#* }"
  dst_ref="$TO_ROOT/${src_ref#"${FROM_ROOT}"/}"
  actions+=("$oid $dst_ref $src_ref")
done

echo "Will mirror the following refs:"
for a in "${actions[@]}"; do
  oid=${a%% *}; rest=${a#* }; dst=${rest%% *}; src=${rest#* }
  printf '  %s -> %s (%s)\n' "$src" "$dst" "$oid"
done
if [ "$REMOVE_OLD" -eq 1 ]; then
  echo "Will delete the source refs after mirroring (--remove-old)."
fi
echo "Will set git config shiplog.refRoot = $TO_ROOT"
if [ "$DO_PUSH" -eq 1 ]; then
  echo "Will push $TO_ROOT/* to $(shiplog_remote_name) (--push)"
fi

echo
if [ "$DRY" -eq 1 ]; then
  echo "Dry-run: no changes made."
  exit 0
fi

# Update destination refs
for a in "${actions[@]}"; do
  oid=${a%% *}; rest=${a#* }; dst=${rest%% *}
  git update-ref "$dst" "$oid"
done

if [ "$REMOVE_OLD" -eq 1 ]; then
  for a in "${actions[@]}"; do
    rest=${a#* }; src=${rest#* }
    git update-ref -d "$src"
    # Shiplog points refs/notes/<notes ref> at the real notes ref so `git notes
    # --ref=` reaches it; drop that alias with the ref instead of leaving it dangling.
    if [ "$(git symbolic-ref -q "refs/notes/$src" 2>/dev/null || true)" = "$src" ]; then
      git symbolic-ref --delete "refs/notes/$src"
    fi
  done
fi

git config shiplog.refRoot "$TO_ROOT"
echo "Set git config shiplog.refRoot = $TO_ROOT"
if [ -n "${SHIPLOG_REF_ROOT:-}" ] && [ "${SHIPLOG_REF_ROOT%/}" != "$TO_ROOT" ]; then
  echo "Note: SHIPLOG_REF_ROOT=$SHIPLOG_REF_ROOT is set in the environment and takes precedence over git config; update or unset it to use $TO_ROOT." >&2
fi

REMOTE_NAME="$(shiplog_remote_name)"

if [ "$DO_PUSH" -eq 1 ]; then
  if git config --get remote."$REMOTE_NAME".url >/dev/null 2>&1; then
    echo "Pushing mirrored refs to $REMOTE_NAME..."
    git push --no-verify "$REMOTE_NAME" "$TO_ROOT/*:$TO_ROOT/*"
  else
    echo "Remote $REMOTE_NAME not configured; skipping push." >&2
  fi
fi

echo "Done."
