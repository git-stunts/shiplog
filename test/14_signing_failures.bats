#!/usr/bin/env bats

load helpers/common

REMOTE_DIR=""
REMOTE_NAME="shiplog-test"

install_hook_remote() {
  local hook_source="${SHIPLOG_HOOK_PATH:-$SHIPLOG_PROJECT_ROOT/contrib/hooks/pre-receive.shiplog}"
  install -m 0755 "$hook_source" "$REMOTE_DIR/hooks/pre-receive"
}

push_trust_ref_only_trust_json() {
  # Create trust commit without allowed_signers to exercise hook validation
  mkdir -p .shiplog
  cat > .shiplog/trust.json <<'JSON'
{
  "version": 1,
  "id": "shiplog-trust-root",
  "threshold": 1,
  "maintainers": [
    {"name": "T", "email": "t@example.com", "pgp_fpr": null, "role": "root", "revoked": false}
  ]
}
JSON
  local trust_blob tree commit
  trust_blob=$(git hash-object -w .shiplog/trust.json)
  tree=$(printf '100644 blob %s\ttrust.json\n' "$trust_blob" | git mktree)
  commit=$(GIT_AUTHOR_NAME="Trust Init" GIT_AUTHOR_EMAIL="trust@shiplog.test" \
    GIT_COMMITTER_NAME="Trust Init" GIT_COMMITTER_EMAIL="trust@shiplog.test" \
    git commit-tree "$tree" -m "shiplog: trust root v1 (GENESIS)")
  git update-ref refs/_shiplog/trust/root "$commit"
  git push -q "$REMOTE_NAME" refs/_shiplog/trust/root
}

make_entry_signed() {
  SHIPLOG_SERVICE="signing-test" \
  SHIPLOG_STATUS="success" \
  SHIPLOG_REASON="signed entry" \
  SHIPLOG_TICKET="SIGN-2" \
  SHIPLOG_REGION="us-east-1" \
  SHIPLOG_CLUSTER="prod-1" \
  SHIPLOG_NAMESPACE="default" \
  SHIPLOG_IMAGE="ghcr.io/example/app" \
  SHIPLOG_TAG="v0.0.2" \
  SHIPLOG_RUN_URL="https://ci.example.local/run/789" \
  SHIPLOG_SIGN=1 \
  git shiplog --boring --yes write >/dev/null
}

make_entry_unsigned() {
  SHIPLOG_SERVICE="signing-test" \
  SHIPLOG_STATUS="success" \
  SHIPLOG_REASON="unsigned entry" \
  SHIPLOG_TICKET="SIGN-1" \
  SHIPLOG_REGION="us-east-1" \
  SHIPLOG_CLUSTER="prod-1" \
  SHIPLOG_NAMESPACE="default" \
  SHIPLOG_IMAGE="ghcr.io/example/app" \
  SHIPLOG_TAG="v0.0.1" \
  SHIPLOG_RUN_URL="https://ci.example.local/run/456" \
  SHIPLOG_SIGN=0 \
  git shiplog --boring --yes write >/dev/null
}

setup() {
  shiplog_install_cli
  shiplog_use_sandbox_repo
  shiplog_bootstrap_trust
  shiplog_bootstrap_policy_ref
  # Enforce signatures for this test file
  cat > .shiplog/policy.json <<'JSON'
{
  "version": "1.0.0",
  "require_signed": true,
  "authors": {"default_allowlist": ["shiplog-tester@example.com"]}
}
JSON
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
  # (SLT.BUG.TRUST.009) is relaxed explicitly so these cases test journal signing.
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

@test "rejects trust update without allowed_signers" {
  run push_trust_ref_only_trust_json
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing allowed_signers"* ]]
}

@test "rejects unsigned journal when require_signed=true" {
  # Push valid trust and policy first
  git push -q "$REMOTE_NAME" refs/_shiplog/trust/root
  "$SHIPLOG_PROJECT_ROOT"/scripts/shiplog-sync-policy.sh >/dev/null
  git push -q "$REMOTE_NAME" refs/_shiplog/policy/current
  git shiplog init >/dev/null
  make_entry_unsigned
  run git push "$REMOTE_NAME" refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
}

@test "server does not trust client-side allowed_signers" {
  # Server state: the trust ref (whose roster is the fixture key from
  # shiplog_bootstrap_trust) and a policy that requires signatures.
  git push -q "$REMOTE_NAME" refs/_shiplog/trust/root
  "$SHIPLOG_PROJECT_ROOT"/scripts/shiplog-sync-policy.sh >/dev/null
  git push -q "$REMOTE_NAME" refs/_shiplog/policy/current
  git shiplog init >/dev/null

  # Client: sign with a fresh SSH key and add it only to the *local*
  # allowed_signers. The trust ref on the server never sees this key.
  shiplog_setup_test_signing
  shiplog_write_allowed_signers_for_signing_key .shiplog/allowed_signers
  make_entry_signed
  local entry
  entry=$(git rev-parse refs/_shiplog/journal/prod)
  git cat-file commit "$entry" | grep -q '^gpgsig '

  # The client trusts its own roster...
  run env SHIPLOG_SIGN=1 git shiplog --boring verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK=1"* ]]

  # ...the server does not: its only roster is the trust ref. Assert the
  # reason, so a rejection for anything else (missing policy, author, ...)
  # cannot make this test pass.
  run git push "$REMOTE_NAME" refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"not accepted by the trust roster"* ]]
  run git --git-dir="$REMOTE_DIR" rev-parse --verify refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
}
