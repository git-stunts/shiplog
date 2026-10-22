#!/usr/bin/env bash
set -euo pipefail

POLICY_FILE=${1:-.shiplog/policy.json}
# Policy ref follows the configured ref root (SHIPLOG_POLICY_REF > SHIPLOG_REF_ROOT >
# git config shiplog.refRoot > refs/_shiplog). The CLI exports the resolved values.
POLICY_REF=${SHIPLOG_POLICY_REF:-}
if [ -z "$POLICY_REF" ]; then
  POLICY_REF_ROOT="${SHIPLOG_REF_ROOT:-$(git config --get shiplog.refRoot 2>/dev/null || true)}"
  POLICY_REF_ROOT="${POLICY_REF_ROOT:-refs/_shiplog}"
  POLICY_REF="${POLICY_REF_ROOT%/}/policy/current"
fi
MESSAGE=${SHIPLOG_POLICY_MESSAGE:-"shiplog: update policy"}
# Default to unsigned policy commits to avoid GPG prompts in CI unless explicitly requested
SIGN_MODE=${SHIPLOG_POLICY_SIGN:-0}
SCHEMA_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../examples/policy.schema.json"

if [ ! -f "$POLICY_FILE" ]; then
  echo "shiplog: policy file $POLICY_FILE not found" >&2
  exit 1
fi

if [ -f "$SCHEMA_PATH" ] && command -v jq >/dev/null 2>&1 && jq --help 2>&1 | grep -q -- '--schema'; then
  if ! jq --schema "$SCHEMA_PATH" '.' "$POLICY_FILE" >/dev/null 2>&1; then
    echo "shiplog: policy file $POLICY_FILE failed schema validation" >&2
    exit 1
  fi
else
  echo "shiplog: schema validation skipped (jq --schema unavailable or schema missing)" >&2
fi

policy_blob=$(git hash-object -w "$POLICY_FILE")
# Create a tree at .shiplog/policy.json to match server hook expectations
inner_tree=$(printf '100644 blob %s\tpolicy.json\n' "$policy_blob" | git mktree)
tree=$(printf '040000 tree %s\t.shiplog\n' "$inner_tree" | git mktree)
parent=$(git rev-parse -q --verify "$POLICY_REF" 2>/dev/null || echo "")

commit_args=("$tree")
if [ -n "$parent" ]; then
  commit_args+=( -p "$parent" )
fi

if [ "$SIGN_MODE" = "0" ]; then
  commit=$(printf '%s\n' "$MESSAGE" | GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$(git config user.name)}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$(git config user.email)}" git commit-tree "${commit_args[@]}")
else
  commit=$(printf '%s\n' "$MESSAGE" | git commit-tree "${commit_args[@]}" -S)
fi

if [ -z "$commit" ]; then
  echo "shiplog: failed to create policy commit" >&2
  exit 1
fi

if [ -n "$parent" ]; then
  git update-ref -m "$MESSAGE" "$POLICY_REF" "$commit" "$parent"
else
  git update-ref -m "$MESSAGE" "$POLICY_REF" "$commit" 0000000000000000000000000000000000000000
fi

echo "Updated $POLICY_REF -> $commit"
