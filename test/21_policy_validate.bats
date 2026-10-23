#!/usr/bin/env bats

load helpers/common

POLICY_VALIDATOR=""

require_policy_validator() {
  [ -x "$POLICY_VALIDATOR" ] || skip "policy validator helper missing"
}

# Most negative-path tests invoke both `git shiplog policy validate` and the
# standalone validator script to ensure the CLI and reusable filter stay in lockstep.

setup() {
  shiplog_standard_setup
  POLICY_VALIDATOR="$SHIPLOG_PROJECT_ROOT/scripts/policy/validate.sh"
}

teardown() {
  shiplog_standard_teardown
}

@test "policy validate succeeds on working policy" {
  # Standard setup writes a minimal working .shiplog/policy.json
  run git shiplog policy validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"Policy OK"* ]]
}

@test "policy validate fails on malformed policy (missing fields)" {
  mkdir -p .shiplog
  cat > .shiplog/policy.json <<'JSON'
{
  "version": 1,
  "authors": {}
}
JSON
  run git shiplog policy validate
  [ "$status" -ne 0 ]
}

@test "policy validate fails on invalid JSON" {
  mkdir -p .shiplog
  printf '{"version":' > .shiplog/policy.json
  run git shiplog policy validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"not parseable"* || "$output" == *"parse"* ]]
}

@test "policy validate catches bad types and ref prefixes" {
  mkdir -p .shiplog
  cat > .shiplog/policy.json <<'JSON'
{
  "version": 1,
  "require_signed": "yes",
  "authors": {"default_allowlist": []},
  "deployment_requirements": "nope",
  "notes_ref": "heads/notes"
}
JSON
  run git shiplog policy validate
  [ "$status" -ne 0 ]
  require_policy_validator
  # Double-check both entry points stay in sync on validation failures.
  run "$POLICY_VALIDATOR" .shiplog/policy.json
  [ "$status" -ne 0 ]
  [[ "$output" == *"require_signed"* ]]
  [[ "$output" == *"authors.default_allowlist"* ]]
  [[ "$output" == *"deployment_requirements"* ]]
  [[ "$output" == *"notes_ref"* ]]
}

@test "policy validate prints the validator errors instead of exiting silently" {
  # SLT.BUG.TRUST.012: errexit used to abort the capture before any output.
  mkdir -p .shiplog
  cat > .shiplog/policy.json <<'JSON'
{
  "version": "1.0.0",
  "require_signed": "yes",
  "authors": {"default_allowlist": ["ship@example.com"]}
}
JSON
  run git shiplog --boring policy validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"require_signed"* ]]
  [[ "$output" == *"policy validation failed"* ]]
}

@test "policy validate fails when ff_only is not boolean" {
  mkdir -p .shiplog
  cat > .shiplog/policy.json <<'JSON'
{
  "version": "1.0.0",
  "ff_only": "yes",
  "authors": {"default_allowlist": ["ship@example.com"]}
}
JSON
  run git shiplog policy validate
  [ "$status" -ne 0 ]
  require_policy_validator
  run "$POLICY_VALIDATOR" .shiplog/policy.json
  [ "$status" -ne 0 ]
  [[ "$output" == *"ff_only"* ]]
}

@test "policy validate fails when deployment_requirements empty" {
  mkdir -p .shiplog
  cat > .shiplog/policy.json <<'JSON'
{
  "version": "1.0.0",
  "authors": {"default_allowlist": ["ship@example.com"]},
  "deployment_requirements": {}
}
JSON
  run git shiplog policy validate
  [ "$status" -ne 0 ]
  require_policy_validator
  run "$POLICY_VALIDATOR" .shiplog/policy.json
  [ "$status" -ne 0 ]
  [[ "$output" == *"deployment_requirements"* ]]
}

@test "policy validate fails when require_where duplicates" {
  mkdir -p .shiplog
  cat > .shiplog/policy.json <<'JSON'
{
  "version": "1.0.0",
  "authors": {"default_allowlist": ["ship@example.com"]},
  "deployment_requirements": {
    "prod": {
      "require_where": ["region", "region"]
    }
  }
}
JSON
  run git shiplog policy validate
  [ "$status" -ne 0 ]
  require_policy_validator
  run "$POLICY_VALIDATOR" .shiplog/policy.json
  [ "$status" -ne 0 ]
  [[ "$output" == *"require_where"* ]]
}

@test "policy validate fails when require_where contains unsupported value" {
  mkdir -p .shiplog
  cat > .shiplog/policy.json <<'JSON'
{
  "version": "1.0.0",
  "authors": {"default_allowlist": ["ship@example.com"]},
  "deployment_requirements": {
    "prod": {
      "require_where": ["region", "shard"]
    }
  }
}
JSON
  run git shiplog policy validate
  [ "$status" -ne 0 ]
  require_policy_validator
  run "$POLICY_VALIDATOR" .shiplog/policy.json
  [ "$status" -ne 0 ]
  [[ "$output" == *"require_where"* ]]
}

@test "policy require-signed coerces numeric version to canonical semver" {
  mkdir -p .shiplog
  cat > .shiplog/policy.json <<'JSON'
{
  "version": 1,
  "require_signed": false,
  "authors": {"default_allowlist": ["ship@example.com"]}
}
JSON
  run git shiplog policy require-signed true
  [ "$status" -eq 0 ]
  run jq -r '.version' .shiplog/policy.json
  [ "$status" -eq 0 ]
  [ "$output" = "1.0.0" ]
  run jq -r '.require_signed' .shiplog/policy.json
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}
