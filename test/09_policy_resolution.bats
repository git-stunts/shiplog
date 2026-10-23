#!/usr/bin/env bats

# Policy resolution: one ordered precedence table per field.
#
#   field           1. env / CLI              2. git config                       3. policy document              4. default
#   authors         SHIPLOG_AUTHORS           shiplog.policy.allowedAuthors       authors.*                       unrestricted
#   signers file    SHIPLOG_ALLOWED_SIGNERS   shiplog.policy.allowedSignersFile   allow_ssh_signers_file          gpg.ssh.allowedSignersFile, else .shiplog/allowed_signers
#   require_signed  SHIPLOG_SIGN              shiplog.policy.requireSigned        deployment_requirements[ENV]    false
#                                                                                 -> .default -> top level
#
# The Docker runner exports SHIPLOG_SIGN=0 for unsigned builds, so every test
# here unsets it first and sets it only where the env layer is under test.

load helpers/common

setup() {
  shiplog_standard_setup
  git shiplog init >/dev/null
  git config user.name "Shiplog Test"
  git config user.email "shiplog-policy@example.com"
  mkdir -p .shiplog
  unset SHIPLOG_SIGN SHIPLOG_AUTHORS SHIPLOG_ALLOWED_SIGNERS
  export SHIPLOG_AUTO_PUSH=0
  export SHIPLOG_SERVICE="policy-test"
  export SHIPLOG_STATUS="success"
  export SHIPLOG_REASON="policy"
  export SHIPLOG_REGION="us-west-2"
  export SHIPLOG_CLUSTER="policy"
  export SHIPLOG_NAMESPACE="default"
  # Distinct signers files per source so the resolved path tells us who won.
  for name in env_signers cfg_signers gpg_signers; do
    printf 'shiplog-policy@example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY%s\n' "$name" > "$name"
  done
  cp env_signers .shiplog/policy_signers
}

teardown() {
  shiplog_standard_teardown
  unset SHIPLOG_SIGN SHIPLOG_AUTO_PUSH SHIPLOG_SERVICE SHIPLOG_STATUS SHIPLOG_REASON
  unset SHIPLOG_REGION SHIPLOG_CLUSTER SHIPLOG_NAMESPACE SHIPLOG_AUTHORS SHIPLOG_ALLOWED_SIGNERS
}

# --- table helpers ---------------------------------------------------------------

# Clear every source for every field; write a baseline document with the
# tester allowed so write-path checks still pass.
reset_sources() {
  unset SHIPLOG_AUTHORS SHIPLOG_ALLOWED_SIGNERS SHIPLOG_SIGN
  git config --unset-all shiplog.policy.allowedAuthors >/dev/null 2>&1 || true
  git config --unset-all shiplog.policy.allowedSignersFile >/dev/null 2>&1 || true
  git config --unset-all shiplog.policy.requireSigned >/dev/null 2>&1 || true
  git config --unset-all gpg.ssh.allowedSignersFile >/dev/null 2>&1 || true
  git update-ref -d refs/_shiplog/policy/current >/dev/null 2>&1 || true
  printf '{"version":"1.0.0"}\n' > .shiplog/policy.json
}

# apply_source FIELD SOURCE VALUE_KIND — VALUE_KIND is "win" or "lose" so a
# losing source carries a different, recognisable value.
apply_source() {
  local field="$1" source="$2" kind="$3"
  case "$field" in
    authors)
      case "$source" in
        env) export SHIPLOG_AUTHORS="$kind-env@example.com" ;;
        config) git config shiplog.policy.allowedAuthors "$kind-cfg@example.com" ;;
        policy)
          jq --arg a "$kind-policy@example.com" '.authors = {default_allowlist: [$a]}' .shiplog/policy.json > .shiplog/policy.tmp
          mv .shiplog/policy.tmp .shiplog/policy.json ;;
      esac ;;
    signers)
      case "$source" in
        env) export SHIPLOG_ALLOWED_SIGNERS="$PWD/env_signers" ;;
        config) git config shiplog.policy.allowedSignersFile "$PWD/cfg_signers" ;;
        policy)
          jq '.allow_ssh_signers_file = ".shiplog/policy_signers"' .shiplog/policy.json > .shiplog/policy.tmp
          mv .shiplog/policy.tmp .shiplog/policy.json ;;
        gpg) git config gpg.ssh.allowedSignersFile "$PWD/gpg_signers" ;;
      esac ;;
    require_signed)
      local value=true
      [ "$kind" = "lose" ] && value=false
      case "$source" in
        env) if [ "$value" = true ]; then export SHIPLOG_SIGN=1; else export SHIPLOG_SIGN=0; fi ;;
        config) git config shiplog.policy.requireSigned "$value" ;;
        policy)
          jq --argjson v "$value" '.require_signed = $v' .shiplog/policy.json > .shiplog/policy.tmp
          mv .shiplog/policy.tmp .shiplog/policy.json ;;
      esac ;;
  esac
}

# expected_value FIELD SOURCE — the value the winning source should produce.
expected_value() {
  local field="$1" source="$2"
  case "$field" in
    authors) printf 'win-%s@example.com' "$( [ "$source" = config ] && echo cfg || echo "$source")" ;;
    signers)
      case "$source" in
        env) printf '/env_signers' ;;
        config) printf '/cfg_signers' ;;
        policy) printf '/.shiplog/policy_signers' ;;
        gpg) printf '/gpg_signers' ;;
      esac ;;
    require_signed) printf 'true' ;;
  esac
}

json_field() {
  case "$1" in
    authors) printf '.allowed_authors' ;;
    signers) printf '.allowed_signers_file' ;;
    require_signed) printf '.require_signed' ;;
  esac
}

sources_field() {
  case "$1" in
    authors) printf '.sources.authors' ;;
    signers) printf '.sources.allowed_signers_file' ;;
    require_signed) printf '.sources.require_signed' ;;
  esac
}

source_label() {
  case "$1:$2" in
    authors:env) printf 'env:SHIPLOG_AUTHORS' ;;
    authors:config) printf 'git-config:shiplog.policy.allowedAuthors' ;;
    signers:env) printf 'env:SHIPLOG_ALLOWED_SIGNERS' ;;
    signers:config) printf 'git-config:shiplog.policy.allowedSignersFile' ;;
    signers:gpg) printf 'git-config:gpg.ssh.allowedSignersFile' ;;
    require_signed:env) printf 'env:SHIPLOG_SIGN' ;;
    require_signed:config) printf 'git-config:shiplog.policy.requireSigned' ;;
    *:policy) printf 'policy-file:.shiplog/policy.json' ;;
  esac
}

@test "precedence table: env beats git config beats policy document beats default, per field" {
  local failures=""
  while read -r field winner loser; do
    [ -n "$field" ] || continue
    reset_sources
    apply_source "$field" "$loser" lose
    apply_source "$field" "$winner" win
    run git shiplog policy show --json
    if [ "$status" -ne 0 ]; then
      failures+="[$field: $winner > $loser] policy show failed: $output"$'\n'
      continue
    fi
    local actual expected actual_src expected_src
    actual=$(jq -r "$(json_field "$field")" <<<"$output")
    expected=$(expected_value "$field" "$winner")
    actual_src=$(jq -r "$(sources_field "$field")" <<<"$output")
    expected_src=$(source_label "$field" "$winner")
    case "$field" in
      signers) [[ "$actual" == *"$expected" ]] || failures+="[$field: $winner > $loser] value '$actual' does not end with '$expected'"$'\n' ;;
      *) [ "$actual" = "$expected" ] || failures+="[$field: $winner > $loser] value '$actual' != '$expected'"$'\n' ;;
    esac
    [ "$actual_src" = "$expected_src" ] || failures+="[$field: $winner > $loser] source '$actual_src' != '$expected_src'"$'\n'
  done <<'TABLE'
authors env config
authors env policy
authors config policy
signers env config
signers env policy
signers config policy
signers policy gpg
signers config gpg
signers env gpg
require_signed env config
require_signed env policy
require_signed config policy
TABLE
  if [ -n "$failures" ]; then
    echo "$failures"
    return 1
  fi
}

@test "precedence: a losing source cannot flip require_signed back on (env/config false beat policy true)" {
  reset_sources
  apply_source require_signed policy win          # policy says true
  export SHIPLOG_SIGN=0                           # env says false -> env wins
  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .require_signed <<<"$output")" = "false" ]
  unset SHIPLOG_SIGN
  git config shiplog.policy.requireSigned false   # config says false -> config beats policy
  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .require_signed <<<"$output")" = "false" ]
  [ "$(jq -r .sources.require_signed <<<"$output")" = "git-config:shiplog.policy.requireSigned" ]
}

@test "precedence: defaults apply only when every source is silent" {
  reset_sources
  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .allowed_authors <<<"$output")" = "" ]
  [ "$(jq -r .require_signed <<<"$output")" = "false" ]
  [ "$(jq -r .sources.authors <<<"$output")" = "default" ]
  [ "$(jq -r .sources.require_signed <<<"$output")" = "default" ]
  [ "$(jq -r .sources.allowed_signers_file <<<"$output")" = "default" ]
  [[ "$(jq -r .allowed_signers_file <<<"$output")" == *"/.shiplog/allowed_signers" ]]
}

@test "SLT.BUG.LIB.001: policy signers path beats gpg.ssh.allowedSignersFile, which is only a fallback" {
  reset_sources
  jq '.allow_ssh_signers_file = ".shiplog/allowed_signers"' .shiplog/policy.json > .shiplog/policy.tmp
  mv .shiplog/policy.tmp .shiplog/policy.json
  git config gpg.ssh.allowedSignersFile /tmp/other_signers
  export SHIPLOG_SIGN=1
  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  [[ "$(jq -r .allowed_signers_file <<<"$output")" == *"/.shiplog/allowed_signers" ]]
  [ "$(jq -r .sources.allowed_signers_file <<<"$output")" = "policy-file:.shiplog/policy.json" ]
  # No policy value and no env: the gpg.ssh fallback is used and reported.
  reset_sources
  git config gpg.ssh.allowedSignersFile /tmp/other_signers
  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .allowed_signers_file <<<"$output")" = "/tmp/other_signers" ]
  [ "$(jq -r .sources.allowed_signers_file <<<"$output")" = "git-config:gpg.ssh.allowedSignersFile" ]
}

@test "SLT.BUG.LIB.002: SHIPLOG_AUTHORS beats shiplog.policy.allowedAuthors; git config beats the policy ref" {
  reset_sources
  git config shiplog.policy.allowedAuthors bot@ci
  run env SHIPLOG_AUTHORS=me@x git shiplog policy show --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .allowed_authors <<<"$output")" = "me@x" ]
  # Policy ref lists a@x, git config lists b@x, no env -> git config wins.
  reset_sources
  printf '{"version":"1.0.0","authors":{"default_allowlist":["a@x"]}}\n' > .shiplog/policy.json
  shiplog_bootstrap_policy_ref >/dev/null
  printf '{"version":"1.0.0","authors":{"default_allowlist":["a@x"]}}\n' > .shiplog/policy.json
  "$SHIPLOG_PROJECT_ROOT"/scripts/shiplog-sync-policy.sh .shiplog/policy.json >/dev/null 2>&1
  git config shiplog.policy.allowedAuthors b@x
  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .allowed_authors <<<"$output")" = "b@x" ]
  [ "$(jq -r .source <<<"$output")" = "policy-ref:refs/_shiplog/policy/current" ]
  git config --unset-all shiplog.policy.allowedAuthors
  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .allowed_authors <<<"$output")" = "a@x" ]
}

@test "policy show reports file source and the environment it resolved" {
  cat <<POLICY > .shiplog/policy.json
{
  "version": "1.0.0",
  "require_signed": false,
  "authors": {
    "default_allowlist": [
      "shiplog-policy@example.com"
    ]
  }
}
POLICY
  run git shiplog policy --boring show
  [ "$status" -eq 0 ]
  [[ "$output" == *"Source: policy-file:.shiplog/policy.json"* ]]
  [[ "$output" == *"Environment: prod"* ]]
  [[ "$output" == *"Allowed Authors: shiplog-policy@example.com"* ]]
  run git shiplog --env staging policy --boring show
  [ "$status" -eq 0 ]
  [[ "$output" == *"Environment: staging"* ]]
}

@test "policy allowlist permits write" {
  cat <<POLICY > .shiplog/policy.json
{
  "version": "1.0.0",
  "require_signed": false,
  "authors": {
    "default_allowlist": [
      "shiplog-policy@example.com"
    ]
  }
}
POLICY
  run git shiplog --yes write
  [ "$status" -eq 0 ]
}

# --- per-environment resolution -------------------------------------------------------

@test "SLT.BUG.LIB.004: deployment_requirements.default inheritance applies to require_signed" {
  cat <<POLICY > .shiplog/policy.json
{"version":"1.0.0","deployment_requirements":{"default":{"require_signed":true},"prod":{"require_ticket":true}}}
POLICY
  run git shiplog --env prod policy show --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .require_signed <<<"$output")" = "true" ]
  run git shiplog policy show --env staging --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .require_signed <<<"$output")" = "true" ]
  # An explicit per-env false beats both the default entry and a global true.
  cat <<POLICY > .shiplog/policy.json
{"version":"1.0.0","require_signed":true,"deployment_requirements":{"default":{"require_signed":true},"staging":{"require_signed":false}}}
POLICY
  run git shiplog policy show --env staging --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .require_signed <<<"$output")" = "false" ]
  run git shiplog policy show --env prod --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .require_signed <<<"$output")" = "true" ]
}

@test "SLT.BUG.CLI.003: positional ENV drives require_signed (write staging ok, write prod needs the roster)" {
  cat <<POLICY > .shiplog/policy.json
{"version":"1.0.0","require_signed":false,"authors":{"default_allowlist":["shiplog-policy@example.com"]},"deployment_requirements":{"prod":{"require_signed":true}}}
POLICY
  export SHIPLOG_ALLOWED_SIGNERS=/nonexistent/allowed_signers
  run git shiplog --boring --yes write staging
  [ "$status" -eq 0 ]
  run env SHIPLOG_ENV=staging git shiplog --boring --yes write prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"allowed signers file"* ]]
  run git show-ref refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
}

@test "SLT.BUG.CLI.003: positional ENV drives authors.env_overrides" {
  cat <<POLICY > .shiplog/policy.json
{"version":"1.0.0","require_signed":false,"authors":{"default_allowlist":["deploy-bot@example.com"],"env_overrides":{"prod":["shiplog-policy@example.com"],"staging":["other@example.com"]}}}
POLICY
  run git shiplog --boring --yes write staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in allowlist"* ]]
  run git shiplog --boring --yes write prod
  [ "$status" -eq 0 ]
}

@test "SLT.BUG.CLI.003: verify ENV evaluates that environment's rules" {
  printf '{"version":"1.0.0","require_signed":false}\n' > .shiplog/policy.json
  run git shiplog --boring --yes write staging
  [ "$status" -eq 0 ]
  run git shiplog --boring --yes write prod
  [ "$status" -eq 0 ]
  # Now staging excludes the tester while prod includes them.
  cat <<POLICY > .shiplog/policy.json
{"version":"1.0.0","require_signed":false,"authors":{"default_allowlist":["deploy-bot@example.com"],"env_overrides":{"prod":["shiplog-policy@example.com"],"staging":["other@example.com"]}}}
POLICY
  run git shiplog --boring verify staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"unauthorized author"* ]]
  run git shiplog --boring verify prod
  [ "$status" -eq 0 ]
}
