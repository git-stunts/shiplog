#!/usr/bin/env bash
set -euo pipefail

# shiplog-trust-sign.sh — create a detached SSH signature (.sig) attesting a trust document
# Usage:
#   scripts/shiplog-trust-sign.sh [--principal you@example.com] [--namespace shiplog-trust]
#                                 [--out .shiplog/trust_sigs] [--message-only]
#                                 [COMMIT]
#
# Signs the canonical attestation payload built by lib/trust-verify.sh
# (trust_verify_payload), which is exactly what the pre-receive hook and
# scripts/shiplog-verify-trust.sh verify:
#
#   shiplog-trust-tree-v1\n<base_tree_oid>\n<trust_id>\n<threshold>\n
#
# where <base_tree_oid> is the tree holding only trust.json (and allowed_signers
# when present) of COMMIT, never the trust_sigs directory. The signature is
# written to <out>/<principal>.sig using ssh-keygen -Y sign with the SSH key
# from `git config user.signingkey`.
#
# The quorum counts KEYS, not filenames: the server binds each .sig to a roster
# key and principal with `ssh-keygen -Y find-principals`. The filename is a
# convenience for humans; --principal must still be the principal listed for
# your key in allowed_signers (usually your e-mail).

die() { echo "❌ $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

need git; need ssh-keygen; need jq

PRINCIPAL="${SHIPLOG_TRUST_PRINCIPAL:-}"         # default to GIT author email if unset
NAMESPACE="${SHIPLOG_TRUST_NAMESPACE:-shiplog-trust}"
OUTDIR="${SHIPLOG_TRUST_SIG_DIR:-.shiplog/trust_sigs}"
MESSAGE_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --principal) shift; PRINCIPAL="${1:-}" ;;
    --principal=*) PRINCIPAL="${1#*=}" ;;
    --namespace) shift; NAMESPACE="${1:-}" ;;
    --namespace=*) NAMESPACE="${1#*=}" ;;
    --out) shift; OUTDIR="${1:-}" ;;
    --out=*) OUTDIR="${1#*=}" ;;
    --message-only) MESSAGE_ONLY=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/shiplog-trust-sign.sh [options] [COMMIT]

Options:
  --principal <email>      SSH principal (as listed in allowed_signers); also names the .sig file
  --namespace <ns>         ssh-keygen signature namespace (default: shiplog-trust)
  --out <dir>              Output directory for .sig files (default: .shiplog/trust_sigs)
  --message-only           Print the exact canonical payload to stdout and exit (no signing)
EOF
      exit 0 ;;
    *) break ;;
  esac
  shift || true
done

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
[ -n "$TRUST_VERIFY_LIB" ] || die "lib/trust-verify.sh not found (looked next to this script and under SHIPLOG_HOME)"
# shellcheck source=../lib/trust-verify.sh
. "$TRUST_VERIFY_LIB"
export SHIPLOG_TRUST_NAMESPACE="$NAMESPACE"

TRUST_COMMIT="${1:-}"
[ -n "$TRUST_COMMIT" ] || TRUST_COMMIT="$(git rev-parse --verify "${SHIPLOG_TRUST_REF:-${SHIPLOG_REF_ROOT:-refs/_shiplog}/trust/root}" 2>/dev/null || true)"
[ -n "$TRUST_COMMIT" ] || die "cannot resolve trust commit; pass COMMIT or set SHIPLOG_TRUST_REF"
git cat-file -e "$TRUST_COMMIT:trust.json" 2>/dev/null || die "trust.json not found at $TRUST_COMMIT:trust.json"

payload_file="$(mktemp)"
trap 'rm -f "$payload_file"' EXIT
trust_verify_payload "$TRUST_COMMIT" > "$payload_file" || die "failed to build attestation payload for $TRUST_COMMIT"

if [ "$MESSAGE_ONLY" -eq 1 ]; then
  cat "$payload_file"
  exit 0
fi

if [ -z "$PRINCIPAL" ]; then
  PRINCIPAL="${GIT_AUTHOR_EMAIL:-$(git config user.email || true)}"
fi
[ -n "$PRINCIPAL" ] || die "principal email is required (set --principal or git config user.email)"
case "$PRINCIPAL" in
  */*|*'*'*|*'?'*) die "principal must be a plain identifier without / * or ? (got: $PRINCIPAL)" ;;
esac

signing_key="$(git config user.signingkey 2>/dev/null || true)"
[ -n "$signing_key" ] || die "git config user.signingkey is not set (SSH private key path)"
case "$signing_key" in
  ~/*) signing_key="$HOME/${signing_key#~/}" ;;
esac
[ -r "$signing_key" ] || die "signing key not readable: $signing_key"

mkdir -p "$OUTDIR"
sig_file="$OUTDIR/$PRINCIPAL.sig"

ssh-keygen -Y sign -f "$signing_key" -n "$NAMESPACE" - < "$payload_file" > "$sig_file" 2>/dev/null \
  || die "ssh-keygen failed to sign payload"

echo "✅ wrote $sig_file"
