#!/usr/bin/env bats
# bats file_tags=refroot
#
# ROADMAP G6: one ref root for every Shiplog ref (client, hook, migrate).
#   #100 SHIPLOG_REF_ROOT / shiplog.refRoot relocate policy, trust and notes too
#   #115 the pre-receive hook enforces journals under the configured root
#   #123 show/publish/export-json use the same resolved notes ref as write
#
# The branch namespace refs/heads/_shiplog/** is the layout the hosting docs
# recommend for SaaS hosts; these tests exercise it end to end against a bare
# remote running contrib/hooks/pre-receive.shiplog.

load helpers/common

BRANCH_ROOT="refs/heads/_shiplog"
DEFAULT_ROOT="refs/_shiplog"
TESTER_EMAIL="shiplog-tester@example.com"
REMOTE_DIR=""
LOG_FILE=""

# The Docker runner exports SHIPLOG_REF_ROOT and SHIPLOG_NOTES_REF for the
# legacy tests; a ref-root test must start from a clean slate so that the
# CLI's own precedence (env > git config > default) is what gets exercised.
clear_ref_env() {
  unset SHIPLOG_REF_ROOT SHIPLOG_NOTES_REF SHIPLOG_POLICY_REF SHIPLOG_TRUST_REF
  unset SHIPLOG_REF_ROOT_SOURCE
  git config --unset-all shiplog.refRoot >/dev/null 2>&1 || true
}

# install_hook_with_env <bare_repo> [VAR=VALUE ...]
# Installs the real hook behind a wrapper that pins SHIPLOG_HOME to the checkout
# under test and exports the given variables (the hook environment on a server).
install_hook_with_env() {
  local remote="$1"
  shift
  local hook_source="${SHIPLOG_HOOK_PATH:-$SHIPLOG_PROJECT_ROOT/contrib/hooks/pre-receive.shiplog}"
  mkdir -p "$remote/hooks"
  cp "$hook_source" "$remote/hooks/pre-receive.real"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export GIT_CONFIG_GLOBAL=/dev/null\n'
    printf 'export SHIPLOG_HOME=%q\n' "$SHIPLOG_PROJECT_ROOT"
    # Policy fixtures here are unsigned; relax only the policy signature gate.
    printf 'export SHIPLOG_REQUIRE_SIGNED_POLICY=0\n'
    local kv
    for kv in "$@"; do
      printf 'export %q\n' "$kv"
    done
    printf 'exec bash "$0.real" "$@"\n'
  } >"$remote/hooks/pre-receive"
  chmod 0755 "$remote/hooks/pre-receive" "$remote/hooks/pre-receive.real"
}

# bootstrap_trust_at <trust_ref>
# Same roster as helpers/common shiplog_bootstrap_trust, at an arbitrary ref.
bootstrap_trust_at() {
  local trust_ref="$1"
  mkdir -p .shiplog
  cat > .shiplog/trust.json <<'JSON'
{
  "version": 1,
  "id": "shiplog-trust-root",
  "threshold": 1,
  "maintainers": [
    {
      "name": "Shiplog Tester",
      "email": "shiplog-tester@example.com",
      "pgp_fpr": "TESTFINGERPRINT",
      "role": "root",
      "revoked": false
    }
  ]
}
JSON
  cat > .shiplog/allowed_signers <<'EOF'
shiplog-tester@example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYSHIPLOGTESTER
EOF
  local oid_trust oid_sigs tree commit
  oid_trust=$(git hash-object -w .shiplog/trust.json)
  oid_sigs=$(git hash-object -w .shiplog/allowed_signers)
  tree=$(printf '100644 blob %s\ttrust.json\n100644 blob %s\tallowed_signers\n' "$oid_trust" "$oid_sigs" | git mktree)
  commit=$(echo "shiplog: trust root v1 (GENESIS)" |
    GIT_AUTHOR_NAME="Trust Init" GIT_AUTHOR_EMAIL="trust@local" \
    GIT_COMMITTER_NAME="Trust Init" GIT_COMMITTER_EMAIL="trust@local" \
    git commit-tree "$tree")
  git update-ref "$trust_ref" "$commit"
}

write_entry() {
  SHIPLOG_SERVICE="${SHIPLOG_SERVICE:-refroot-svc}" \
  SHIPLOG_STATUS="${SHIPLOG_STATUS:-success}" \
  SHIPLOG_REASON="${SHIPLOG_REASON:-ref root e2e}" \
  SHIPLOG_REGION="us-west-2" \
  SHIPLOG_CLUSTER="prod-1" \
  SHIPLOG_NAMESPACE="default" \
  git shiplog --boring --yes write "$@"
}

remote_refs() {
  git --git-dir="$REMOTE_DIR" for-each-ref --format='%(refname)' "$@"
}

setup() {
  shiplog_install_cli
  shiplog_use_sandbox_repo
  clear_ref_env
  export SHIPLOG_SIGN=0
  export SHIPLOG_AUTO_PUSH=0
  export SHIPLOG_ENV=prod
  export SHIPLOG_BORING=1
  export SHIPLOG_ASSUME_YES=1
  LOG_FILE=$(mktemp)
  printf '{"ts":"now","level":"info","msg":"hello-from-refroot"}\n' >"$LOG_FILE"
  REMOTE_DIR=$(mktemp -d)
  git init -q --bare "$REMOTE_DIR"
  git remote add origin "$REMOTE_DIR"
}

teardown() {
  if [ -n "$REMOTE_DIR" ]; then
    rm -rf "$REMOTE_DIR"
  fi
  rm -f "$LOG_FILE"
  shiplog_cleanup_sandbox_repo
  unset SHIPLOG_SIGN SHIPLOG_AUTO_PUSH SHIPLOG_ENV SHIPLOG_BORING SHIPLOG_ASSUME_YES SHIPLOG_LOG
  unset SHIPLOG_REF_ROOT SHIPLOG_NOTES_REF SHIPLOG_AUTHORS SHIPLOG_EXTRA_JSON
}

# ---------------------------------------------------------------------------
# #100 + #115 + #123: branch namespace end to end, root from the environment
# ---------------------------------------------------------------------------

@test "SHIPLOG_REF_ROOT relocates every ref and the hook enforces them (setup, write, publish)" {
  export SHIPLOG_REF_ROOT="$BRANCH_ROOT"
  install_hook_with_env "$REMOTE_DIR" "SHIPLOG_REF_ROOT=$BRANCH_ROOT"
  bootstrap_trust_at "$BRANCH_ROOT/trust/root"

  run git shiplog init
  [ "$status" -eq 0 ]
  run git config --get-all remote.origin.fetch
  [[ "$output" == *"+$BRANCH_ROOT/*:$BRANCH_ROOT/*"* ]]

  run git shiplog setup --strictness balanced --authors "$TESTER_EMAIL"
  echo "setup: $output" >&2
  [ "$status" -eq 0 ]
  run git rev-parse -q --verify "$BRANCH_ROOT/policy/current"
  [ "$status" -eq 0 ]

  export SHIPLOG_LOG="$LOG_FILE"
  run write_entry
  unset SHIPLOG_LOG
  echo "write: $output" >&2
  [ "$status" -eq 0 ]
  run git rev-parse -q --verify "$BRANCH_ROOT/journal/prod"
  [ "$status" -eq 0 ]
  run git rev-parse -q --verify "$BRANCH_ROOT/notes/logs"
  [ "$status" -eq 0 ]

  # Nothing leaked into the default namespace on the client.
  run git for-each-ref --format='%(refname)' "$DEFAULT_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # trust_oid recorded in the entry is the trust tip under the branch root.
  run git shiplog show --json
  [ "$status" -eq 0 ]
  recorded_trust=$(printf '%s\n' "$output" | jq -r '.trust_oid')
  [ "$recorded_trust" = "$(git rev-parse "$BRANCH_ROOT/trust/root")" ]

  # show reads the attached log from the derived notes ref (#123).
  run git shiplog --boring show
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-from-refroot"* ]]

  run git shiplog publish --all --policy --trust
  echo "publish: $output" >&2
  [ "$status" -eq 0 ]

  run remote_refs "$BRANCH_ROOT"
  echo "remote refs: $output" >&2
  [ "$status" -eq 0 ]
  [[ "$output" == *"$BRANCH_ROOT/journal/prod"* ]]
  [[ "$output" == *"$BRANCH_ROOT/policy/current"* ]]
  [[ "$output" == *"$BRANCH_ROOT/trust/root"* ]]
  [[ "$output" == *"$BRANCH_ROOT/notes/logs"* ]]
  run remote_refs "$DEFAULT_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run git shiplog refs root show
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ref Root: $BRANCH_ROOT"* ]]
  [[ "$output" == *"Source: env"* ]]
}

@test "hook rejects a disallowed author under the branch root and accepts an allowed one" {
  export SHIPLOG_REF_ROOT="$BRANCH_ROOT"
  install_hook_with_env "$REMOTE_DIR" "SHIPLOG_REF_ROOT=$BRANCH_ROOT"
  bootstrap_trust_at "$BRANCH_ROOT/trust/root"
  run git shiplog setup --strictness balanced --authors "$TESTER_EMAIL"
  [ "$status" -eq 0 ]

  run write_entry
  [ "$status" -eq 0 ]
  run git shiplog publish --all --policy --trust
  echo "publish: $output" >&2
  [ "$status" -eq 0 ]
  accepted_tip=$(git rev-parse "$BRANCH_ROOT/journal/prod")

  # Mallory bypasses the client allowlist (SHIPLOG_AUTHORS) and pushes directly.
  export GIT_AUTHOR_NAME="Mallory" GIT_AUTHOR_EMAIL="mallory@example.com"
  export GIT_COMMITTER_NAME="Mallory" GIT_COMMITTER_EMAIL="mallory@example.com"
  export SHIPLOG_AUTHORS="mallory@example.com"
  run write_entry
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL SHIPLOG_AUTHORS
  echo "mallory write: $output" >&2
  [ "$status" -eq 0 ]
  [ "$(git show -s --format='%ae' "$BRANCH_ROOT/journal/prod")" = "mallory@example.com" ]
  run git push origin "$BRANCH_ROOT/journal/prod"
  echo "mallory push: $output" >&2
  [ "$status" -ne 0 ]
  [[ "$output" == *"not allowed"* ]]
  [ "$(git --git-dir="$REMOTE_DIR" rev-parse "$BRANCH_ROOT/journal/prod")" = "$accepted_tip" ]

  # Drop Mallory's entry locally; an allowed author's entry goes through.
  git update-ref "$BRANCH_ROOT/journal/prod" "$accepted_tip"
  run write_entry
  [ "$status" -eq 0 ]
  run git push origin "$BRANCH_ROOT/journal/prod"
  echo "allowed push: $output" >&2
  [ "$status" -eq 0 ]
  [ "$(git --git-dir="$REMOTE_DIR" rev-parse "$BRANCH_ROOT/journal/prod")" = "$(git rev-parse "$BRANCH_ROOT/journal/prod")" ]
}

@test "hook refuses to start when trust/policy refs are outside the root unless mixed layout is allowed" {
  export SHIPLOG_REF_ROOT="$BRANCH_ROOT"
  bootstrap_trust_at "$BRANCH_ROOT/trust/root"

  install_hook_with_env "$REMOTE_DIR" "SHIPLOG_REF_ROOT=$BRANCH_ROOT" "SHIPLOG_TRUST_REF=$DEFAULT_ROOT/trust/root"
  run git push origin "$BRANCH_ROOT/trust/root"
  echo "mixed push: $output" >&2
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside the ref root"* ]]

  install_hook_with_env "$REMOTE_DIR" "SHIPLOG_REF_ROOT=$BRANCH_ROOT" "SHIPLOG_TRUST_REF=$DEFAULT_ROOT/trust/root" "SHIPLOG_ALLOW_MIXED_REF_ROOT=1"
  # With the mixed layout allowed the hook starts; the branch-root trust ref is
  # then just an unmanaged ref and the push succeeds.
  run git push origin "$BRANCH_ROOT/trust/root"
  echo "allowed mixed push: $output" >&2
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# #100: root from git config shiplog.refRoot (env unset)
# ---------------------------------------------------------------------------

@test "git config shiplog.refRoot produces the same layout and refs root show reports config" {
  git config shiplog.refRoot "$BRANCH_ROOT"
  bootstrap_trust_at "$BRANCH_ROOT/trust/root"

  run git shiplog setup --strictness open
  echo "setup: $output" >&2
  [ "$status" -eq 0 ]
  run git rev-parse -q --verify "$BRANCH_ROOT/policy/current"
  [ "$status" -eq 0 ]

  export SHIPLOG_LOG="$LOG_FILE"
  run write_entry
  unset SHIPLOG_LOG
  echo "write: $output" >&2
  [ "$status" -eq 0 ]
  run git rev-parse -q --verify "$BRANCH_ROOT/journal/prod"
  [ "$status" -eq 0 ]
  run git rev-parse -q --verify "$BRANCH_ROOT/notes/logs"
  [ "$status" -eq 0 ]
  run git for-each-ref --format='%(refname)' "$DEFAULT_ROOT"
  [ -z "$output" ]

  run git shiplog show --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.trust_oid')" = "$(git rev-parse "$BRANCH_ROOT/trust/root")" ]

  run git shiplog refs root show
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ref Root: $BRANCH_ROOT"* ]]
  [[ "$output" == *"Source: config"* ]]
  [[ "$output" == *"Policy Ref: $BRANCH_ROOT/policy/current"* ]]
  [[ "$output" == *"Trust Ref: $BRANCH_ROOT/trust/root"* ]]
  [[ "$output" == *"Notes Ref: $BRANCH_ROOT/notes/logs"* ]]

  run git shiplog refs root show --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.source')" = "config" ]
  [ "$(printf '%s\n' "$output" | jq -r '.ref_root')" = "$BRANCH_ROOT" ]
}

@test "refs root show reports the source and env beats config beats default" {
  run git shiplog refs root show
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ref Root: $DEFAULT_ROOT"* ]]
  [[ "$output" == *"Source: default"* ]]

  run git shiplog refs root set "$BRANCH_ROOT/"
  [ "$status" -eq 0 ]
  [ "$(git config --get shiplog.refRoot)" = "$BRANCH_ROOT" ]
  run git shiplog refs root show
  [[ "$output" == *"Ref Root: $BRANCH_ROOT"* ]]
  [[ "$output" == *"Source: config"* ]]

  run env SHIPLOG_REF_ROOT="refs/other/_shiplog" git shiplog refs root show
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ref Root: refs/other/_shiplog"* ]]
  [[ "$output" == *"Source: env"* ]]

  run env SHIPLOG_REF_ROOT="heads/_shiplog" git shiplog refs root show
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid ref root"* ]]

  run git shiplog refs root set "not-a-ref"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# #123: the policy notes_ref is honored by show, export-json and publish
# ---------------------------------------------------------------------------

@test "policy notes_ref is used by write, show, export-json and publish" {
  # Default root. SHIPLOG_NOTES_REF outranks the policy (lib/policy.sh precedence
  # table), so drop the Docker runner's value to let the policy notes_ref apply.
  unset SHIPLOG_NOTES_REF
  shiplog_bootstrap_trust
  mkdir -p .shiplog
  cat > .shiplog/policy.json <<'JSON'
{
  "version": "1.0.0",
  "require_signed": false,
  "notes_ref": "refs/_shiplog/notes/deploy",
  "authors": { "default_allowlist": ["shiplog-tester@example.com"] }
}
JSON

  export SHIPLOG_LOG="$LOG_FILE"
  run write_entry
  unset SHIPLOG_LOG
  echo "write: $output" >&2
  [ "$status" -eq 0 ]
  sha=$(git rev-parse "$DEFAULT_ROOT/journal/prod")
  run git notes --ref="$DEFAULT_ROOT/notes/deploy" show "$sha"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-from-refroot"* ]]
  run git rev-parse -q --verify "$DEFAULT_ROOT/notes/logs"
  [ "$status" -ne 0 ]

  run git shiplog --boring show
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-from-refroot"* ]]

  run git shiplog export-json
  [ "$status" -eq 0 ]
  first=$(printf '%s\n' "$output" | head -n1)
  [ "$(printf '%s\n' "$first" | jq -r '.notes.ref')" = "$DEFAULT_ROOT/notes/deploy" ]
  [ "$(printf '%s\n' "$first" | jq -r '.notes.attached')" = "true" ]

  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.notes_ref')" = "$DEFAULT_ROOT/notes/deploy" ]

  run git shiplog publish
  echo "publish: $output" >&2
  [ "$status" -eq 0 ]
  run remote_refs "$DEFAULT_ROOT"
  [[ "$output" == *"$DEFAULT_ROOT/journal/prod"* ]]
  [[ "$output" == *"$DEFAULT_ROOT/notes/deploy"* ]]
  [[ "$output" != *"$DEFAULT_ROOT/notes/logs"* ]]

  # SHIPLOG_NOTES_REF wins over the policy notes_ref, for policy show and the
  # commands alike, so both report the same ref.
  export SHIPLOG_NOTES_REF="$DEFAULT_ROOT/notes/override"
  run git shiplog policy show --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.notes_ref')" = "$DEFAULT_ROOT/notes/override" ]
  [ "$(printf '%s\n' "$output" | jq -r '.sources.notes_ref')" = "env:SHIPLOG_NOTES_REF" ]
  run git shiplog export-json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -n1 | jq -r '.notes.ref')" = "$DEFAULT_ROOT/notes/override" ]
  unset SHIPLOG_NOTES_REF
}

@test "publish fails loudly when entries claim log_attached but the notes ref is missing locally" {
  shiplog_bootstrap_trust
  shiplog_write_local_policy
  export SHIPLOG_LOG="$LOG_FILE"
  # `run` is a reserved trailer key (#121): simulate a `git shiplog run` entry
  # through the internal channel cmd_run uses, not SHIPLOG_EXTRA_JSON.
  export SHIPLOG_RUN_JSON='{"log_attached":true}'
  run write_entry
  unset SHIPLOG_LOG SHIPLOG_RUN_JSON
  echo "write: $output" >&2
  [ "$status" -eq 0 ]
  run git rev-parse -q --verify "$DEFAULT_ROOT/notes/logs"
  [ "$status" -eq 0 ]
  run git shiplog show --json
  [ "$(printf '%s\n' "$output" | jq -r '.run.log_attached')" = "true" ]

  # Point the resolved notes ref somewhere else: the attached logs would never
  # be published, so publish must refuse instead of pushing silently.
  export SHIPLOG_NOTES_REF="$DEFAULT_ROOT/notes/elsewhere"
  run git shiplog publish
  echo "publish: $output" >&2
  [ "$status" -ne 0 ]
  [[ "$output" == *"log_attached=true"* ]]
  [[ "$output" == *"$DEFAULT_ROOT/notes/elsewhere"* ]]

  unset SHIPLOG_NOTES_REF
  run git shiplog publish
  echo "publish (fixed): $output" >&2
  [ "$status" -eq 0 ]
  run remote_refs "$DEFAULT_ROOT"
  [[ "$output" == *"$DEFAULT_ROOT/notes/logs"* ]]
}

# ---------------------------------------------------------------------------
# migrate: every ref kind moves; --dry-run moves nothing
# ---------------------------------------------------------------------------

@test "refs migrate moves journal, anchors, policy, trust and notes; --dry-run changes nothing" {
  shiplog_bootstrap_trust
  shiplog_bootstrap_policy_ref
  export SHIPLOG_LOG="$LOG_FILE"
  run write_entry
  unset SHIPLOG_LOG
  echo "write: $output" >&2
  [ "$status" -eq 0 ]
  git update-ref "$DEFAULT_ROOT/anchors/prod" "$(git rev-parse "$DEFAULT_ROOT/journal/prod")"

  local kinds=(journal/prod anchors/prod policy/current trust/root notes/logs)
  declare -A before=()
  local kind
  for kind in "${kinds[@]}"; do
    before[$kind]=$(git rev-parse "$DEFAULT_ROOT/$kind")
    [ -n "${before[$kind]}" ]
  done

  # Global --dry-run must reach the helper (previously swallowed by the parser).
  run git shiplog refs migrate --to "$BRANCH_ROOT" --dry-run
  echo "dry-run: $output" >&2
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry-run: no changes made."* ]]
  for kind in "${kinds[@]}"; do
    [[ "$output" == *"$DEFAULT_ROOT/$kind -> $BRANCH_ROOT/$kind"* ]]
  done
  run git for-each-ref --format='%(refname)' "$BRANCH_ROOT"
  [ -z "$output" ]
  run git config --get shiplog.refRoot
  [ "$status" -ne 0 ]

  run git shiplog refs migrate --to "$BRANCH_ROOT"
  echo "migrate: $output" >&2
  [ "$status" -eq 0 ]
  for kind in "${kinds[@]}"; do
    run git rev-parse -q --verify "$BRANCH_ROOT/$kind"
    [ "$status" -eq 0 ]
    [ "$output" = "${before[$kind]}" ]
  done
  [ "$(git config --get shiplog.refRoot)" = "$BRANCH_ROOT" ]

  # With the env override gone the CLI follows the new root.
  run git shiplog refs root show
  [[ "$output" == *"Ref Root: $BRANCH_ROOT"* ]]
  [[ "$output" == *"Source: config"* ]]
  run git shiplog ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"refroot-svc"* ]]
  run git shiplog --boring show
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-from-refroot"* ]]
}

# ---------------------------------------------------------------------------
# Notes are shared: a second writer must build on the published notes ref
# ---------------------------------------------------------------------------

@test "a second clone attaching a log fast-forwards the notes ref before pushing it" {
  shiplog_bootstrap_trust
  shiplog_write_local_policy
  git push -q origin "$DEFAULT_ROOT/trust/root" HEAD:refs/heads/main

  local other
  other=$(mktemp -d)
  git clone -q "$REMOTE_DIR" "$other/b" 2>/dev/null
  git -C "$other/b" config user.name "Shiplog Tester"
  git -C "$other/b" config user.email "$TESTER_EMAIL"
  git -C "$other/b" fetch -q origin "+$DEFAULT_ROOT/*:$DEFAULT_ROOT/*"
  cp -R .shiplog "$other/b/.shiplog"

  # Writer A publishes an entry with a log while B's notes ref is still absent.
  export SHIPLOG_AUTO_PUSH=1 SHIPLOG_LOG="$LOG_FILE"
  run write_entry
  echo "writer A: $output" >&2
  [ "$status" -eq 0 ]
  a_notes=$(git --git-dir="$REMOTE_DIR" rev-parse "$DEFAULT_ROOT/notes/logs")

  # Writer B attaches a log too; its notes commit must build on A's.
  pushd "$other/b" >/dev/null
  run write_entry
  b_status=$status
  b_output=$output
  popd >/dev/null
  unset SHIPLOG_LOG
  export SHIPLOG_AUTO_PUSH=0
  rm -rf "$other"
  echo "writer B: $b_output" >&2
  [ "$b_status" -eq 0 ]
  b_notes=$(git --git-dir="$REMOTE_DIR" rev-parse "$DEFAULT_ROOT/notes/logs")
  [ "$b_notes" != "$a_notes" ]
  git --git-dir="$REMOTE_DIR" merge-base --is-ancestor "$a_notes" "$b_notes"
  # Both entries keep their log on the published notes ref.
  [ "$(git --git-dir="$REMOTE_DIR" ls-tree -r --name-only "$b_notes" | wc -l | tr -d ' ')" -eq 2 ]
}

# ---------------------------------------------------------------------------
# #115: the hook protects the notes ref under the root like journals
# ---------------------------------------------------------------------------

@test "hook refuses deletion and non-fast-forward of the notes ref under the root; a fast-forward passes" {
  export SHIPLOG_REF_ROOT="$BRANCH_ROOT"
  install_hook_with_env "$REMOTE_DIR" "SHIPLOG_REF_ROOT=$BRANCH_ROOT"
  bootstrap_trust_at "$BRANCH_ROOT/trust/root"
  run git shiplog setup --strictness balanced --authors "$TESTER_EMAIL"
  [ "$status" -eq 0 ]
  export SHIPLOG_LOG="$LOG_FILE"
  run write_entry
  unset SHIPLOG_LOG
  [ "$status" -eq 0 ]
  run git shiplog publish --all --policy --trust
  echo "publish: $output" >&2
  [ "$status" -eq 0 ]
  published=$(git --git-dir="$REMOTE_DIR" rev-parse "$BRANCH_ROOT/notes/logs")

  run git push origin ":$BRANCH_ROOT/notes/logs"
  echo "delete: $output" >&2
  [ "$status" -ne 0 ]
  [[ "$output" == *"not permitted"* ]]
  [ "$(git --git-dir="$REMOTE_DIR" rev-parse "$BRANCH_ROOT/notes/logs")" = "$published" ]

  rewrite=$(git commit-tree "$(git mktree </dev/null)" -m "rewritten notes")
  run git push --force origin "$rewrite:$BRANCH_ROOT/notes/logs"
  echo "rewrite: $output" >&2
  [ "$status" -ne 0 ]
  [ "$(git --git-dir="$REMOTE_DIR" rev-parse "$BRANCH_ROOT/notes/logs")" = "$published" ]

  # Positive control: appending a note is a fast-forward and is accepted.
  git notes --ref="$BRANCH_ROOT/notes/logs" add -m "second note" HEAD
  run git push origin "$BRANCH_ROOT/notes/logs"
  echo "append: $output" >&2
  [ "$status" -eq 0 ]
  [ "$(git --git-dir="$REMOTE_DIR" rev-parse "$BRANCH_ROOT/notes/logs")" = "$(git rev-parse "$BRANCH_ROOT/notes/logs")" ]
}

# ---------------------------------------------------------------------------
# #100: trust-sign binds the prior trust tip under the configured root
# ---------------------------------------------------------------------------

@test "trust-sign run on its own binds the trust tip under SHIPLOG_REF_ROOT or shiplog.refRoot" {
  bootstrap_trust_at "$BRANCH_ROOT/trust/root"
  genesis=$(git rev-parse "$BRANCH_ROOT/trust/root")
  update=$(git commit-tree "$(git rev-parse "$genesis^{tree}")" -p "$genesis" -m "shiplog: trust update")
  local sign="$SHIPLOG_PROJECT_ROOT/scripts/shiplog-trust-sign.sh"

  # Control: the default root has no trust ref, so the payload binds genesis (zero OID).
  run "$sign" --message-only "$update"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "0000000000000000000000000000000000000000" ]

  run env SHIPLOG_REF_ROOT="$BRANCH_ROOT" "$sign" --message-only "$update"
  echo "env payload: $output" >&2
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "$genesis" ]

  git config shiplog.refRoot "$BRANCH_ROOT"
  run "$sign" --message-only "$update"
  echo "config payload: $output" >&2
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "$genesis" ]
  # With no COMMIT argument the trust commit also comes from the configured root.
  run "$sign" --message-only
  [ "$status" -eq 0 ]
}

@test "refs migrate --remove-old drops the local refs/notes alias of the removed notes ref" {
  shiplog_bootstrap_trust
  shiplog_write_local_policy
  export SHIPLOG_LOG="$LOG_FILE"
  run write_entry
  unset SHIPLOG_LOG
  [ "$status" -eq 0 ]
  # Control: writing a note created the alias for the default-root notes ref.
  [ "$(git symbolic-ref -q "refs/notes/$DEFAULT_ROOT/notes/logs")" = "$DEFAULT_ROOT/notes/logs" ]

  run git shiplog refs migrate --to "$BRANCH_ROOT" --remove-old
  echo "migrate: $output" >&2
  [ "$status" -eq 0 ]
  run git rev-parse -q --verify "$DEFAULT_ROOT/notes/logs"
  [ "$status" -ne 0 ]
  run git symbolic-ref -q "refs/notes/$DEFAULT_ROOT/notes/logs"
  [ "$status" -ne 0 ]
  run git for-each-ref refs/notes
  [ "$status" -eq 0 ]
  [[ "$output" != *"broken ref"* ]]
  run git shiplog --boring show
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-from-refroot"* ]]
}

@test "hook on one root refuses creates and updates under the other well-known root; deletions and the mixed opt-out still work" {
  forged=$(git commit-tree "$(git mktree </dev/null)" -m "forged entry outside the server's root")

  # Server on the branch root: nothing may be written under refs/_shiplog/**.
  install_hook_with_env "$REMOTE_DIR" "SHIPLOG_REF_ROOT=$BRANCH_ROOT"
  git update-ref "$DEFAULT_ROOT/journal/prod" "$forged"
  run git push origin "$DEFAULT_ROOT/journal/prod"
  echo "legacy create: $output" >&2
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside this server's ref root"* ]]
  [ -z "$(git --git-dir="$REMOTE_DIR" rev-parse -q --verify "$DEFAULT_ROOT/journal/prod" || true)" ]

  # Control: an ordinary branch is not a Shiplog ref and is accepted.
  git update-ref refs/heads/feature "$forged"
  run git push origin refs/heads/feature
  [ "$status" -eq 0 ]

  # Deleting a leftover under the other root is allowed (refs migrate --remove-old).
  git --git-dir="$REMOTE_DIR" update-ref "$DEFAULT_ROOT/journal/old" "$forged"
  run git push origin ":$DEFAULT_ROOT/journal/old"
  echo "legacy delete: $output" >&2
  [ "$status" -eq 0 ]
  [ -z "$(git --git-dir="$REMOTE_DIR" rev-parse -q --verify "$DEFAULT_ROOT/journal/old" || true)" ]

  # Opt-out for staged migrations.
  install_hook_with_env "$REMOTE_DIR" "SHIPLOG_REF_ROOT=$BRANCH_ROOT" "SHIPLOG_ALLOW_MIXED_REF_ROOT=1"
  run git push origin "$DEFAULT_ROOT/journal/prod"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WITHOUT validation"* ]]

  # The reverse: a server on the default root refuses writes under refs/heads/_shiplog/**.
  install_hook_with_env "$REMOTE_DIR"
  git update-ref "$BRANCH_ROOT/journal/prod" "$forged"
  run git push origin "$BRANCH_ROOT/journal/prod"
  echo "branch-root create on default server: $output" >&2
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside this server's ref root"* ]]
}
