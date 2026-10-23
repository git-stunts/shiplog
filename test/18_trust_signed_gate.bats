#!/usr/bin/env bats

load helpers/common

setup() {
  shiplog_standard_setup
  # Prepare a bare remote for exercising the pre-receive hook
  REMOTE_DIR=$(mktemp -d)
  pushd "$REMOTE_DIR" >/dev/null
  git init -q --bare
  popd >/dev/null
  git remote add origin "$REMOTE_DIR"
}

teardown() {
  rm -rf "$REMOTE_DIR" 2>/dev/null || true
  shiplog_standard_teardown
}

install_hook_with_gate() {
  mkdir -p "$REMOTE_DIR/hooks"
  # Wrap to ensure bash execution under sh-only environments
  cp "$SHIPLOG_HOME/contrib/hooks/pre-receive.shiplog" "$REMOTE_DIR/hooks/pre-receive.real"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'export SHIPLOG_REQUIRE_SIGNED_TRUST=1' \
    'export SHIPLOG_REQUIRE_SIGNED_TRUST_MODE=either' \
    'export SHIPLOG_DEBUG_SSH_VERIFY=1' \
    'exec /usr/bin/env bash "$0.real" "$@"' > "$REMOTE_DIR/hooks/pre-receive"
  chmod +x "$REMOTE_DIR/hooks/pre-receive" "$REMOTE_DIR/hooks/pre-receive.real"
}

@test "unsigned trust push rejected when SHIPLOG_REQUIRE_SIGNED_TRUST=1" {
  install_hook_with_gate

  # Bootstrap an unsigned trust commit (helpers create a default one)
  shiplog_bootstrap_trust 1

  run git push -q origin refs/_shiplog/trust/root
  [ "$status" -ne 0 ]
  [[ "$output" == *"pre-receive hook declined"* ]]
}

@test "signed trust push passes when SHIPLOG_REQUIRE_SIGNED_TRUST=1" {
  install_hook_with_gate

  # Set up SSH signing and sign a new trust commit (commit signature, not tag)
  shiplog_setup_test_signing
  git config user.email "shiplog-tester@example.com"
  mkdir -p .shiplog
  cat > .shiplog/trust.json <<'JSON'
{
  "version": 1,
  "id": "shiplog-trust-root",
  "threshold": 1,
  "maintainers": [ {"name":"Shiplog Tester","email":"shiplog-tester@example.com","role":"root","revoked":false} ]
}
JSON
  # Build robust allowed_signers from the configured SSH signing key
  shiplog_write_allowed_signers_for_signing_key .shiplog/allowed_signers
  oid_trust=$(git hash-object -w .shiplog/trust.json)
  oid_sigs=$(git hash-object -w .shiplog/allowed_signers)
  tab=$'\t'
  # Produce an attestation signature as a fallback under 'either' mode
  priv="$(git config user.signingkey)"
  base=$(printf "100644 blob %s${tab}trust.json\n100644 blob %s${tab}allowed_signers\n" "$oid_trust" "$oid_sigs" | git mktree)
  printf 'shiplog-trust-tree-v2\n%s\n%s\n%s\n%s\n' "$base" "shiplog-trust-root" "1" "0000000000000000000000000000000000000000" > payload.txt
  ssh-keygen -Y sign -q -f "$priv" -n shiplog-trust payload.txt >/dev/null
  mkdir -p .shiplog/trust_sigs
  mv payload.txt.sig .shiplog/trust_sigs/shiplog-tester@example.com.sig
  oid_asig=$(git hash-object -w .shiplog/trust_sigs/shiplog-tester@example.com.sig)
  ts_tree=$(printf "100644 blob %s${tab}shiplog-tester@example.com.sig\n" "$oid_asig" | git mktree)
  dotshiplog_tree=$(printf "040000 tree %s${tab}trust_sigs\n" "$ts_tree" | git mktree)
  root_tree=$(printf "100644 blob %s${tab}trust.json\n100644 blob %s${tab}allowed_signers\n040000 tree %s${tab}.shiplog\n" "$oid_trust" "$oid_sigs" "$dotshiplog_tree" | git mktree)
  commit=$(GIT_AUTHOR_NAME="Shiplog Tester" GIT_AUTHOR_EMAIL="shiplog-tester@example.com" \
    GIT_COMMITTER_NAME="Shiplog Tester" GIT_COMMITTER_EMAIL="shiplog-tester@example.com" \
    git commit-tree -S "$root_tree" -m "shiplog: trust root (signed)" )
  git update-ref refs/_shiplog/trust/root "$commit"

  run git push -q origin refs/_shiplog/trust/root
  if [ "$status" -ne 0 ]; then
    echo "--- git push output ---"
    echo "$output"
    echo "------------------------"
  fi
  [ "$status" -eq 0 ]
}
