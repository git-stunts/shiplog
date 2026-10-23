#!/usr/bin/env bats

load helpers/common

REF_ROOT=${SHIPLOG_REF_ROOT:-refs/_shiplog}

setup() {
  shiplog_standard_setup
  git shiplog init >/dev/null
  export SHIPLOG_SIGN=0
  export SHIPLOG_AUTO_PUSH=0
  export SHIPLOG_SERVICE="web"
  export SHIPLOG_REASON="test hotfix"
  export SHIPLOG_TICKET="OPS-0000"
  export SHIPLOG_REGION="us-west-2"
  export SHIPLOG_CLUSTER="prod-1"
  export SHIPLOG_NAMESPACE="pf3"
  export SHIPLOG_IMAGE="ghcr.io/example/web"
  export SHIPLOG_TAG="test.1"
  export SHIPLOG_RUN_URL="https://ci/run/123"
}

teardown() {
  unset SHIPLOG_SERVICE SHIPLOG_STATUS SHIPLOG_REASON SHIPLOG_TICKET
  unset SHIPLOG_REGION SHIPLOG_CLUSTER SHIPLOG_NAMESPACE SHIPLOG_IMAGE SHIPLOG_TAG
  unset SHIPLOG_AUTO_PUSH SHIPLOG_SIGN
  shiplog_standard_teardown
}

@test "write creates a commit under refs/_shiplog/journal/prod" {
  run git shiplog --yes write
  [ "$status" -eq 0 ]
  ref="${REF_ROOT}/journal/prod"
  run git show -s --format=%s "$ref"
  [ "$status" -eq 0 ]
  [[ "$output" == "Deploy: web"* ]]
}

@test "write --dry-run previews without writing" {
  local unique_env="prod-write-dryrun-${BATS_TEST_NUMBER:-0}-${RANDOM}${RANDOM}"
  local journal_ref="${REF_ROOT}/journal/${unique_env}"
  # No EXIT trap here: bats-core owns the EXIT trap, and overriding it hides
  # failure output and skips teardown. The sandbox repo (and this ref) is
  # removed by teardown (#148).

  git update-ref -d "$journal_ref" >/dev/null 2>&1 || true

  run git show-ref "$journal_ref"
  [ "$status" -ne 0 ]

  run env SHIPLOG_ENV="$unique_env" git shiplog --boring write --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would sign & append entry to ${REF_ROOT}/journal/${unique_env}"* ]]

  run git show-ref "$journal_ref"
  [ "$status" -ne 0 ]
}

@test "ls shows a formatted table via bosun" {
  run git shiplog --yes write
  [ "$status" -eq 0 ]
  run git shiplog ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"web"* ]]
  [[ "$output" == *"SUCCESS"* ]]
}

@test "show renders human header and seq" {
  run git shiplog --yes write
  [ "$status" -eq 0 ]
  sha=$(git rev-parse "${REF_ROOT}/journal/prod")
  run git shiplog show "$sha"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHIPLOG Entry"* ]]
  [[ "$output" == *"Seq:"* ]]
  [[ "$output" == *"OPS-0000"* ]]
}

@test "--boring write consumes SHIPLOG defaults" {
  export SHIPLOG_SERVICE="boring-web"
  export SHIPLOG_STATUS="success"
  export SHIPLOG_REASON="non-interactive deploy"
  export SHIPLOG_TICKET="BORING-1"
  export SHIPLOG_REGION="us-east-1"
  export SHIPLOG_CLUSTER="prod-a"
  export SHIPLOG_NAMESPACE="default"
  export SHIPLOG_IMAGE="ghcr.io/example/boring"
  export SHIPLOG_TAG="v1.2.3"

  run git shiplog --boring write
  if [ "$status" -ne 0 ]; then
    printf 'git shiplog write output:\n%s\n' "$output" >&2
  fi
  [ "$status" -eq 0 ]
  if [ -z "$output" ]; then
    echo "git shiplog command produced no output" >&2
    return 1
  fi

  run git show -s --format=%s "${REF_ROOT}/journal/prod"
  [ "$status" -eq 0 ]
  if [[ ! "$output" =~ ^"Deploy: boring-web" ]]; then
    echo "Expected commit subject to start with service name" >&2
    return 1
  fi

  command -v jq >/dev/null 2>&1 || skip "jq required for JSON assertions"
  local raw json
  raw=$(git cat-file commit "${REF_ROOT}/journal/prod" | sed '1,/^$/d')
  json=$(printf '%s\n' "$raw" | awk '/^[[:space:]]*---/{flag=1;next}flag')
  if [ -z "$json" ]; then
    printf 'Journal output:\n%s\n' "$output" >&2
    echo "Structured trailer missing from journal entry" >&2
    return 1
  fi

  local field
  field=$(printf '%s\n' "$json" | jq -er '.what.service')
  if [ "$field" != "$SHIPLOG_SERVICE" ]; then
    echo "Expected service $SHIPLOG_SERVICE, got $field" >&2
    return 1
  fi

  field=$(printf '%s\n' "$json" | jq -er '.status')
  if [ "$field" != "$SHIPLOG_STATUS" ]; then
    echo "Expected status $SHIPLOG_STATUS, got $field" >&2
    return 1
  fi

  field=$(printf '%s\n' "$json" | jq -er '.why.reason')
  if [ "$field" != "$SHIPLOG_REASON" ]; then
    echo "Expected reason $SHIPLOG_REASON, got $field" >&2
    return 1
  fi

  field=$(printf '%s\n' "$json" | jq -er '.why.ticket')
  if [ "$field" != "$SHIPLOG_TICKET" ]; then
    echo "Expected ticket $SHIPLOG_TICKET, got $field" >&2
    return 1
  fi

  field=$(printf '%s\n' "$json" | jq -er '.where.region')
  if [ "$field" != "$SHIPLOG_REGION" ]; then
    echo "Expected region $SHIPLOG_REGION, got $field" >&2
    return 1
  fi

  field=$(printf '%s\n' "$json" | jq -er '.where.cluster')
  if [ "$field" != "$SHIPLOG_CLUSTER" ]; then
    echo "Expected cluster $SHIPLOG_CLUSTER, got $field" >&2
    return 1
  fi

  field=$(printf '%s\n' "$json" | jq -er '.where.namespace')
  if [ "$field" != "$SHIPLOG_NAMESPACE" ]; then
    echo "Expected namespace $SHIPLOG_NAMESPACE, got $field" >&2
    return 1
  fi

  field=$(printf '%s\n' "$json" | jq -er '.what.artifact')
  if [ "$field" != "$SHIPLOG_IMAGE:$SHIPLOG_TAG" ]; then
    echo "Expected artifact $SHIPLOG_IMAGE:$SHIPLOG_TAG, got $field" >&2
    return 1
  fi
}

# --- SLT.BUG.CLI.001 (#97): header text can never corrupt the trailer -------

@test "write: a --- line in the reason cannot wedge the journal" {
  local ref="${REF_ROOT}/journal/prod"
  run env SHIPLOG_REASON=$'rollback\n---\nsee runbook' SHIPLOG_SERVICE=$'web\nevil' git shiplog --boring --yes write
  [ "$status" -eq 0 ]
  first=$(git rev-parse "$ref")

  # The next write must still read seq from the previous entry.
  run git shiplog --boring --yes write
  [ "$status" -eq 0 ]
  run git shiplog show --json "$ref"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.seq')" = "1" ]

  # Documented rule: newlines in header fields become spaces and round-trip.
  run git shiplog show --json "$first"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.why.reason')" = "rollback --- see runbook" ]
  [ "$(printf '%s\n' "$output" | jq -r '.what.service')" = "web evil" ]
  run git show -s --format=%s "$first"
  [[ "$output" == "Deploy: web evil"* ]]
  run git shiplog validate-trailer "$first"
  [ "$status" -eq 0 ]
  run git shiplog ls
  [ "$status" -eq 0 ]
}

@test "write rejects a status outside the documented enum" {
  run env SHIPLOG_STATUS=bogus git shiplog --boring --yes write
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid status 'bogus'"* ]]
  run git show-ref "${REF_ROOT}/journal/prod"
  [ "$status" -ne 0 ]
}

@test "legacy entries with a stray --- in the header still parse and chain" {
  local ref="${REF_ROOT}/journal/prod"
  run git shiplog --boring --yes write
  [ "$status" -eq 0 ]
  local parent tree json msg fixture
  parent=$(git rev-parse "$ref")
  tree=$(git rev-parse "${ref}^{tree}")
  json=$(git shiplog show --json "$parent" | jq -c --arg p "$parent" '.seq = 1 | .journal_parent = $p')
  # Old-format fixture: a bare --- line in the header followed by the writer
  # sentinel and the JSON. The first-`---` reader returned garbage for this.
  msg=$(printf 'Deploy: web → prod\nReason: rollback\n---\nsee runbook\nStatus: SUCCESS\n\n---  # structured trailer for machines\n%s\n' "$json")
  fixture=$(printf '%s\n' "$msg" | GIT_AUTHOR_NAME="Shiplog Tester" GIT_AUTHOR_EMAIL="shiplog-tester@example.com" \
    GIT_COMMITTER_NAME="Shiplog Tester" GIT_COMMITTER_EMAIL="shiplog-tester@example.com" \
    git commit-tree "$tree" -p "$parent")
  git update-ref "$ref" "$fixture" "$parent"

  run git shiplog validate-trailer "$fixture"
  [ "$status" -eq 0 ]
  run git shiplog --boring --yes write
  [ "$status" -eq 0 ]
  run git shiplog show --json "$ref"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.seq')" = "2" ]
  [ "$(printf '%s\n' "$output" | jq -r '.journal_parent')" = "$fixture" ]
}

# --- SLT.BUG.LIB.012 (#158): one identity for allowlist, trailer and commit --

@test "SHIPLOG_AUTHOR_* sets both the author and the committer of the entry" {
  local ref="${REF_ROOT}/journal/prod"
  run env SHIPLOG_AUTHORS="shiplog-tester@example.com bot@x" SHIPLOG_AUTHOR_NAME="Deploy Bot" SHIPLOG_AUTHOR_EMAIL="bot@x" \
    git shiplog --boring --yes write
  [ "$status" -eq 0 ]
  run git show -s --format='%an <%ae> / %cn <%ce>' "$ref"
  [ "$output" = "Deploy Bot <bot@x> / Deploy Bot <bot@x>" ]
  run git shiplog show --json "$ref"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.who.email')" = "bot@x" ]
}
