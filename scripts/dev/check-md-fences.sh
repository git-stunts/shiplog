#!/usr/bin/env bash
# check-md-fences.sh — every Markdown file must open and close its code fences.
#
# For each tracked *.md file (or each file given as an argument) the number of
# lines matching ^\s*(> )?``` must be even. An odd count means a fence was
# opened and never closed, so everything after it renders as code.
#
# Usage: scripts/dev/check-md-fences.sh [FILE...]
# Exit:  0 when every file is balanced; 1 when any file is not, a named file is
#        missing, or no Markdown file was found to check.
#
# Portable: bash 3.2+, POSIX grep/sed; runs on macOS and Alpine.
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root"

status=0
checked=0

check_file() {
  local file="$1" count
  if [ ! -f "$file" ]; then
    printf '%s: no such file\n' "$file"
    status=1
    return 0
  fi
  checked=$((checked + 1))
  count=$(grep -cE '^[[:space:]]*(> )?```' "$file" || true)
  if [ $((count % 2)) -ne 0 ]; then
    printf '%s: %s fence line(s); a code fence is never closed\n' "$file" "$count"
    status=1
  fi
}

if [ "$#" -gt 0 ]; then
  for f in "$@"; do check_file "$f"; done
else
  while IFS= read -r f; do
    check_file "$f"
  done < <(git ls-files -- '*.md')
fi

if [ "$checked" -eq 0 ] && [ "$status" -eq 0 ]; then
  # Nothing checked (not a Git checkout, git failed, or no tracked *.md):
  # an empty run must not report success.
  printf 'check-md-fences: no Markdown files found to check\n' >&2
  exit 1
fi

if [ "$status" -ne 0 ]; then
  printf 'check-md-fences: unbalanced code fences found\n' >&2
else
  printf 'check-md-fences: %s file(s) OK\n' "$checked"
fi
exit "$status"
