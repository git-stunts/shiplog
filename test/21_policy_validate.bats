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

# --- SLT.BUG.LIB.013: validate checks the working tree first; --ref / --file override ----

@test "policy validate checks the edited working-tree file, not the published ref" {
  shiplog_bootstrap_policy_ref
  printf '{"version":1}\n' > .shiplog/policy.json
  run git shiplog --boring policy validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"policy-file:.shiplog/policy.json"* ]]
  [[ "$output" == *"differs from refs/_shiplog/policy/current"* ]]
  run git shiplog --boring policy validate --ref
  [ "$status" -eq 0 ]
  [[ "$output" == *"Policy OK (policy-ref:refs/_shiplog/policy/current)"* ]]
  printf '{"version":"1.0.0","require_signed":false}\n' > other-policy.json
  run git shiplog --boring policy validate --file other-policy.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"Policy OK (file:other-policy.json)"* ]]
  run git shiplog --boring policy validate --file "$SHIPLOG_PROJECT_ROOT/test/fixtures/policy/invalid/misspelled-key.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requre_signed: unknown key"* ]]
}

@test "policy validate falls back to the ref when no working-tree file exists" {
  shiplog_bootstrap_policy_ref
  rm -f .shiplog/policy.json
  run git shiplog --boring policy validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"policy-ref:refs/_shiplog/policy/current"* ]]
}

# --- SLT.BUG.TOOL.006: sync-policy runs the real validator; callers abort before the ref moves ----

@test "policy require-signed aborts when the resulting document is invalid and leaves the ref alone" {
  printf '{"version":"1.0.0","authors":{}}\n' > .shiplog/policy.json
  run git rev-parse --verify refs/_shiplog/policy/current
  [ "$status" -ne 0 ]
  run git shiplog --boring policy require-signed true
  [ "$status" -ne 0 ]
  [[ "$output" == *"authors.default_allowlist"* ]]
  run git rev-parse --verify refs/_shiplog/policy/current
  [ "$status" -ne 0 ]
}

@test "sync-policy refuses an invalid policy with the validator's message" {
  printf '{"version":"1.0.0","require_signed":"yes"}\n' > .shiplog/policy.json
  run "$SHIPLOG_PROJECT_ROOT"/scripts/shiplog-sync-policy.sh .shiplog/policy.json
  [ "$status" -ne 0 ]
  [[ "$output" == *"require_signed: boolean required"* ]]
  run git rev-parse --verify refs/_shiplog/policy/current
  [ "$status" -ne 0 ]
}

@test "sync-policy signs the policy commit by default when a signing key is configured" {
  shiplog_setup_test_signing
  run "$SHIPLOG_PROJECT_ROOT"/scripts/shiplog-sync-policy.sh .shiplog/policy.json
  [ "$status" -eq 0 ]
  run git cat-file commit refs/_shiplog/policy/current
  [ "$status" -eq 0 ]
  [[ "$output" == *"gpgsig "* ]]
  # SHIPLOG_POLICY_SIGN=0 still forces an unsigned commit.
  run env SHIPLOG_POLICY_SIGN=0 "$SHIPLOG_PROJECT_ROOT"/scripts/shiplog-sync-policy.sh .shiplog/policy.json
  [ "$status" -eq 0 ]
  run git cat-file commit refs/_shiplog/policy/current
  [[ "$output" != *"gpgsig "* ]]
}

@test "sync-policy publishes unsigned with a hint when no signing key is configured" {
  [ -z "$(git config user.signingkey 2>/dev/null || true)" ] || skip "a signing key is configured in this build"
  run "$SHIPLOG_PROJECT_ROOT"/scripts/shiplog-sync-policy.sh .shiplog/policy.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"unsigned"* ]]
  run git cat-file commit refs/_shiplog/policy/current
  [[ "$output" != *"gpgsig "* ]]
}
