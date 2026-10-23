#!/usr/bin/env bats

load helpers/common

REF_ROOT=${SHIPLOG_REF_ROOT:-refs/_shiplog}
TRUST_REF=${SHIPLOG_TRUST_REF:-refs/_shiplog/trust/root}

set_default_shiplog_env() {
  unset SHIPLOG_SERVICE SHIPLOG_STATUS SHIPLOG_REASON SHIPLOG_TICKET
  unset SHIPLOG_REGION SHIPLOG_CLUSTER SHIPLOG_NAMESPACE
  unset SHIPLOG_IMAGE SHIPLOG_TAG SHIPLOG_RUN_URL
  unset SHIPLOG_LOG SHIPLOG_EXTRA_JSON SHIPLOG_BORING SHIPLOG_ASSUME_YES
  export SHIPLOG_ENV=prod
}

setup() {
  set_default_shiplog_env
  shiplog_standard_setup
  git shiplog init >/dev/null
  export SHIPLOG_SIGN=0
  export SHIPLOG_AUTO_PUSH=0
}

teardown() {
  shiplog_standard_teardown
  unset SHIPLOG_SIGN SHIPLOG_AUTO_PUSH
  unset SHIPLOG_SERVICE SHIPLOG_STATUS SHIPLOG_REASON SHIPLOG_TICKET
  unset SHIPLOG_REGION SHIPLOG_CLUSTER SHIPLOG_NAMESPACE
  unset SHIPLOG_IMAGE SHIPLOG_TAG SHIPLOG_RUN_URL
  unset SHIPLOG_LOG SHIPLOG_EXTRA_JSON SHIPLOG_BORING SHIPLOG_ASSUME_YES
  unset SHIPLOG_ENV
}

@test "defaults namespace to environment name when SHIPLOG_NAMESPACE is unset" {
  run bash -c 'SHIPLOG_BORING=1 SHIPLOG_ASSUME_YES=1 SHIPLOG_SERVICE=api git shiplog write staging'
  [ "$status" -eq 0 ]

  run bash -c "git shiplog show --json ${REF_ROOT}/journal/staging | jq -r '.where.namespace'"
  [ "$status" -eq 0 ]
  [ "$output" = "staging" ]
}

@test "append merges provided JSON payload" {
  run bash -c 'git shiplog append --service api --status success --reason "auto" --json '\''{"build":"200"}'\'''
  [ "$status" -eq 0 ]

  run bash -c "git shiplog show --json ${REF_ROOT}/journal/prod"
  [ "$status" -eq 0 ]
  build=$(printf '%s\n' "$output" | jq -r '.build')
  [ "$build" = "200" ]
}

@test "append --dry-run previews without writing" {
  local unique_env="prod-append-dryrun-${BATS_TEST_NUMBER:-0}-${RANDOM}${RANDOM}"
  local journal_ref="${REF_ROOT}/journal/${unique_env}"
  # No EXIT trap: bats-core owns it; the sandbox repo is removed by teardown (#148).

  git update-ref -d "$journal_ref" >/dev/null 2>&1 || true

  run bash -c "git show-ref $journal_ref"
  [ "$status" -ne 0 ]

  run bash -c "SHIPLOG_ENV='$unique_env' git shiplog append --dry-run --service api --status success --reason 'dry-run' --json '{\"build\":\"preview\"}'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would sign & append entry to ${REF_ROOT}/journal/${unique_env}"* ]]

  run bash -c "git show-ref $journal_ref"
  [ "$status" -ne 0 ]
}

@test "append accepts JSON from stdin" {
  local prev_env="${SHIPLOG_ENV:-prod}"
  local unique_env="prod-append-stdin-${BATS_TEST_NUMBER:-0}-${RANDOM}${RANDOM}"
  export SHIPLOG_ENV="$unique_env"
  local journal_ref="${REF_ROOT}/journal/${SHIPLOG_ENV}"
  # No EXIT trap: bats-core owns it; the sandbox repo is removed by teardown (#148).

  git update-ref -d "$journal_ref" >/dev/null 2>&1 || true
  before=$(git rev-parse "$journal_ref" 2>/dev/null || echo "")

  run bash -c 'printf '\''{"build":"201","method":"stdin"}'\'' | git shiplog append --service api --status success --reason "stdin" --json -'
  [ "$status" -eq 0 ]

  after=$(git rev-parse "$journal_ref" 2>/dev/null || echo "")
  [ "$before" != "$after" ]

  run bash -c "git shiplog show --json $journal_ref"
  [ "$status" -eq 0 ]
  method=$(printf '%s\n' "$output" | jq -r '.method')
  [ "$method" = "stdin" ]

  export SHIPLOG_ENV="$prev_env"
}

@test "trust show prints roster and supports --json" {
  run bash -c 'git show refs/_shiplog/trust/root:trust.json'
  [ "$status" -eq 0 ]

  run bash -c 'git shiplog trust show --json'
  [ "$status" -eq 0 ]
  threshold=$(printf '%s\n' "$output" | jq -r '.threshold')
  [ "$threshold" = "1" ]

  run bash -c 'git shiplog trust show'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Trust ID"* ]]
  [[ "$output" == *"Allowed signers: "* ]]
  [[ "$output" == *"shiplog-tester@example.com"* ]]
}
