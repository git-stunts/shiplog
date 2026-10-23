#!/usr/bin/env bats

load helpers/common

REMOTE_DIR=""
REMOTE_NAME="shiplog-test"

install_hook_remote() {
  local hook_source="${SHIPLOG_HOOK_PATH:-$SHIPLOG_PROJECT_ROOT/contrib/hooks/pre-receive.shiplog}"
  install -m 0755 "$hook_source" "$REMOTE_DIR/hooks/pre-receive"
}

setup() {
  shiplog_install_cli
  shiplog_use_sandbox_repo
  shiplog_bootstrap_trust
  # Policy: prod requires signed; staging unsigned
  mkdir -p .shiplog
  cat > .shiplog/policy.json <<'JSON'
{
  "version": "1.0.0",
  "require_signed": false,
  "authors": {"default_allowlist": ["shiplog-tester@example.com"]},
  "deployment_requirements": {
    "prod": { "require_signed": true },
    "staging": { "require_signed": false }
  }
}
JSON
  # Publish policy ref
  "$SHIPLOG_PROJECT_ROOT"/scripts/shiplog-sync-policy.sh >/dev/null

  export SHIPLOG_HOME="$SHIPLOG_PROJECT_ROOT"
  case ":$PATH:" in
    *":$SHIPLOG_PROJECT_ROOT/bin:"*) ;;
    *) export PATH="$SHIPLOG_PROJECT_ROOT/bin:$PATH" ;;
  esac
  git shiplog trust sync >/dev/null
  git config user.name "Shiplog Tester"
  git config user.email "shiplog-tester@example.com"
  export SHIPLOG_AUTO_PUSH=0
  # Unsigned policy fixture; the maintainer-signature gate on policy pushes
  # (SLT.BUG.TRUST.009) is relaxed explicitly so these cases test per-env signing.
  export SHIPLOG_REQUIRE_SIGNED_POLICY=0

  REMOTE_DIR=$(mktemp -d)
  git init --bare "$REMOTE_DIR"
  install_hook_remote
  git remote remove "$REMOTE_NAME" >/dev/null 2>&1 || true
  git remote add "$REMOTE_NAME" "$REMOTE_DIR"
}

teardown() {
  git remote remove "$REMOTE_NAME" >/dev/null 2>&1 || true
  if [ -n "$REMOTE_DIR" ]; then
    rm -rf "$REMOTE_DIR"
  fi
  shiplog_cleanup_sandbox_repo
}

make_entry_unsigned() {
  local env="$1"
  SHIPLOG_SERVICE="svc" \
  SHIPLOG_STATUS="success" \
  SHIPLOG_REASON="per-env test" \
  SHIPLOG_TICKET="ENV-1" \
  SHIPLOG_REGION="us-east-1" \
  SHIPLOG_CLUSTER="prod-1" \
  SHIPLOG_NAMESPACE="default" \
  SHIPLOG_SIGN=0 \
  git shiplog --boring --yes write "$env" >/dev/null
}

@test "per-env require_signed:false relaxes a global require_signed:true (hook)" {
  # SLT.BUG.TRUST.011: jq's // treated an explicit false as absent. The hook side
  # is fixed here; the CLI resolves policy for the positional ENV under G5 (#99).
  cat > .shiplog/policy.json <<'JSON'
{
  "version": "1.0.0",
  "require_signed": true,
  "authors": {"default_allowlist": ["shiplog-tester@example.com"]},
  "deployment_requirements": {
    "staging": { "require_signed": false }
  }
}
JSON
  "$SHIPLOG_PROJECT_ROOT"/scripts/shiplog-sync-policy.sh >/dev/null
  git shiplog init >/dev/null
  git push -q "$REMOTE_NAME" refs/_shiplog/trust/root
  git push -q "$REMOTE_NAME" refs/_shiplog/policy/current

  # Hook: an unsigned staging entry passes because staging explicitly says false.
  make_entry_unsigned staging
  run git push "$REMOTE_NAME" refs/_shiplog/journal/staging
  [ "$status" -eq 0 ]

  # Hook: an explicitly unsigned prod entry is still rejected by the global true.
  make_entry_unsigned prod
  run git push "$REMOTE_NAME" refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required signature"* ]]
}

@test "deployment_requirements.default.require_signed is inherited by the hook like the CLI (#127)" {
  cat > .shiplog/policy.json <<'JSON'
{
  "version": "1.0.0",
  "require_signed": false,
  "authors": {"default_allowlist": ["shiplog-tester@example.com"]},
  "deployment_requirements": {
    "default": { "require_signed": true },
    "staging": { "require_signed": false }
  }
}
JSON
  "$SHIPLOG_PROJECT_ROOT"/scripts/shiplog-sync-policy.sh >/dev/null
  git shiplog init >/dev/null
  git push -q "$REMOTE_NAME" refs/_shiplog/trust/root
  git push -q "$REMOTE_NAME" refs/_shiplog/policy/current

  # Control: staging explicitly opts out, so an unsigned entry passes.
  make_entry_unsigned staging
  run git push "$REMOTE_NAME" refs/_shiplog/journal/staging
  [ "$status" -eq 0 ]

  # prod has no entry of its own: it inherits default=true, not the top-level false.
  make_entry_unsigned prod
  run git push "$REMOTE_NAME" refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required signature"* ]]
}

@test "unsigned allowed in staging but rejected in prod" {
  git shiplog init >/dev/null
  # Push trust and policy
  git push -q "$REMOTE_NAME" refs/_shiplog/trust/root
  git push -q "$REMOTE_NAME" refs/_shiplog/policy/current

  # Staging unsigned should succeed
  make_entry_unsigned staging
  run git push "$REMOTE_NAME" refs/_shiplog/journal/staging
  [ "$status" -eq 0 ]

  # Prod unsigned should fail
  make_entry_unsigned prod
  run git push "$REMOTE_NAME" refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required signature"* ]]
}
