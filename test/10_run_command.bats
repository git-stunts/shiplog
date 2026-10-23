#!/usr/bin/env bats

load helpers/common

REF_ROOT=${SHIPLOG_REF_ROOT:-refs/_shiplog}
NOTES_REF=${SHIPLOG_NOTES_REF:-refs/_shiplog/notes/logs}

setup() {
  shiplog_standard_setup
  git shiplog init >/dev/null
  export SHIPLOG_SIGN=0
  export SHIPLOG_AUTO_PUSH=0
}

teardown() {
  shiplog_standard_teardown
  unset SHIPLOG_SIGN SHIPLOG_AUTO_PUSH
}

@test "run captures success metadata and attaches note" {
  run bash -lc 'git shiplog run --service test --reason "printf hi" -- env printf hi'
  [ "$status" -eq 0 ]
  [[ "$output" == *"hi"* ]]

  sha=$(git rev-parse "${REF_ROOT}/journal/prod")

  run git notes --ref="${NOTES_REF}" show "$sha"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hi"* ]]

  run bash -lc "git shiplog show --json $sha | jq -r '.status'"
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]

  run bash -lc "git shiplog show --json $sha | jq -r '.run.status'"
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]

  run bash -lc "git shiplog show --json $sha | jq -c '.run.argv'"
  [ "$status" -eq 0 ]
  [ "$output" = '["env","printf","hi"]' ]

  run bash -lc "git shiplog show --json $sha | jq -r '.run.exit_code'"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  run bash -lc "git shiplog show --json $sha | jq -r '.run.log_attached'"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "run propagates failure exit code and status" {
  run bash -lc 'git shiplog run --service test --status-success finalize --status-failure failed -- false'
  [ "$status" -eq 1 ]

  sha=$(git rev-parse "${REF_ROOT}/journal/prod")

  run bash -lc "git shiplog show --json $sha | jq -r '.status'"
  [ "$status" -eq 0 ]
  [ "$output" = "failed" ]

  run bash -lc "git shiplog show --json $sha | jq -r '.run.status'"
  [ "$status" -eq 0 ]
  [ "$output" = "failed" ]

  run bash -lc "git shiplog show --json $sha | jq -r '.run.exit_code'"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  run bash -lc "git shiplog show --json $sha | jq -c '.run.argv'"
  [ "$status" -eq 0 ]
  [ "$output" = '["false"]' ]

  run bash -lc "git shiplog show --json $sha | jq -r '.run.log_attached'"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "run dry-run previews without executing" {
  local unique_env="prod-run-dryrun-${BATS_TEST_NUMBER:-0}-${RANDOM}${RANDOM}"
  local journal_ref="${REF_ROOT}/journal/${unique_env}"
  # No EXIT trap here: bats-core owns the EXIT trap, and overriding it hides
  # failure output and skips teardown. The sandbox repo (and this ref) is
  # removed by teardown (#148).

  git update-ref -d "$journal_ref" >/dev/null 2>&1 || true

  rm -f dry-run-file
  [ ! -e dry-run-file ]

  run git show-ref "$journal_ref"
  [ "$status" -ne 0 ]

  run bash -lc "SHIPLOG_ENV=\"$unique_env\" git shiplog run --dry-run --service test --reason 'no-op' -- touch dry-run-file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would execute: touch dry-run-file"* ]]
  [[ "$output" == *"Would sign & append entry to ${journal_ref}"* ]]
  [ ! -e dry-run-file ]

  run git show-ref "$journal_ref"
  [ "$status" -ne 0 ]
}

# --- SLT.BUG.CLI.002 (#98): a failed write explains itself ------------------

@test "run reports the write failure and the preserved log path" {
  git update-ref -d "${SHIPLOG_TRUST_REF:-refs/_shiplog/trust/root}"
  run git shiplog run --service t -- sh -c 'echo run-output-marker'
  [ "$status" -ne 0 ]
  [[ "$output" == *"trust ref"* ]]
  [[ "$output" == *"failed to record run entry"* ]]
  local log_path
  log_path=$(printf '%s\n' "$output" | sed -n 's/.*log preserved at //p' | tail -n 1)
  [ -n "$log_path" ]
  [ -f "$log_path" ]
  grep -q 'run-output-marker' "$log_path"
  rm -f "$log_path"
}

@test "run: a write failure never masks the wrapped command's exit code" {
  git update-ref -d "${SHIPLOG_TRUST_REF:-refs/_shiplog/trust/root}"
  run git shiplog run --service t -- sh -c 'exit 7'
  [ "$status" -eq 7 ]
  [[ "$output" == *"failed to record run entry"* ]]
}

@test "run: extras cannot override the reserved run block" {
  run env SHIPLOG_EXTRA_JSON='{"run":{"exit_code":0}}' git shiplog run --service t -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *'reserved trailer key "run"'* ]]
  run git show-ref "${REF_ROOT}/journal/prod"
  [ "$status" -ne 0 ]
}

# --- SLT.BUG.CLI.011 (#122): the log is complete when it is attached --------

@test "run attaches the complete log for bursty output (5 runs)" {
  local i sha count attached
  for i in 1 2 3 4 5; do
    run git shiplog run --service t -- sh -c 'head -c 2000000 /dev/zero | tr "\0" x' </dev/null
    [ "$status" -eq 0 ]
    sha=$(git rev-parse "${REF_ROOT}/journal/prod")
    count=$(git notes --ref="${NOTES_REF}" show "$sha" | tr -cd x | wc -c | tr -d ' ')
    [ "$count" -eq 2000000 ]
    attached=$(git shiplog show --json "$sha" | jq -r '.run.log_attached')
    [ "$attached" = "true" ]
  done
}

@test "run preserves the exit code and records both streams" {
  run git shiplog run --service t -- sh -c 'echo out-line; echo err-line >&2; exit 7'
  [ "$status" -eq 7 ]
  [[ "$output" == *"out-line"* ]]
  [[ "$output" == *"err-line"* ]]
  sha=$(git rev-parse "${REF_ROOT}/journal/prod")
  run git notes --ref="${NOTES_REF}" show "$sha"
  [ "$status" -eq 0 ]
  [[ "$output" == *"out-line"* ]]
  [[ "$output" == *"err-line"* ]]
  run bash -lc "git shiplog show --json $sha | jq -r '.run.exit_code'"
  [ "$output" = "7" ]
}

@test "run rejects an invalid --status-success/--status-failure before running the command" {
  local marker="$BATS_TEST_TMPDIR/ran-marker"
  rm -f "$marker"
  run git shiplog run --service t --status-failure bogus -- sh -c "touch '$marker'; exit 3"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid status 'bogus'"* ]]
  [ ! -e "$marker" ]
  run git shiplog run --service t --status-success=nope -- sh -c "touch '$marker'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid status 'nope'"* ]]
  [ ! -e "$marker" ]
  run git show-ref "${REF_ROOT}/journal/prod"
  [ "$status" -ne 0 ]
  # Positive control: a documented non-default status is accepted and recorded.
  run git shiplog run --service t --status-failure revert -- sh -c "touch '$marker'; exit 3"
  [ "$status" -eq 3 ]
  [ -e "$marker" ]
  run bash -c "git shiplog show --json ${REF_ROOT}/journal/prod | jq -r '.status + \" \" + .run.status + \" \" + (.run.exit_code|tostring)'"
  [ "$output" = "revert revert 3" ]
}
