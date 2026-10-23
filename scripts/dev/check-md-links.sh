#!/usr/bin/env bash
# check-md-links.sh — every relative Markdown link must point at a file that exists.
#
# For each tracked *.md file (or each file given as an argument) every inline
# link or image target `](target)` outside a code fence is resolved relative to
# the file (a leading `/` means the repository root, as on GitHub). `#anchor`
# fragments and `"titles"` are stripped; http(s)://, mailto: and pure-anchor
# links are ignored. Missing targets are printed as `file:line target`.
#
# Usage: scripts/dev/check-md-links.sh [FILE...]
# Exit:  0 when every target exists; 1 when any is missing, a named file is
#        missing, or no Markdown file was found to check.
#
# Portable: bash 3.2+, POSIX tools only; runs on macOS and Alpine.
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root"

status=0
checked=0
link_re='\]\(([^)]*)\)'
fence_re='^[[:space:]]*(> )?```'

check_file() {
  local file="$1" dir line lineno rest target path in_fence
  if [ ! -f "$file" ]; then
    printf '%s: no such file\n' "$file"
    status=1
    return 0
  fi
  checked=$((checked + 1))
  dir="$(dirname "$file")"
  lineno=0
  in_fence=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [[ $line =~ $fence_re ]]; then
      in_fence=$((1 - in_fence))
      continue
    fi
    [ "$in_fence" -eq 1 ] && continue
    rest="$line"
    while [[ $rest =~ $link_re ]]; do
      target="${BASH_REMATCH[1]}"
      rest="${rest#*"${BASH_REMATCH[0]}"}"
      # Strip surrounding <...>, an optional "title", and any #fragment.
      target="${target#<}"
      target="${target%>}"
      target="${target%% \"*}"
      target="${target%% \'*}"
      path="${target%%#*}"
      case "$path" in
        ''|http://*|https://*|mailto:*) continue ;;
      esac
      case "$path" in
        /*) path="./${path#/}" ;;
        *)  path="$dir/$path" ;;
      esac
      if [ ! -e "$path" ]; then
        printf '%s:%s %s\n' "$file" "$lineno" "$target"
        status=1
      fi
    done
  done < "$file"
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
  printf 'check-md-links: no Markdown files found to check\n' >&2
  exit 1
fi

if [ "$status" -ne 0 ]; then
  printf 'check-md-links: broken relative links found\n' >&2
else
  printf 'check-md-links: %s file(s) OK\n' "$checked"
fi
exit "$status"
