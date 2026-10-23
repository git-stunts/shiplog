#!/usr/bin/env sh
set -eu

TRUST_REF="${1:-refs/_shiplog/trust/root}"
DEST="${2:-.shiplog/allowed_signers}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'shiplog-trust-sync: must run inside a git repository\n' >&2
  exit 1
fi

TIP="$(git rev-parse -q --verify "$TRUST_REF" 2>/dev/null || true)"
if [ -z "$TIP" ]; then
  printf 'shiplog-trust-sync: trust ref %s not found (did you fetch it?)\n' "$TRUST_REF" >&2
  exit 1
fi

BLOB="$(git ls-tree -r "$TIP" | awk '$4=="allowed_signers"{print $3; exit}')"
if [ -z "$BLOB" ]; then
  printf 'shiplog-trust-sync: trust ref %s does not contain an allowed_signers blob\n' "$TRUST_REF" >&2
  exit 1
fi

DEST_DIR="$(dirname "$DEST")"
mkdir -p "$DEST_DIR"

# Git resolves gpg.ssh.allowedSignersFile relative to the process working
# directory (only ~ is expanded), so store an absolute path: verification from
# a subdirectory or a CI step that cd's must still find the roster.
DEST_DIR_ABS="$(cd "$DEST_DIR" && pwd -P)"
DEST_ABS="$DEST_DIR_ABS/$(basename "$DEST")"

git cat-file -p "$BLOB" > "$DEST_ABS"
chmod 600 "$DEST_ABS"

git config gpg.ssh.allowedSignersFile "$DEST_ABS"

printf '✅ installed allowed_signers from %s → %s\n' "$TRUST_REF" "$DEST_ABS"
