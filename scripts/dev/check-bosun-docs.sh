#!/usr/bin/env bash
# check-bosun-docs.sh — keep docs/bosun/*.md and scripts/bosun in step.
#
# For every subcommand (confirm input choose style table spin) this asserts:
#   1. every `--flag` mentioned in docs/bosun/<cmd>.md is a case label in
#      cmd_<cmd>() of scripts/bosun, and vice versa;
#   2. every `--flag` on the `- \`bosun <cmd>\`` bullet of docs/bosun/overview.md
#      exists in cmd_<cmd>();
#   3. every `--flag` on the `bosun <cmd> …` line of the usage() fallback inside
#      scripts/bosun exists in cmd_<cmd>().
#
# Stock tools only (awk, sed, grep, sort, comm, tr). Exit 1 on any mismatch.
#
# Usage: scripts/dev/check-bosun-docs.sh [--bosun PATH] [--docs DIR]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOSUN="$ROOT/scripts/bosun"
DOCS="$ROOT/docs/bosun"
COMMANDS=(confirm input choose style table spin)

while [ $# -gt 0 ]; do
  case "$1" in
    --bosun) BOSUN="$2"; shift ;;
    --docs) DOCS="$2"; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "check-bosun-docs: unknown argument '$1'" >&2; exit 64 ;;
  esac
  shift
done

[ -r "$BOSUN" ] || { echo "check-bosun-docs: cannot read $BOSUN" >&2; exit 64; }
[ -d "$DOCS" ] || { echo "check-bosun-docs: docs directory not found: $DOCS" >&2; exit 64; }

# Long flags look like --word or --word-word. `--` alone (end of options) is
# excluded by requiring a letter after the dashes.
FLAG_RE='--[a-z][a-z0-9-]*'

# Flags accepted by cmd_<name>(): the case labels inside the function body,
# split on `|` so `--value|--default)` yields both spellings.
code_flags() {
  awk -v fn="cmd_$1() {" '
    $0 == fn { inside = 1; next }
    inside && $0 == "}" { exit }
    inside { print }
  ' "$BOSUN" \
    | sed -n 's/^[[:space:]]*\(-[-A-Za-z0-9|]*\))[[:space:]].*/\1/p' \
    | tr '|' '\n' \
    | grep -E "^${FLAG_RE}\$" \
    | sort -u
}

# Flags mentioned anywhere in docs/bosun/<name>.md.
doc_flags() {
  local page="$DOCS/$1.md"
  [ -r "$page" ] || { echo "check-bosun-docs: missing page $page" >&2; return 1; }
  grep -o -E -- "$FLAG_RE" "$page" | sort -u
}

# Flags on the overview bullet for <name>.
overview_flags() {
  local page="$DOCS/overview.md"
  [ -r "$page" ] || return 0
  grep -E -- "^- \`bosun $1\`" "$page" \
    | { grep -o -E -- "$FLAG_RE" || true; } \
    | sort -u
}

# Flags on the usage() fallback line for <name> inside scripts/bosun.
usage_flags() {
  awk '
    /^usage\(\) \{/ { inside = 1; next }
    inside && /^}/ { exit }
    inside { print }
  ' "$BOSUN" \
    | grep -E -- "^[[:space:]]+bosun $1( |\$)" \
    | { grep -o -E -- "$FLAG_RE" || true; } \
    | sort -u
}

failures=0
report() {
  printf 'check-bosun-docs: %s\n' "$*" >&2
  failures=$((failures + 1))
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

for cmd in "${COMMANDS[@]}"; do
  code_flags "$cmd" > "$tmpdir/code"
  doc_flags "$cmd" > "$tmpdir/doc" || { failures=$((failures + 1)); continue; }
  overview_flags "$cmd" > "$tmpdir/overview"
  usage_flags "$cmd" > "$tmpdir/usage"

  if [ ! -s "$tmpdir/code" ]; then
    report "$cmd: no case labels found in cmd_$cmd() of $BOSUN"
    continue
  fi

  # docs ⊄ code
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    report "$cmd: $flag is documented in docs/bosun/$cmd.md but cmd_$cmd() does not accept it"
  done < <(comm -23 "$tmpdir/doc" "$tmpdir/code")

  # code ⊄ docs
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    report "$cmd: $flag is accepted by cmd_$cmd() but not documented in docs/bosun/$cmd.md"
  done < <(comm -13 "$tmpdir/doc" "$tmpdir/code")

  # overview bullet ⊄ code
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    report "$cmd: $flag appears on the overview.md bullet but cmd_$cmd() does not accept it"
  done < <(comm -23 "$tmpdir/overview" "$tmpdir/code")

  # usage() fallback ⊄ code
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    report "$cmd: $flag appears in the usage() fallback of scripts/bosun but cmd_$cmd() does not accept it"
  done < <(comm -23 "$tmpdir/usage" "$tmpdir/code")

  printf '%-8s ok: %s\n' "$cmd" "$(tr '\n' ' ' < "$tmpdir/code")"
done

if [ "$failures" -gt 0 ]; then
  printf 'check-bosun-docs: %d mismatch(es)\n' "$failures" >&2
  exit 1
fi
echo "check-bosun-docs: docs/bosun and scripts/bosun agree"
