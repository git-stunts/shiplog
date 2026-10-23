#!/usr/bin/env bash
set -euo pipefail

# shiplog-verify-trust.sh — verify one update of the trust ref.
#
# Usage:
#   shiplog-verify-trust.sh --old <old_oid|0> --new <new_oid> [--ref <ref>]
#
# Thin wrapper around lib/trust-verify.sh, the module the pre-receive hook
# sources as well, so CI required checks and the server apply the same rules:
#   - Rotations are verified against the PRIOR roster (OLD); genesis (OLD = 0)
#     against its own content.
#   - sig_mode=attestation: at least <threshold> attestations under
#     .shiplog/trust_sigs/ from distinct, unrevoked maintainer keys.
#   - sig_mode=chain: threshold 1 only; the single trust commit must be signed
#     by a current maintainer (rotations always; genesis when
#     SHIPLOG_REQUIRE_SIGNED_TRUST is enabled).
#   - SHIPLOG_REQUIRE_SIGNED_TRUST=1 additionally requires the trust commit
#     itself to be signed by a current maintainer in attestation mode.
#   - SHIPLOG_ALLOW_TRUST_THRESHOLD_UNENFORCED=1 is the only escape hatch and
#     prints a loud warning.
# Set SHIPLOG_DEBUG_SSH_VERIFY=1 for verbose diagnostics.

err() { echo "❌ shiplog: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "missing dependency: $1"; }

OLD=""; NEW=""; REF="${SHIPLOG_TRUST_REF:-${SHIPLOG_REF_ROOT:-refs/_shiplog}/trust/root}"
while [ $# -gt 0 ]; do
  case "$1" in
    --old) shift; OLD="${1:-}" ;;
    --old=*) OLD="${1#*=}" ;;
    --new) shift; NEW="${1:-}" ;;
    --new=*) NEW="${1#*=}" ;;
    --ref) shift; REF="${1:-}" ;;
    --ref=*) REF="${1#*=}" ;;
    -h|--help)
      sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) err "unknown arg: $1" ;;
  esac
  shift || true
done

[ -n "$NEW" ] || err "--new is required"
case "$OLD" in
  ''|0) OLD="0000000000000000000000000000000000000000" ;;
esac

JQ_BIN="${SHIPLOG_JQ_BIN:-jq}"
need git; need "$JQ_BIN"
export JQ_BIN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRUST_VERIFY_LIB=""
for candidate in \
  "${SHIPLOG_TRUST_VERIFY_LIB:-}" \
  "$SCRIPT_DIR/../lib/trust-verify.sh" \
  "${SHIPLOG_HOME:+$SHIPLOG_HOME/lib/trust-verify.sh}"; do
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then
    TRUST_VERIFY_LIB="$candidate"
    break
  fi
done
[ -n "$TRUST_VERIFY_LIB" ] || err "lib/trust-verify.sh not found (looked next to this script and under SHIPLOG_HOME)"
# shellcheck source=../lib/trust-verify.sh
. "$TRUST_VERIFY_LIB"

# Keep every temporary file under one trap-cleaned directory (honors TMPDIR).
TRUST_VERIFY_TMP="$(mktemp -d)"
trap 'trust_verify_cleanup' EXIT

git cat-file -e "$NEW^{commit}" 2>/dev/null || err "cannot resolve new trust commit $NEW in $REF"

if trust_verify_update "$OLD" "$NEW" "$REF"; then
  echo "✅ shiplog: trust update verified for $REF (${OLD:0:12} -> ${NEW:0:12}; sig_mode=${TV_SIG_MODE:-?} threshold=${TV_THRESHOLD:-?})"
  exit 0
fi
err "trust verification failed for $REF (${OLD:0:12} -> ${NEW:0:12})"
