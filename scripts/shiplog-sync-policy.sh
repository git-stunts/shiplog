#!/usr/bin/env bash
set -euo pipefail

# Publishes a policy document to the local policy ref as a fast-forward commit
# (does not push). The document is validated with the canonical validator first;
# an invalid policy aborts before the ref moves.
#
# Signing (SLT.BUG.TOOL.006): SHIPLOG_POLICY_SIGN=1|0 decides whether the commit
# is signed. When unset, the commit is signed when `git config user.signingkey`
# is configured and unsigned (with a hint) otherwise. The pre-receive hook
# requires a maintainer signature on policy updates once a trust ref exists.

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$POLICY_FILE" ]; then
  echo "shiplog: policy file $POLICY_FILE not found" >&2
  exit 1
fi

# --- validate with the real validator (no jq --schema; it does not exist) ------
VALIDATOR=""
for candidate in \
  "${SHIPLOG_HOME:-}/scripts/policy/validate.sh" \
  "$SCRIPT_DIR/policy/validate.sh"; do
  case "$candidate" in /scripts/*) continue ;; esac
  if [ -x "$candidate" ]; then
    VALIDATOR="$candidate"
    break
  fi
done
if [ -z "$VALIDATOR" ]; then
  echo "shiplog: policy validator not found (expected scripts/policy/validate.sh under SHIPLOG_HOME or next to this script)" >&2
  exit 66
fi

validation_output=""
validation_status=0
validation_output=$("$VALIDATOR" "$POLICY_FILE" 2>&1) || validation_status=$?
if [ "$validation_status" -ne 0 ]; then
  echo "shiplog: policy file $POLICY_FILE failed validation; not publishing" >&2
  [ -n "$validation_output" ] && printf '%s\n' "$validation_output" >&2
  exit 1
fi

# --- signing default --------------------------------------------------------------
sign_mode=""
case "${SHIPLOG_POLICY_SIGN:-}" in
  "")
    if [ -n "$(git config --get user.signingkey 2>/dev/null || true)" ]; then
      sign_mode=1
    else
      sign_mode=0
      echo "shiplog: publishing an unsigned policy commit (no user.signingkey configured; set SHIPLOG_POLICY_SIGN=1 and a signing key to sign)" >&2
    fi
    ;;
  1|true|yes|on|TRUE|True|YES|Yes|ON|On) sign_mode=1 ;;
  0|false|no|off|FALSE|False|NO|No|OFF|Off) sign_mode=0 ;;
  *)
    echo "shiplog: SHIPLOG_POLICY_SIGN must be a boolean (1|true|yes|on|0|false|no|off), got '${SHIPLOG_POLICY_SIGN}'" >&2
    exit 1
    ;;
esac

policy_blob=$(git hash-object -w "$POLICY_FILE")
# Create a tree at .shiplog/policy.json to match server hook expectations
inner_tree=$(printf '100644 blob %s\tpolicy.json\n' "$policy_blob" | git mktree)
tree=$(printf '040000 tree %s\t.shiplog\n' "$inner_tree" | git mktree)
parent=$(git rev-parse -q --verify "$POLICY_REF" 2>/dev/null || echo "")

commit_args=("$tree")
if [ -n "$parent" ]; then
  commit_args+=( -p "$parent" )
fi

if [ "$sign_mode" = "0" ]; then
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
