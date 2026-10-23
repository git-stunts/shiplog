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
  run bash -lc 'git shiplog run --service test --status-success done --status-failure failed -- false'
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
