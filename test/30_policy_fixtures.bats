#!/usr/bin/env bats

# Validator parity and repository-root resolution:
#   SLT.BUG.LIB.005 (#128) fixtures under test/fixtures/policy/{valid,invalid}
#   SLT.BUG.LIB.007 (#129) .shiplog/* resolve from the repository root
#   SLT.BUG.LIB.008 (#142) examples/policy.json is literal
#   SLT.BUG.LIB.006 (#141) journals_ref_prefix / anchors_ref_prefix are reserved

load helpers/common

FIXTURES=""
VALIDATOR=""

setup() {
  shiplog_standard_setup
  git shiplog init >/dev/null
  FIXTURES="$SHIPLOG_PROJECT_ROOT/test/fixtures/policy"
  VALIDATOR="$SHIPLOG_PROJECT_ROOT/scripts/policy/validate.sh"
  unset SHIPLOG_SIGN
  export SHIPLOG_AUTO_PUSH=0
  export SHIPLOG_SERVICE="fixtures"
  export SHIPLOG_STATUS="success"
  export SHIPLOG_REASON="fixtures"
  export SHIPLOG_REGION="us-west-2"
  export SHIPLOG_CLUSTER="c1"
  export SHIPLOG_NAMESPACE="default"
}

teardown() {
  shiplog_standard_teardown
  unset SHIPLOG_SIGN SHIPLOG_AUTO_PUSH SHIPLOG_SERVICE SHIPLOG_STATUS SHIPLOG_REASON
  unset SHIPLOG_REGION SHIPLOG_CLUSTER SHIPLOG_NAMESPACE
}

@test "fixtures: every valid policy fixture passes the jq validator" {
  [ -x "$VALIDATOR" ] || skip "validator script missing"
  local n=0 failures=""
  for f in "$FIXTURES"/valid/*.json; do
    n=$((n + 1))
    run "$VALIDATOR" "$f"
    if [ "$status" -ne 0 ] || [ -n "$output" ]; then
      failures+="$(basename "$f"): status=$status output=$output"$'\n'
    fi
  done
  [ "$n" -ge 3 ]
  if [ -n "$failures" ]; then echo "$failures"; return 1; fi
}

@test "fixtures: every invalid policy fixture is rejected with exit 1 and a named path (never a jq crash)" {
  [ -x "$VALIDATOR" ] || skip "validator script missing"
  local n=0 failures=""
  for f in "$FIXTURES"/invalid/*.json; do
    n=$((n + 1))
    run "$VALIDATOR" "$f"
    if [ "$status" -ne 1 ] || [ -z "$output" ] || [[ "$output" == *"jq: error"* ]]; then
      failures+="$(basename "$f"): status=$status output=$output"$'\n'
    fi
  done
  [ "$n" -ge 3 ]
  if [ -n "$failures" ]; then echo "$failures"; return 1; fi
  run "$VALIDATOR" "$FIXTURES/invalid/env-entry-array.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"deployment_requirements.prod: object required"* ]]
  run "$VALIDATOR" "$FIXTURES/invalid/misspelled-key.json"
  [[ "$output" == *"requre_signed: unknown key"* ]]
  run "$VALIDATOR" "$FIXTURES/invalid/top-level-array.json"
  [[ "$output" == *"policy: object required"* ]]
}

@test "fixtures: jq validator and ajv agree on every fixture (when ajv is installed)" {
  command -v ajv >/dev/null 2>&1 || skip "ajv not installed in this container"
  local schema="$SHIPLOG_PROJECT_ROOT/examples/policy.schema.json" failures=""
  for f in "$FIXTURES"/valid/*.json "$FIXTURES"/invalid/*.json; do
    local jq_ok=1 ajv_ok=1
    "$VALIDATOR" "$f" >/dev/null 2>&1 || jq_ok=0
    ajv validate --spec=draft2020 -s "$schema" -d "$f" >/dev/null 2>&1 || ajv_ok=0
    [ "$jq_ok" = "$ajv_ok" ] || failures+="$(basename "$f"): jq=$jq_ok ajv=$ajv_ok"$'\n'
  done
  if [ -n "$failures" ]; then echo "$failures"; return 1; fi
}

@test "fixtures: setup --strictness balanced writes exactly the balanced fixture" {
  run git shiplog --boring setup --strictness balanced --authors "shiplog-tester@example.com ops@example.com" --dry-run
  [ "$status" -eq 0 ]
  local produced
  produced=$(printf '%s\n' "$output" | sed -n '/^{/,/^}/p' | jq -cS .)
  [ "$produced" = "$(jq -cS . "$FIXTURES/valid/setup-balanced.json")" ]
}

@test "fixtures: config --apply writes exactly the prod-only fixture" {
  rm -f .shiplog/policy.json
  run env SHIPLOG_BORING=1 SHIPLOG_CONFIG_HOST=self-hosted SHIPLOG_CONFIG_REQSIG=prod-only git shiplog config --interactive --apply
  [ "$status" -eq 0 ]
  [ "$(jq -cS . .shiplog/policy.json)" = "$(jq -cS . "$FIXTURES/valid/config-apply-prod-only.json")" ]
  run git shiplog --boring policy validate
  [ "$status" -eq 0 ]
}

@test "fixtures: the example fixture is byte-identical to examples/policy.json" {
  # git hash-object, not cmp: the arch and fedora matrix images have no cmp.
  [ "$(git hash-object "$SHIPLOG_PROJECT_ROOT/examples/policy.json")" = "$(git hash-object "$FIXTURES/valid/example-full.json")" ]
}

@test "SLT.BUG.LIB.008: examples/policy.json is usable as-is (literal addresses, no shell syntax)" {
  cp "$SHIPLOG_PROJECT_ROOT/examples/policy.json" .shiplog/policy.json
  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  local authors
  authors=$(jq -r .allowed_authors <<<"$output")
  [ -n "$authors" ]
  [[ "$authors" != *'$'* ]]
  [[ "$authors" == *"deploy-bot@example.com"* ]]
  run git shiplog --boring policy validate
  [ "$status" -eq 0 ]
}

@test "SLT.BUG.LIB.007: policy and plugins resolve from the repository root when run from a subdirectory" {
  mkdir -p .shiplog/plugins/pre-commit-message.d
  cat <<'PLUGIN' > .shiplog/plugins/pre-commit-message.d/10-marker.sh
#!/usr/bin/env bash
set -euo pipefail
awk '{ gsub(/fixtures/, "fixtures plugin-ran-from-root"); print }'
PLUGIN
  chmod +x .shiplog/plugins/pre-commit-message.d/10-marker.sh
  printf '{"version":"1.0.0","require_signed":false,"authors":{"default_allowlist":["shiplog-tester@example.com"]}}\n' > .shiplog/policy.json
  mkdir -p services/api
  cd services/api
  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  [[ "$(jq -r .source <<<"$output")" == policy-file:* ]]
  run git shiplog --boring --yes write
  [ "$status" -eq 0 ]
  local message
  message=$(git show -s --format=%B refs/_shiplog/journal/prod)
  [[ "$message" == *"plugin-ran-from-root"* ]]
}

@test "SLT.BUG.LIB.007: run keeps the wrapped command in the caller's cwd" {
  mkdir -p services/api
  cd services/api
  run git shiplog --boring run --service t --reason pwd -- pwd
  [ "$status" -eq 0 ]
  local sha note
  sha=$(git rev-parse refs/_shiplog/journal/prod)
  note=$(git notes --ref="${SHIPLOG_NOTES_REF:-refs/_shiplog/notes/logs}" show "$sha")
  [[ "$note" == *"/services/api"* ]]
}

@test "SLT.BUG.LIB.006: journals_ref_prefix / anchors_ref_prefix are reserved and no longer parsed" {
  # Nothing reads the policy keys (jq .journals_ref_prefix / the old POLICY_* vars).
  # `refs root show --json` has its own journals_prefix/anchors_prefix output
  # fields, derived from the ref root, which are not policy parsing.
  run grep -rn 'POLICY_JOURNALS_PREFIX\|POLICY_ANCHORS_PREFIX\|journals_ref_prefix\|anchors_ref_prefix' "$SHIPLOG_PROJECT_ROOT/lib" "$SHIPLOG_PROJECT_ROOT/bin"
  [ "$status" -ne 0 ]
  # Still accepted by the validator for forward compatibility.
  printf '{"version":"1.0.0","journals_ref_prefix":"refs/_shiplog/j2/","anchors_ref_prefix":"refs/_shiplog/a2/"}\n' > .shiplog/policy.json
  run git shiplog --boring policy validate
  [ "$status" -eq 0 ]
}
