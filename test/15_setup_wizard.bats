#!/usr/bin/env bats

load helpers/common

setup() {
  shiplog_install_cli
  shiplog_use_sandbox_repo
  git config user.name "Shiplog Tester"
  git config user.email "shiplog-tester@example.com"
  shiplog_setup_test_signing
}

teardown() {
  shiplog_cleanup_sandbox_repo
  # Bare origins created by individual tests (no EXIT traps: bats-core owns
  # the EXIT trap and overriding it hides failure output, #148).
  if [ -n "${ORIGIN2_DIR:-}" ] && [ -d "$ORIGIN2_DIR" ]; then
    rm -rf "$ORIGIN2_DIR"
  fi
  unset ORIGIN2_DIR
}

@test "setup open writes policy and updates ref" {
  run env SHIPLOG_SETUP_STRICTNESS=open git shiplog setup
  [ "$status" -eq 0 ]
  [ -f .shiplog/policy.json ]
  run jq -r '.require_signed' .shiplog/policy.json
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
  run git rev-parse --verify refs/_shiplog/policy/current
  [ "$status" -eq 0 ]
}

@test "policy show --json emits valid JSON" {
  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  run jq -er '.require_signed | type' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "setup balanced writes allowlist" {
  run env SHIPLOG_SETUP_STRICTNESS=balanced SHIPLOG_SETUP_AUTHORS="shiplog-tester@example.com other@example.com" git shiplog setup
  [ "$status" -eq 0 ]
  run jq -r '.authors.default_allowlist | join(" ")' .shiplog/policy.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"shiplog-tester@example.com"* ]]
  [[ "$output" == *"other@example.com"* ]]
}

@test "setup strict bootstraps trust and sets require_signed" {
  # Create a fake SSH public key file
  mkdir -p tmp
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY shiplog@test" > tmp/testkey.pub
  export SHIPLOG_TRUST_COUNT=1
  export SHIPLOG_TRUST_ID="shiplog-trust-root"
  export SHIPLOG_TRUST_1_NAME="Shiplog Tester"
  export SHIPLOG_TRUST_1_EMAIL="shiplog-tester@example.com"
  export SHIPLOG_TRUST_1_ROLE="root"
  export SHIPLOG_TRUST_1_PGP_FPR=""
  export SHIPLOG_TRUST_1_SSH_KEY_PATH="$(pwd)/tmp/testkey.pub"
  export SHIPLOG_TRUST_1_PRINCIPAL="shiplog-tester@example.com"
  export SHIPLOG_TRUST_1_REVOKED="no"
  export SHIPLOG_TRUST_THRESHOLD=1
  export SHIPLOG_TRUST_COMMIT_MESSAGE="shiplog: trust root v1 (GENESIS)"
  export SHIPLOG_ASSUME_YES=1
  export SHIPLOG_PLAIN=1

  run env SHIPLOG_SETUP_STRICTNESS=strict git shiplog setup
  [ "$status" -eq 0 ]
  run jq -r '.require_signed' .shiplog/policy.json
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run git rev-parse --verify refs/_shiplog/trust/root
  [ "$status" -eq 0 ]
}

@test "setup strict per-env writes deployment_requirements and can auto-push" {
  # Create a bare origin and set as remote
  ORIGIN_DIR=$(mktemp -d)
  git remote remove origin >/dev/null 2>&1 || true
  git init --bare "$ORIGIN_DIR"
  git remote add origin "$ORIGIN_DIR"

  run env SHIPLOG_SETUP_STRICTNESS=strict SHIPLOG_SETUP_STRICT_ENVS="prod staging" SHIPLOG_SETUP_AUTO_PUSH=1 git shiplog setup --auto-push --strict-envs "prod staging"
  [ "$status" -eq 0 ]
  run jq -r '.require_signed' .shiplog/policy.json
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
  run jq -r '.deployment_requirements.prod.require_signed' .shiplog/policy.json
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run jq -r '.deployment_requirements.staging.require_signed' .shiplog/policy.json
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  # Auto-push should populate origin
  run git --git-dir="$ORIGIN_DIR" rev-parse --verify refs/_shiplog/policy/current
  [ "$status" -eq 0 ]
  # Cleanup
  rm -rf "$ORIGIN_DIR"
}

@test "setup strict env-driven auto-pushes trust to origin" {
  # Prepare origin
  ORIGIN2_DIR=$(mktemp -d)
  git remote remove origin >/dev/null 2>&1 || true
  git init --bare "$ORIGIN2_DIR"
  git remote add origin "$ORIGIN2_DIR"

  # Fake key
  mkdir -p tmp
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY shiplog@test" > tmp/testkey.pub
  export SHIPLOG_TRUST_COUNT=1
  export SHIPLOG_TRUST_ID="shiplog-trust-root"
  export SHIPLOG_TRUST_1_NAME="Shiplog Tester"
  export SHIPLOG_TRUST_1_EMAIL="shiplog-tester@example.com"
  export SHIPLOG_TRUST_1_ROLE="root"
  export SHIPLOG_TRUST_1_PGP_FPR=""
  export SHIPLOG_TRUST_1_SSH_KEY_PATH="$(pwd)/tmp/testkey.pub"
  export SHIPLOG_TRUST_1_PRINCIPAL="shiplog-tester@example.com"
  export SHIPLOG_TRUST_1_REVOKED="no"
  export SHIPLOG_TRUST_THRESHOLD=1
  export SHIPLOG_TRUST_COMMIT_MESSAGE="shiplog: trust root v1 (GENESIS)"
  export SHIPLOG_ASSUME_YES=1
  export SHIPLOG_PLAIN=1

  run env SHIPLOG_SETUP_STRICTNESS=strict SHIPLOG_SETUP_AUTO_PUSH=1 git shiplog setup --auto-push
  [ "$status" -eq 0 ]
  run git --git-dir="$ORIGIN2_DIR" rev-parse --verify refs/_shiplog/trust/root
  [ "$status" -eq 0 ]
}

@test "setup warns about missing remote refs when not auto-pushing" {
  ORIGIN_WARN_DIR=$(mktemp -d)
  git remote remove origin >/dev/null 2>&1 || true
  git init --bare "$ORIGIN_WARN_DIR"
  git remote add origin "$ORIGIN_WARN_DIR"

  run git --git-dir="$ORIGIN_WARN_DIR" rev-parse --verify refs/_shiplog/policy/current
  [ "$status" -ne 0 ]
  run git --git-dir="$ORIGIN_WARN_DIR" rev-parse --verify refs/_shiplog/trust/root
  [ "$status" -ne 0 ]

  run env SHIPLOG_SETUP_STRICTNESS=open git shiplog setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHIPLOG_ALLOW_MISSING_POLICY=1"* ]]
  [[ "$output" == *"SHIPLOG_ALLOW_MISSING_TRUST=1"* ]]
  rm -rf "$ORIGIN_WARN_DIR"
}

@test "setup does not warn when remote refs exist" {
  ORIGIN_OK_DIR=$(mktemp -d)
  git remote remove origin >/dev/null 2>&1 || true
  git init --bare "$ORIGIN_OK_DIR"
  git remote add origin "$ORIGIN_OK_DIR"

  mkdir -p tmp
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY shiplog@test" > tmp/testkey.pub
  export SHIPLOG_TRUST_COUNT=1
  export SHIPLOG_TRUST_ID="shiplog-trust-root"
  export SHIPLOG_TRUST_1_NAME="Shiplog Tester"
  export SHIPLOG_TRUST_1_EMAIL="shiplog-tester@example.com"
  export SHIPLOG_TRUST_1_ROLE="root"
  export SHIPLOG_TRUST_1_PGP_FPR=""
  export SHIPLOG_TRUST_1_SSH_KEY_PATH="$(pwd)/tmp/testkey.pub"
  export SHIPLOG_TRUST_1_PRINCIPAL="shiplog-tester@example.com"
  export SHIPLOG_TRUST_1_REVOKED="no"
  export SHIPLOG_TRUST_THRESHOLD=1
  export SHIPLOG_TRUST_COMMIT_MESSAGE="shiplog: trust root v1 (GENESIS)"
  export SHIPLOG_ASSUME_YES=1
  export SHIPLOG_PLAIN=1

  run env SHIPLOG_SETUP_STRICTNESS=strict SHIPLOG_SETUP_AUTO_PUSH=1 git shiplog setup --auto-push
  [ "$status" -eq 0 ]

  unset SHIPLOG_TRUST_COUNT SHIPLOG_TRUST_ID SHIPLOG_TRUST_1_NAME SHIPLOG_TRUST_1_EMAIL
  unset SHIPLOG_TRUST_1_ROLE SHIPLOG_TRUST_1_PGP_FPR SHIPLOG_TRUST_1_SSH_KEY_PATH SHIPLOG_TRUST_1_PRINCIPAL
  unset SHIPLOG_TRUST_1_REVOKED SHIPLOG_TRUST_THRESHOLD SHIPLOG_TRUST_COMMIT_MESSAGE SHIPLOG_ASSUME_YES SHIPLOG_PLAIN

  run git --git-dir="$ORIGIN_OK_DIR" rev-parse --verify refs/_shiplog/policy/current
  [ "$status" -eq 0 ]
  run git --git-dir="$ORIGIN_OK_DIR" rev-parse --verify refs/_shiplog/trust/root
  [ "$status" -eq 0 ]

  run env SHIPLOG_SETUP_STRICTNESS=open git shiplog setup
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHIPLOG_ALLOW_MISSING_POLICY=1"* ]]
  [[ "$output" != *"SHIPLOG_ALLOW_MISSING_TRUST=1"* ]]

  rm -f tmp/testkey.pub
  rm -rf "$ORIGIN_OK_DIR"
}

@test "setup backups and diffs policy on overwrite" {
  mkdir -p .shiplog
  rm -f .shiplog/policy.json.bak.*
  printf '{"version":1,"require_signed":true}' > .shiplog/policy.json
  run env SHIPLOG_SETUP_STRICTNESS=open git shiplog setup
  [ "$status" -eq 0 ]
  run ls .shiplog/policy.json.bak.*
  [ "$status" -eq 0 ]
  run jq -r '.require_signed' .shiplog/policy.json
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
  # Running again with same settings should not create another backup
  before_count=$(ls -1 .shiplog/policy.json.bak.* | wc -l | tr -d ' ')
  run env SHIPLOG_SETUP_STRICTNESS=open git shiplog setup
  [ "$status" -eq 0 ]
  after_count=$(ls -1 .shiplog/policy.json.bak.* | wc -l | tr -d ' ')
  [ "$before_count" -eq "$after_count" ]
}

@test "setup dry-run previews without writing or syncing" {
  mkdir -p .shiplog
  printf '{"version":1,"require_signed":false}' > .shiplog/policy.json
  # Record current ref (should exist due to previous tests creating it)
  before_ref=$(git rev-parse -q --verify refs/_shiplog/policy/current 2>/dev/null || echo "")
  run env SHIPLOG_SETUP_STRICTNESS=balanced SHIPLOG_SETUP_AUTHORS="x@y" git shiplog setup --dry-run --authors "x@y"
  [ "$status" -eq 0 ]
  # File unchanged
  run jq -r '.require_signed' .shiplog/policy.json
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
  # Ref unchanged (no sync on dry-run)
  after_ref=$(git rev-parse -q --verify refs/_shiplog/policy/current 2>/dev/null || echo "")
  [ "$before_ref" = "$after_ref" ]
}
