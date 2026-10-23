#!/usr/bin/env bats

# Fail-closed behaviour of policy resolution and boolean switches:
#   SLT.BUG.LIB.010 (#156) malformed policy stops the command
#   SLT.BUG.LIB.003 (#104) non-boolean require_signed / SHIPLOG_SIGN rejected
#   SLT.BUG.CLI.007 (#118) --dry-run=VALUE normalized, unknown rejected
#   SLT.BUG.CLI.015 (#126) policy subcommands do not need the signers file

load helpers/common

setup() {
  shiplog_standard_setup
  git shiplog init >/dev/null
  unset SHIPLOG_SIGN
  export SHIPLOG_AUTO_PUSH=0
  export SHIPLOG_SERVICE="fail-closed"
  export SHIPLOG_STATUS="success"
  export SHIPLOG_REASON="policy"
  export SHIPLOG_REGION="us-west-2"
  export SHIPLOG_CLUSTER="c1"
  export SHIPLOG_NAMESPACE="default"
}

teardown() {
  shiplog_standard_teardown
  unset SHIPLOG_SIGN SHIPLOG_AUTO_PUSH SHIPLOG_SERVICE SHIPLOG_STATUS SHIPLOG_REASON
  unset SHIPLOG_REGION SHIPLOG_CLUSTER SHIPLOG_NAMESPACE SHIPLOG_BORING
}

# Remove every roster the sandbox has so "signing on" has nothing to verify with.
drop_signers() {
  rm -f .shiplog/allowed_signers
  git config --unset-all gpg.ssh.allowedSignersFile >/dev/null 2>&1 || true
}

@test "SLT.BUG.LIB.010: a wrong-typed field stops policy show and write (no fallback to defaults)" {
  printf '{"version":"1.0.0","require_signed":true,"authors":"everyone"}\n' > .shiplog/policy.json
  run git shiplog policy show --boring
  [ "$status" -ne 0 ]
  [[ "$output" == *"authors"* ]]
  [[ "$output" != *"Source: default"* ]]
  run git shiplog --boring --yes write
  [ "$status" -ne 0 ]
  [[ "$output" == *"authors"* ]]
  run git show-ref refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
}

@test "SLT.BUG.LIB.010: truncated policy JSON stops policy show and write" {
  printf '{"version":"1.0.0","require_signed":true,' > .shiplog/policy.json
  run git shiplog policy show --boring
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid JSON"* ]]
  run git shiplog --boring --yes write
  [ "$status" -ne 0 ]
  run git show-ref refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
}

@test "SLT.BUG.LIB.010: a malformed policy ref is not skipped in favour of the working tree" {
  printf '{"version":"1.0.0","requre_signed":true}\n' > .shiplog/policy.json
  "$SHIPLOG_PROJECT_ROOT"/scripts/shiplog-sync-policy.sh .shiplog/policy.json >/dev/null 2>&1 || true
  # The validator in the sync script refuses it; publish the broken ref by hand.
  local blob sub tree commit
  blob=$(git hash-object -w .shiplog/policy.json)
  sub=$(printf '100644 blob %s\tpolicy.json\n' "$blob" | git mktree)
  tree=$(printf '040000 tree %s\t.shiplog\n' "$sub" | git mktree)
  commit=$(git commit-tree "$tree" -m "broken policy")
  git update-ref refs/_shiplog/policy/current "$commit"
  shiplog_write_local_policy
  run git shiplog policy show --boring
  [ "$status" -ne 0 ]
  [[ "$output" == *"requre_signed"* ]]
  [[ "$output" == *"policy-ref:refs/_shiplog/policy/current"* ]]
}

@test "SLT.BUG.LIB.010: with no policy document at all, policy show reports Source: default" {
  rm -f .shiplog/policy.json
  run git shiplog policy show --boring
  [ "$status" -eq 0 ]
  [[ "$output" == *"Source: default"* ]]
  # A trust ref exists, so the one-line warning about defaults is printed.
  [[ "$output" == *"no policy document found"* ]]
}

@test "SLT.BUG.LIB.003: validator rejects a non-boolean per-env require_signed" {
  printf '{"version":"1.0.0","require_signed":false,"deployment_requirements":{"prod":{"require_signed":"required"}}}\n' > .shiplog/policy.json
  run git shiplog --boring policy validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"deployment_requirements.prod.require_signed: boolean required"* ]]
}

@test "SLT.BUG.LIB.003: SHIPLOG_SIGN=required dies naming the value instead of writing unsigned" {
  run env SHIPLOG_SIGN=required git shiplog --boring --yes write
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHIPLOG_SIGN"* ]]
  [[ "$output" == *"'required'"* ]]
  run git show-ref refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
}

@test "SLT.BUG.LIB.003: SHIPLOG_SIGN=TRUE is parsed as true (signers-file error, not an unsigned write)" {
  drop_signers
  run env SHIPLOG_SIGN=TRUE git shiplog --boring --yes write
  [ "$status" -ne 0 ]
  [[ "$output" == *"allowed signers file"* ]]
  run git show-ref refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
}

@test "SLT.BUG.LIB.003: SHIPLOG_BORING=TRUE selects boring output" {
  run env SHIPLOG_SIGN=0 git shiplog --boring --yes write
  [ "$status" -eq 0 ]
  run env SHIPLOG_BORING=TRUE SHIPLOG_SIGN=0 git shiplog ls
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\e['* ]]
  [[ "$output" == *"Commit"*"Status"* ]]
  run env SHIPLOG_BORING=sometimes SHIPLOG_SIGN=0 git shiplog ls
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHIPLOG_BORING"* ]]
}

@test "SLT.BUG.CLI.007: --dry-run=True is a dry run; --dry-run=maybe is an error" {
  run env SHIPLOG_SIGN=0 git shiplog --boring --yes write --dry-run=True
  [ "$status" -eq 0 ]
  run git show-ref refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
  run env SHIPLOG_SIGN=0 git shiplog --boring --yes write --dry-run=YES
  [ "$status" -eq 0 ]
  run git show-ref refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
  run env SHIPLOG_SIGN=0 git shiplog --boring --yes write --dry-run=maybe
  [ "$status" -ne 0 ]
  [[ "$output" == *"--dry-run"* ]]
  run git show-ref refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
  run env SHIPLOG_SIGN=0 SHIPLOG_DRY_RUN=perhaps git shiplog --boring --yes write
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHIPLOG_DRY_RUN"* ]]
}

@test "SLT.BUG.CLI.009: SHIPLOG_AUTO_PUSH=sometimes is rejected" {
  run env SHIPLOG_AUTO_PUSH=sometimes SHIPLOG_SIGN=0 git shiplog --boring --yes write
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHIPLOG_AUTO_PUSH"* ]]
}

@test "SLT.BUG.CLI.015: policy subcommands work while signing is on and the roster is missing" {
  drop_signers
  run git shiplog --boring policy require-signed true
  [ "$status" -eq 0 ]
  run git shiplog --boring policy show
  [ "$status" -eq 0 ]
  [[ "$output" == *"Require Signed: enabled"* ]]
  [[ "$output" == *"Warning"*"allowed signers file"* ]]
  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .allowed_signers_file_exists <<<"$output")" = "false" ]
  [ "$(jq -r '.warnings | length' <<<"$output")" -ge 1 ]
  run git shiplog --boring policy validate
  [ "$status" -eq 0 ]
  # The write path still refuses.
  run git shiplog --boring --yes write
  [ "$status" -ne 0 ]
  [[ "$output" == *"allowed signers file"* ]]
  # And the recovery command works.
  run git shiplog --boring policy require-signed false
  [ "$status" -eq 0 ]
  run git shiplog --boring policy toggle
  [ "$status" -eq 0 ]
  [ "$(jq -r .require_signed .shiplog/policy.json)" = "true" ]
  run git shiplog --boring policy toggle
  [ "$status" -eq 0 ]
  [ "$(jq -r .require_signed .shiplog/policy.json)" = "false" ]
}

@test "SLT.BUG.LIB.010: an empty or multi-value policy document stops policy show and write" {
  # Positive control: a single valid document loads.
  printf '{"version":"1.0.0","require_signed":false}\n' > .shiplog/policy.json
  run git shiplog policy show --boring
  [ "$status" -eq 0 ]
  [[ "$output" == *"Source: policy-file:.shiplog/policy.json"* ]]

  local doc
  for doc in '' '   ' $'{"version":"1.0.0","require_signed":false}\n{"version":"1.0.0","require_signed":true}'; do
    printf '%s' "$doc" > .shiplog/policy.json
    run git shiplog policy show --boring
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly one JSON value"* ]]
    run env SHIPLOG_SIGN=0 git shiplog --boring --yes write
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly one JSON value"* ]]
    run git show-ref refs/_shiplog/journal/prod
    [ "$status" -ne 0 ]
    run "$SHIPLOG_PROJECT_ROOT"/scripts/policy/validate.sh .shiplog/policy.json
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly one JSON value"* ]]
    run git shiplog --boring policy validate
    [ "$status" -ne 0 ]
  done
}

@test "SLT.BUG.LIB.010: an inherited SHIPLOG_POLICY_LOADED_ENV does not skip the policy document" {
  printf '{"version":"1.0.0","authors":{"default_allowlist":["only-me@example.com"]}}\n' > .shiplog/policy.json
  run env SHIPLOG_POLICY_LOADED_ENV=prod git shiplog policy show --boring
  [ "$status" -eq 0 ]
  [[ "$output" == *"Allowed Authors: only-me@example.com"* ]]
  run env SHIPLOG_POLICY_LOADED_ENV=prod SHIPLOG_SIGN=0 git shiplog --boring --yes write
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in allowlist: only-me@example.com"* ]]
  run git show-ref refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
}

@test "SLT.BUG.LIB.010: a newline or whitespace inside a policy string cannot shift or split fields" {
  # Positive control: the allowlist is read when the strings are clean.
  printf '{"version":"1.0.0","allow_ssh_signers_file":"x","authors":{"default_allowlist":["a@example.com"]}}\n' > .shiplog/policy.json
  run git shiplog policy show --boring
  [ "$status" -eq 0 ]
  [[ "$output" == *"Allowed Authors: a@example.com"* ]]
  # A newline in the signers path would otherwise push the allowlist off its line.
  printf '{"version":"1.0.0","allow_ssh_signers_file":"x\\nrefs/_shiplog/notes/evil","authors":{"default_allowlist":["a@example.com"]}}\n' > .shiplog/policy.json
  run git shiplog policy show --boring
  [ "$status" -ne 0 ]
  [[ "$output" == *"allow_ssh_signers_file"* ]]
  [[ "$output" != *"Allowed Authors: <none>"* ]]
  # An author entry with whitespace would otherwise become two authors.
  printf '{"version":"1.0.0","authors":{"default_allowlist":["a@example.com b@example.com"]}}\n' > .shiplog/policy.json
  run git shiplog policy show --boring
  [ "$status" -ne 0 ]
  [[ "$output" == *"authors.default_allowlist"* ]]
  printf '{"version":"1.0.0","authors":{"default_allowlist":["a@example.com"],"env_overrides":{"prod":["b@example.com\\tc@example.com"]}}}\n' > .shiplog/policy.json
  run git shiplog --boring policy validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"authors.env_overrides.prod"* ]]
}
