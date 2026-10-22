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

usage() {
  cat <<'USAGE'
shiplog-migrate-ref-root.sh

Mirror all Shiplog refs from one root to another (e.g., refs/_shiplog -> refs/heads/_shiplog).

Options:
  --to ROOT         Destination root (required), e.g. refs/heads/_shiplog
  --from ROOT       Source root (default: SHIPLOG_REF_ROOT or git config shiplog.refRoot or refs/_shiplog)
  --remove-old      Delete old refs after mirroring
  --push            Push mirrored refs to the configured remote (defaults to origin)
  --dry-run         Print actions without making changes
  -h, --help        Show this help

Notes:
  - Only refs under the source root are touched.
  - Uses git update-ref to write new refs atomically.
  - With --push, runs: git push --no-verify <remote> '<TO>/*:<TO>/*' (remote defaults to origin or SHIPLOG_REMOTE)
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIPLOG_HOME="${SHIPLOG_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
COMMON_LIB="$SHIPLOG_HOME/lib/common.sh"
if [ -f "$COMMON_LIB" ]; then
  # shellcheck disable=SC1090
  . "$COMMON_LIB"
else
  echo "shiplog-migrate-ref-root: missing $COMMON_LIB" >&2
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }

DRY=0 REMOVE_OLD=0 DO_PUSH=0 FROM_ROOT="" TO_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) shift; TO_ROOT="${1:-}" ;;
    --from) shift; FROM_ROOT="${1:-}" ;;
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

case "$FROM_ROOT" in refs/*) : ;; *) echo "--from must start with refs/" >&2; exit 1 ;; esac
case "$TO_ROOT" in refs/*) : ;; *) echo "--to must start with refs/" >&2; exit 1 ;; esac

if [ "$FROM_ROOT" = "$TO_ROOT" ]; then
  echo "Source and destination roots are identical; nothing to do." >&2
  exit 0
fi

echo "Source root:      $FROM_ROOT"
echo "Destination root: $TO_ROOT"
echo

# Collect source refs
mapfile -t refs < <(git for-each-ref "$FROM_ROOT/*" --format='%(refname) %(objectname)')
if [ ${#refs[@]} -eq 0 ]; then
  echo "No refs under $FROM_ROOT to migrate."
  exit 0
fi

actions=()
for line in "${refs[@]}"; do
  src_ref="${line% *}"
  oid="${line#* }"
  dst_ref="$TO_ROOT/${src_ref#${FROM_ROOT}/}"
  actions+=("$oid $dst_ref $src_ref")
done

echo "Will mirror the following refs:"
for a in "${actions[@]}"; do
  oid=${a%% *}; rest=${a#* }; dst=${rest%% *}; src=${rest#* }
  printf '  %s -> %s (%s)\n' "$src" "$dst" "$oid"
done

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
  done
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
