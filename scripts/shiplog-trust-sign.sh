#!/usr/bin/env bash
set -euo pipefail

# shiplog-trust-sign.sh — create a detached SSH signature (.sig) for the trust tree
# Usage:
#   scripts/shiplog-trust-sign.sh [--principal you@example.com] [--namespace shiplog-trust]
#                                 [--out .shiplog/trust_sigs] [--message-only]
#                                 [COMMIT]
#
# Signs the payload:
#   shiplog-trust-tree-v1\n<trust_tree_oid>\n<trust_id>\n<threshold>\n
#
# and writes a signature file under <out>/<principal>.sig. It uses ssh-keygen -Y sign
# with a configured SSH signing key (git config user.signingkey) by default.

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
  --principal <email>      SSH principal to record in the signature filename
  --namespace <ns>         ssh-keygen signature namespace (default: shiplog-trust)
  --out <dir>              Output directory for .sig files (default: .shiplog/trust_sigs)
  --message-only           Print canonical payload to stdout and exit (no signing)
EOF
      exit 0 ;;
    *) break ;;
  esac
  shift || true
done

TRUST_COMMIT="${1:-}"
[ -n "$TRUST_COMMIT" ] || TRUST_COMMIT="$(git rev-parse --verify "${SHIPLOG_TRUST_REF:-refs/_shiplog/trust/root}" 2>/dev/null || true)"
[ -n "$TRUST_COMMIT" ] || die "cannot resolve trust commit; pass COMMIT or set SHIPLOG_TRUST_REF"

trust_tree="$(git show -s --format='%T' "$TRUST_COMMIT")"
[ -n "$trust_tree" ] || die "cannot resolve trust tree for $TRUST_COMMIT"
trust_json="$(git show "$TRUST_COMMIT:trust.json" 2>/dev/null || true)"
[ -n "$trust_json" ] || die "trust.json not found at $TRUST_COMMIT:trust.json"

trust_id="$(printf '%s' "$trust_json" | jq -r '.id // "shiplog-trust-root"')"
threshold="$(printf '%s' "$trust_json" | jq -r '.threshold // 1')"

payload=$(printf 'shiplog-trust-tree-v1\n%s\n%s\n%s\n' "$trust_tree" "$trust_id" "$threshold")

if [ "$MESSAGE_ONLY" -eq 1 ]; then
  printf '%s' "$payload"
  exit 0
fi

if [ -z "$PRINCIPAL" ]; then
  PRINCIPAL="${GIT_AUTHOR_EMAIL:-$(git config user.email || true)}"
fi
[ -n "$PRINCIPAL" ] || die "principal email is required (set --principal or git config user.email)"

signing_key="$(git config user.signingkey 2>/dev/null || true)"
[ -n "$signing_key" ] || die "git config user.signingkey is not set (SSH private key path)"
[ -r "$signing_key" ] || die "signing key not readable: $signing_key"

mkdir -p "$OUTDIR"
sig_file="$OUTDIR/$PRINCIPAL.sig"
tmp_in=$(mktemp)
printf '%s' "$payload" > "$tmp_in"

ssh-keygen -Y sign -f "$signing_key" -n "$NAMESPACE" - < "$tmp_in" > "$sig_file" 2>/dev/null \
  || die "ssh-keygen failed to sign payload"

echo "✅ wrote $sig_file"

