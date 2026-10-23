#!/usr/bin/env bats

load helpers/common

REMOTE_DIR=""
REMOTE_NAME="shiplog-test"

make_entry() {
  SHIPLOG_SERVICE="hook-test" \
  SHIPLOG_STATUS="success" \
  SHIPLOG_REASON="hook validation" \
  SHIPLOG_TICKET="HOOK-1" \
  SHIPLOG_REGION="us-west-2" \
  SHIPLOG_CLUSTER="prod-1" \
  SHIPLOG_NAMESPACE="default" \
  SHIPLOG_IMAGE="ghcr.io/example/app" \
  SHIPLOG_TAG="v0.0.1" \
  SHIPLOG_RUN_URL="https://ci.example.local/run/123" \
  git shiplog --boring --yes write >/dev/null
}

install_hook_remote() {
  local hook_source="${SHIPLOG_HOOK_PATH:-$SHIPLOG_PROJECT_ROOT/contrib/hooks/pre-receive.shiplog}"
  install -m 0755 "$hook_source" "$REMOTE_DIR/hooks/pre-receive"
}

push_trust_ref() {
  git push -q "$REMOTE_NAME" refs/_shiplog/trust/root
}

push_policy_ref() {
  git push -q "$REMOTE_NAME" refs/_shiplog/policy/current
}

rotate_remote_trust() {
  local tmp_trust tmp_signers parent trust_blob signers_blob trust_tree commit_hash
  tmp_trust=$(mktemp)
  tmp_signers=$(mktemp)
  cat > "$tmp_trust" <<'JSON_TRUST'
{
  "version": 1,
  "id": "shiplog-trust-root",
  "threshold": 1,
  "maintainers": [
    {
      "name": "Rotated",
      "email": "rotated@example.com",
      "pgp_fpr": "ROTATEDFINGERPRINT",
      "role": "root",
      "revoked": false
    }
  ]
}
JSON_TRUST
  cat > "$tmp_signers" <<'SIGNERS_TRUST'
rotated@example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIROTATEDKEY
SIGNERS_TRUST
  parent=$(git --git-dir="$REMOTE_DIR" rev-parse --verify refs/_shiplog/trust/root 2>/dev/null || printf '')
  trust_blob=$(git --git-dir="$REMOTE_DIR" hash-object -w "$tmp_trust")
  signers_blob=$(git --git-dir="$REMOTE_DIR" hash-object -w "$tmp_signers")
  trust_tree=$(printf '100644 blob %s\ttrust.json\n100644 blob %s\tallowed_signers\n' "$trust_blob" "$signers_blob" | git --git-dir="$REMOTE_DIR" mktree)
  if [ -n "$parent" ]; then
    commit_hash=$(GIT_AUTHOR_NAME="Rotated Trust" GIT_AUTHOR_EMAIL="trust@shiplog.test" \
      GIT_COMMITTER_NAME="Rotated Trust" GIT_COMMITTER_EMAIL="trust@shiplog.test" \
      git --git-dir="$REMOTE_DIR" commit-tree "$trust_tree" -p "$parent" -m "shiplog: trust rotation")
    git --git-dir="$REMOTE_DIR" update-ref refs/_shiplog/trust/root "$commit_hash" "$parent"
  else
    commit_hash=$(GIT_AUTHOR_NAME="Rotated Trust" GIT_AUTHOR_EMAIL="trust@shiplog.test" \
      GIT_COMMITTER_NAME="Rotated Trust" GIT_COMMITTER_EMAIL="trust@shiplog.test" \
      git --git-dir="$REMOTE_DIR" commit-tree "$trust_tree" -m "shiplog: trust rotation")
    git --git-dir="$REMOTE_DIR" update-ref refs/_shiplog/trust/root "$commit_hash"
  fi
  rm -f "$tmp_trust" "$tmp_signers"
}

setup() {
  shiplog_install_cli
  shiplog_use_sandbox_repo
  shiplog_bootstrap_trust
  shiplog_bootstrap_policy_ref
  shiplog_write_local_policy
  export SHIPLOG_HOME="$SHIPLOG_PROJECT_ROOT"
  case ":$PATH:" in
    *":$SHIPLOG_PROJECT_ROOT/bin:"*) ;;
    *) export PATH="$SHIPLOG_PROJECT_ROOT/bin:$PATH" ;;
  esac
  git shiplog trust sync >/dev/null
  git config user.name "Shiplog Tester"
  git config user.email "shiplog-tester@example.com"
  export SHIPLOG_SIGN=0
  export SHIPLOG_AUTO_PUSH=0
  export SHIPLOG_ENV=prod
  # These cases exercise journal validation with an unsigned policy fixture. The hook
  # now requires policy commits to be signed by a current maintainer once a trust ref
  # exists (SLT.BUG.TRUST.009); relax that gate explicitly here.
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

@test "push fails when trust ref missing" {
  git shiplog init >/dev/null
  make_entry
  run git push "$REMOTE_NAME" refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
  # Accept either trust/policy missing depending on current hook state
  [[ "$output" == *"trust"* || "$output" == *"policy"* ]]
}

@test "push succeeds with valid trust and policy" {
  git shiplog init >/dev/null
  push_trust_ref
  push_policy_ref
  make_entry
  run git push "$REMOTE_NAME" refs/_shiplog/journal/prod
  [ "$status" -eq 0 ]
  run git --git-dir="$REMOTE_DIR" rev-parse refs/_shiplog/journal/prod
  [ "$status" -eq 0 ]
}

@test "push rejects stale trust oid" {
  git shiplog init >/dev/null
  push_trust_ref
  push_policy_ref
  make_entry
  run git push "$REMOTE_NAME" refs/_shiplog/journal/prod
  [ "$status" -eq 0 ]
  rotate_remote_trust
  make_entry
  run git push "$REMOTE_NAME" refs/_shiplog/journal/prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"trust_oid"* || "$output" == *"trust"* ]]
}
