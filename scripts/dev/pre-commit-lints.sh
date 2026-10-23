#!/usr/bin/env bash
set -euo pipefail

# Shiplog pre-commit linters (staged files only)
# Tools: shellcheck, markdownlint-cli2, yamllint
# Runs all linters and reports cumulative failures at the end.
# To bypass missing tool failures (not lint errors), set SHIPLOG_LINT_SKIP_MISSING=1.

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

changed() {
  git diff --cached --name-only --diff-filter=ACM | tr '\n' '\0'
}

mapfile -d '' files < <(changed)
[ ${#files[@]} -gt 0 ] || exit 0

sh_files=()
md_files=()
yml_files=()
for f in "${files[@]}"; do
  case "$f" in
    bin/git-shiplog|contrib/hooks/*|*.sh) sh_files+=("$f") ;;
    *.md) md_files+=("$f") ;;
    *.yml|*.yaml) yml_files+=("$f") ;;
  esac
done

fail_missing() {
  if [ "${SHIPLOG_LINT_SKIP_MISSING:-0}" != "1" ]; then
    echo "Missing required tool: $1" >&2
    exit 1
  else
    echo "Skipping $1 (missing)" >&2
  fi
}

had_failures=0

# ShellCheck (auto-detect shell unless bash shebang is present)
if [ ${#sh_files[@]} -gt 0 ]; then
  if command -v shellcheck >/dev/null 2>&1; then
    for f in "${sh_files[@]}"; do
      shebang=$(head -n 1 "$f" 2>/dev/null || true)
      shebang_lc=$(printf '%s' "$shebang" | tr '[:upper:]' '[:lower:]')
      case "$shebang_lc" in
        (*bash*)
          if ! shellcheck -S error -s bash "$f"; then
            had_failures=1
          fi
          ;;
        (*)
          if ! shellcheck -S error "$f"; then
            had_failures=1
          fi
          ;;
      esac
    done
  else
    fail_missing shellcheck
  fi
fi

# markdownlint-cli2
if [ ${#md_files[@]} -gt 0 ]; then
  if command -v markdownlint-cli2 >/dev/null 2>&1; then
    if ! markdownlint-cli2 "${md_files[@]}"; then
      had_failures=1
    fi
  else
    # Try npx fallback if Node present
    if command -v npx >/dev/null 2>&1; then
      if ! npx --yes markdownlint-cli2 "${md_files[@]}"; then
        had_failures=1
      fi
    else
      fail_missing markdownlint-cli2
    fi
  fi
fi

# yamllint
if [ ${#yml_files[@]} -gt 0 ]; then
  if command -v yamllint >/dev/null 2>&1; then
    if ! yamllint -f standard "${yml_files[@]}"; then
      had_failures=1
    fi
  else
    fail_missing yamllint
  fi
fi

# Cumulative status
if [ "$had_failures" -eq 1 ]; then
  exit 1
fi
