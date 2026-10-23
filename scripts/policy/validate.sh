#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: policy/validate.sh [--stdin|-] [policy.json]

Reads a Shiplog policy JSON document (from a file path or STDIN) and emits
validation errors one per line. Returns 0 when the policy is valid, 1 when
errors are present.
USAGE
}

INPUT_MODE="file"
INPUT_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --stdin|-)
      INPUT_MODE="stdin"
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      INPUT_PATH="$1"
      shift
      ;;
  esac
  if [ "$INPUT_MODE" = "stdin" ] && [ -n "$INPUT_PATH" ]; then
    echo "policy/validate.sh: cannot mix --stdin with file argument" >&2
    exit 64
  fi
done

if [ "$INPUT_MODE" = "file" ] && [ -z "$INPUT_PATH" ]; then
  if [ $# -gt 0 ]; then
    INPUT_PATH="$1"
  fi
fi

if [ "$INPUT_MODE" = "file" ] && [ -z "$INPUT_PATH" ]; then
  echo "policy/validate.sh: missing policy JSON path or --stdin" >&2
  exit 64
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR_DEFAULT=$(cd "$SCRIPT_DIR/.." && pwd)
ROOT_DIR="${SHIPLOG_HOME:-$ROOT_DIR_DEFAULT}"
SAFE_PREFIXES=("$ROOT_DIR" "$SCRIPT_DIR" "$SCRIPT_DIR/../lib")

canonicalize_path() {
  local target="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$target" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target" 2>/dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -MCwd=abs_path -e 'print abs_path(shift)' "$target" 2>/dev/null
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "$target" 2>/dev/null
  else
    return 1
  fi
}

path_is_safe() {
  local candidate="$1"
  local canonical
  canonical=$(canonicalize_path "$candidate") || return 1
  local prefix
  for prefix in "${SAFE_PREFIXES[@]}"; do
    [ -n "$prefix" ] || continue
    local canon_prefix
    canon_prefix=$(canonicalize_path "$prefix") || continue
    case "$canonical" in
      "$canon_prefix"|"$canon_prefix"/*)
        return 0
        ;;
    esac
  done
  return 1
}

resolve_filter() {
  local filter="${SHIPLOG_POLICY_VALIDATOR:-}"
  local candidate
  if [ -n "$filter" ] && [ -f "$filter" ]; then
    if path_is_safe "$filter"; then
      SHIPLOG_POLICY_VALIDATOR=$(canonicalize_path "$filter")
      return 0
    fi
  fi
  for candidate in \
    "$SCRIPT_DIR/../lib/policy_validate.jq" \
    "$ROOT_DIR/scripts/lib/policy_validate.jq"; do
    if [ -f "$candidate" ] && path_is_safe "$candidate"; then
      SHIPLOG_POLICY_VALIDATOR=$(canonicalize_path "$candidate")
      return 0
    fi
  done
  return 1
}

if ! resolve_filter; then
  echo "policy/validate.sh: validator filter not found (expected scripts/lib/policy_validate.jq)" >&2
  exit 66
fi
FILTER_PATH="$SHIPLOG_POLICY_VALIDATOR"

if ! command -v jq >/dev/null 2>&1; then
  echo "policy/validate.sh: jq is required" >&2
  exit 127
fi

read_json() {
  if [ "$INPUT_MODE" = "stdin" ]; then
    cat
  else
    cat "$INPUT_PATH"
  fi
}

document=$(read_json)
# Exactly one JSON value: jq runs the filter zero times on an empty document
# (which would pass) and once per value when there are several.
value_count=$(printf '%s\n' "$document" | jq -n '[inputs] | length' 2>&1) || {
  printf '%s\n' "$value_count" >&2
  exit 2
}
if [ "$value_count" != 1 ]; then
  printf 'policy: exactly one JSON value required (found %s)\n' "$value_count"
  exit 1
fi

errors=""
if ! errors=$(printf '%s\n' "$document" | jq -r -f "$FILTER_PATH" 2>&1); then
  printf '%s\n' "$errors" >&2
  exit 2
fi
if [ -n "$errors" ]; then
  printf '%s\n' "$errors"
  exit 1
fi
exit 0
