#!/usr/bin/env bats

load helpers/common

setup() {
  shiplog_standard_setup
  git shiplog init >/dev/null
  # Use default test identity from helpers (allowed by policy)
}

teardown() {
  shiplog_standard_teardown
}

@test "publish pushes journal regardless of auto-push settings" {
  # Set env to auto-push, git config to 0, and pass --push to publish
  export SHIPLOG_AUTO_PUSH=0
  git config shiplog.autoPush false
  # Create a bare remote and set as origin
  REMOTE_DIR=$(mktemp -d)
  git remote remove origin >/dev/null 2>&1 || true
  git init -q --bare "$REMOTE_DIR"
  git remote add origin "$REMOTE_DIR"
  # Write an entry locally (no push)
  export SHIPLOG_BORING=1
  export SHIPLOG_SERVICE=pub
  export SHIPLOG_STATUS=success
  export SHIPLOG_REASON=t
  export SHIPLOG_REGION=us
  export SHIPLOG_CLUSTER=c
  export SHIPLOG_NAMESPACE=ns
  run git shiplog write --env staging
  [ "$status" -eq 0 ]
  # Publish should push even if auto-push settings are disabled (explicit action)
  run git shiplog publish --env staging
  [ "$status" -eq 0 ]
  # Verify the remote journal ref exists
  run git --git-dir="$REMOTE_DIR" for-each-ref 'refs/_shiplog/journal/staging' --format='%(refname)'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "refs/_shiplog/journal/staging"
}

@test "auto-push honors SHIPLOG_REMOTE and bypasses pre-push hook" {
  export SHIPLOG_REMOTE=mirror
  export SHIPLOG_BORING=1
  export SHIPLOG_SERVICE=remote
  export SHIPLOG_STATUS=success
  export SHIPLOG_REASON=autopush
  export SHIPLOG_REGION=us-test
  export SHIPLOG_CLUSTER=cluster-1
  export SHIPLOG_NAMESPACE=ns-remote
  git shiplog init >/dev/null
  REMOTE_DIR=$(mktemp -d)
  git remote remove "$SHIPLOG_REMOTE" >/dev/null 2>&1 || true
  git init -q --bare "$REMOTE_DIR"
  git remote add "$SHIPLOG_REMOTE" "$REMOTE_DIR"
  cat > .git/hooks/pre-push <<'EOF'
#!/usr/bin/env bash
echo "hook" >> .git/prepush.log
exit 1
EOF
  chmod +x .git/hooks/pre-push
  run git shiplog write --env staging
  local write_output="$output"
  if [ "$status" -ne 0 ]; then
    echo "$write_output" >&2
    if [ -f .git/prepush.log ]; then
      echo "pre-push hook output:" >&2
      cat .git/prepush.log >&2
    fi
  fi
  [ "$status" -eq 0 ]
  [ ! -f .git/prepush.log ]
  run git --git-dir="$REMOTE_DIR" for-each-ref 'refs/_shiplog/journal/staging' --format='%(refname)'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "refs/_shiplog/journal/staging"
  git --git-dir="$REMOTE_DIR" update-ref -d refs/_shiplog/journal/staging >/dev/null 2>&1 || true
  git update-ref -d refs/_shiplog/journal/staging >/dev/null 2>&1 || true
  rm -f .git/hooks/pre-push .git/prepush.log
  rm -rf "$REMOTE_DIR"
}

@test "publish uses SHIPLOG_REMOTE and skips pre-push hook" {
  export SHIPLOG_REMOTE=mirror
  export SHIPLOG_AUTO_PUSH=0
  export SHIPLOG_BORING=1
  export SHIPLOG_SERVICE=remote
  export SHIPLOG_STATUS=success
  export SHIPLOG_REASON=publish
  export SHIPLOG_REGION=us-test
  export SHIPLOG_CLUSTER=cluster-2
  export SHIPLOG_NAMESPACE=ns-remote
  git shiplog init >/dev/null
  REMOTE_DIR=$(mktemp -d)
  git remote remove "$SHIPLOG_REMOTE" >/dev/null 2>&1 || true
  git init -q --bare "$REMOTE_DIR"
  git remote add "$SHIPLOG_REMOTE" "$REMOTE_DIR"
  cat > .git/hooks/pre-push <<'EOF'
#!/usr/bin/env bash
echo "hook" >> .git/prepush-publish.log
exit 1
EOF
  chmod +x .git/hooks/pre-push
  run git shiplog write --env staging
  local write_output="$output"
  if [ "$status" -ne 0 ]; then
    echo "$write_output" >&2
    if [ -f .git/prepush.log ]; then
      echo "pre-push hook output:" >&2
      cat .git/prepush.log >&2
    fi
  fi
  [ "$status" -eq 0 ]
  run git shiplog publish --env staging
  local publish_output="$output"
  if [ "$status" -ne 0 ]; then
    echo "$publish_output" >&2
    if [ -f .git/prepush-publish.log ]; then
      echo "pre-push hook output:" >&2
      cat .git/prepush-publish.log >&2
    fi
  fi
  [ "$status" -eq 0 ]
  [ ! -f .git/prepush-publish.log ]
  run git --git-dir="$REMOTE_DIR" for-each-ref 'refs/_shiplog/journal/staging' --format='%(refname)'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "refs/_shiplog/journal/staging"
  git --git-dir="$REMOTE_DIR" update-ref -d refs/_shiplog/journal/staging >/dev/null 2>&1 || true
  git update-ref -d refs/_shiplog/journal/staging >/dev/null 2>&1 || true
  rm -f .git/hooks/pre-push .git/prepush-publish.log
  rm -rf "$REMOTE_DIR"
}

# --- SLT.BUG.CLI.009: flags > git config shiplog.autoPush > SHIPLOG_AUTO_PUSH, with boolean parsing ----

make_bare_origin() {
  REMOTE_DIR=$(mktemp -d)
  git remote remove origin >/dev/null 2>&1 || true
  git init -q --bare "$REMOTE_DIR"
  git remote add origin "$REMOTE_DIR"
  export SHIPLOG_BORING=1
  export SHIPLOG_SERVICE=autopush
  export SHIPLOG_STATUS=success
  export SHIPLOG_REASON=precedence
  export SHIPLOG_REGION=us
  export SHIPLOG_CLUSTER=c
  export SHIPLOG_NAMESPACE=ns
}

remote_has_prod() {
  git --git-dir="$REMOTE_DIR" rev-parse --verify refs/_shiplog/journal/prod >/dev/null 2>&1
}

@test "auto-push: git config shiplog.autoPush=true beats SHIPLOG_AUTO_PUSH=0" {
  make_bare_origin
  git config shiplog.autoPush true
  run env SHIPLOG_AUTO_PUSH=0 git shiplog --boring --yes write
  [ "$status" -eq 0 ]
  remote_has_prod
  rm -rf "$REMOTE_DIR"
}

@test "auto-push: SHIPLOG_AUTO_PUSH=false disables pushing when no config is set" {
  make_bare_origin
  git config --unset-all shiplog.autoPush >/dev/null 2>&1 || true
  run env SHIPLOG_AUTO_PUSH=false git shiplog --boring --yes write
  [ "$status" -eq 0 ]
  ! remote_has_prod
  [[ "$output" == *"remember to publish"* ]]
  rm -rf "$REMOTE_DIR"
}

@test "auto-push: --no-push beats git config and prints the publish hint" {
  make_bare_origin
  git config shiplog.autoPush true
  run git shiplog --boring --yes --no-push write
  [ "$status" -eq 0 ]
  ! remote_has_prod
  [[ "$output" == *"remember to publish"* ]]
  rm -rf "$REMOTE_DIR"
}

@test "auto-push: --push beats git config shiplog.autoPush=false" {
  make_bare_origin
  git config shiplog.autoPush false
  run env SHIPLOG_AUTO_PUSH=0 git shiplog --boring --yes --push write
  [ "$status" -eq 0 ]
  remote_has_prod
  rm -rf "$REMOTE_DIR"
}

@test "auto-push: an unparseable git config shiplog.autoPush is an error, not a push" {
  make_bare_origin
  git config shiplog.autoPush sometimes
  run git shiplog --boring --yes write
  [ "$status" -ne 0 ]
  [[ "$output" == *"shiplog.autoPush"* ]]
  ! remote_has_prod
  rm -rf "$REMOTE_DIR"
}
