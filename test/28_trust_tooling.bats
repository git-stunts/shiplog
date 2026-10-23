#!/usr/bin/env bats
#
# Trust tooling built on lib/trust-verify.sh (ROADMAP G3): the attestation sign
# helper, the bootstrap script, trust-sync, verifier hygiene and the hook's
# validator diagnostics. The adversarial scenarios live in
# test/27_trust_adversarial.bats; this file covers the supporting tools
# (#112, #116, #137, #138, #153, #154, #109 lint).

load helpers/common
load helpers/trust_adversarial

TESTER_EMAIL="shiplog-tester@example.com"
REMOTE_NAME="shiplog-tooling"

setup() {
  shiplog_install_cli
  shiplog_use_sandbox_repo
  export SHIPLOG_HOME="$SHIPLOG_PROJECT_ROOT"
  case ":$PATH:" in
    *":$SHIPLOG_PROJECT_ROOT/bin:"*) ;;
    *) export PATH="$SHIPLOG_PROJECT_ROOT/bin:$PATH" ;;
  esac
  git config user.name "Shiplog Tester"
  git config user.email "$TESTER_EMAIL"
  export SHIPLOG_SIGN=0
  export SHIPLOG_AUTO_PUSH=0
  adv_keys_init
  adv_keygen K "$TESTER_EMAIL"
  REMOTE_DIR=""
}

teardown() {
  git remote remove "$REMOTE_NAME" >/dev/null 2>&1 || true
  if [ -n "${REMOTE_DIR:-}" ]; then
    rm -rf "$REMOTE_DIR"
  fi
  adv_keys_cleanup
  shiplog_cleanup_sandbox_repo
}

# A threshold-1 attestation-mode trust document for the tester (key K).
build_trust_k_docs() {
  TRUST_K=$(adv_trust_json 1 attestation "$TESTER_EMAIL")
  SIGNERS_K="$(adv_signers_line "$TESTER_EMAIL" K)"
}

# ---------------------------------------------------------------------------
# #112 one payload builder
# ---------------------------------------------------------------------------

@test "trust-sign: --message-only prints exactly the payload the verifier checks" {
  build_trust_k_docs
  commit=$(adv_trust_commit -S K -e "$TESTER_EMAIL" -m "shiplog: trust base" "$TRUST_K" "$SIGNERS_K")
  base=$(adv_base_tree "$(git rev-parse "$commit:trust.json")" "$(git rev-parse "$commit:allowed_signers")")
  expected=$(adv_attest_payload "$base" "shiplog-trust-root" 1 | sha256sum | awk '{print $1}')
  actual=$("$SHIPLOG_PROJECT_ROOT/scripts/shiplog-trust-sign.sh" --message-only "$commit" | sha256sum | awk '{print $1}')
  [ "$actual" = "$expected" ]
}

@test "trust-sign: a rotation attestation binds the local trust tip as prior and verifies" {
  build_trust_k_docs
  adv_use_signing_key K
  genesis=$(adv_trust_commit -S K -e "$TESTER_EMAIL" --sig "$TESTER_EMAIL=K" -m "shiplog: trust root" "$TRUST_K" "$SIGNERS_K")
  git update-ref "$ADV_TRUST_REF" "$genesis"

  # Rotation draft: same roster, new id. The helper's default prior is the local tip.
  trust_next=$(jq -c '.id = "shiplog-trust-root-2"' <<<"$TRUST_K")
  draft=$(adv_trust_commit -S K -e "$TESTER_EMAIL" -m "shiplog: rotation draft" "$trust_next" "$SIGNERS_K")
  [ "$("$SHIPLOG_PROJECT_ROOT/scripts/shiplog-trust-sign.sh" --message-only "$draft" | tail -n1)" = "$genesis" ]
  sigdir=$(mktemp -d)
  run env SHIPLOG_TRUST_SIG_DIR="$sigdir" "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-trust-sign.sh" --principal "$TESTER_EMAIL" "$draft"
  [ "$status" -eq 0 ]
  sig_oid=$(git hash-object -w "$sigdir/$TESTER_EMAIL.sig")
  rm -rf "$sigdir"
  rotation=$(adv_trust_commit -p "$genesis" -S K -e "$TESTER_EMAIL" --sig-blob "$TESTER_EMAIL=$sig_oid" \
    -m "shiplog: rotation" "$trust_next" "$SIGNERS_K")

  run env SHIPLOG_REQUIRE_SIGNED_TRUST=1 "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" \
    --old "$genesis" --new "$rotation" --ref "$ADV_TRUST_REF"
  [ "$status" -eq 0 ]

  # The same attestation does not approve the document as a genesis (prior = zero OID).
  run env SHIPLOG_REQUIRE_SIGNED_TRUST=1 "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" \
    --old "$ADV_ZERO_OID" --new "$(adv_trust_commit -S K -e "$TESTER_EMAIL" --sig-blob "$TESTER_EMAIL=$sig_oid" -m "shiplog: replayed as genesis" "$trust_next" "$SIGNERS_K")" --ref "$ADV_TRUST_REF"
  [ "$status" -ne 0 ]
}

@test "trust-sign: a signature produced by the helper verifies through the shared verifier" {
  build_trust_k_docs
  adv_use_signing_key K
  base_commit=$(adv_trust_commit -S K -e "$TESTER_EMAIL" -m "shiplog: trust base" "$TRUST_K" "$SIGNERS_K")
  sigdir=$(mktemp -d)
  run env SHIPLOG_TRUST_SIG_DIR="$sigdir" "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-trust-sign.sh" --principal "$TESTER_EMAIL" "$base_commit"
  [ "$status" -eq 0 ]
  [ -s "$sigdir/$TESTER_EMAIL.sig" ]
  sig_oid=$(git hash-object -w "$sigdir/$TESTER_EMAIL.sig")
  rm -rf "$sigdir"
  commit=$(adv_trust_commit -S K -e "$TESTER_EMAIL" --sig-blob "$TESTER_EMAIL=$sig_oid" -m "shiplog: trust root (attested)" "$TRUST_K" "$SIGNERS_K")

  run env SHIPLOG_REQUIRE_SIGNED_TRUST=1 "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" \
    --old "$ADV_ZERO_OID" --new "$commit" --ref "$ADV_TRUST_REF"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# #154 hygiene: temp files and the ssh-keygen escape hatch
# ---------------------------------------------------------------------------

@test "verify-trust: leaves TMPDIR empty" {
  build_trust_k_docs
  commit=$(adv_trust_commit -S K --sig "$TESTER_EMAIL=K" -e "$TESTER_EMAIL" -m "shiplog: trust root" "$TRUST_K" "$SIGNERS_K")
  scratch=$(mktemp -d)
  run env TMPDIR="$scratch" "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" \
    --old "$ADV_ZERO_OID" --new "$commit" --ref "$ADV_TRUST_REF"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$scratch")" ]
  rm -rf "$scratch"
}

# Restricted PATH without ssh-keygen (git itself still needs its helpers on PATH).
make_path_without_ssh_keygen() {
  local dir bin src
  dir=$(mktemp -d)
  for bin in git jq bash sh sed awk grep tr cut head tail mktemp rm chmod cat paste sha256sum env printf dirname basename ls cp mv ln; do
    if src=$(command -v "$bin" 2>/dev/null); then
      ln -s "$src" "$dir/$bin"
    fi
  done
  printf '%s' "$dir"
}

@test "verify-trust: without ssh-keygen attestation verification fails closed unless SHIPLOG_ALLOW_TRUST_THRESHOLD_UNENFORCED=1" {
  build_trust_k_docs
  commit=$(adv_trust_commit -S K --sig "$TESTER_EMAIL=K" -e "$TESTER_EMAIL" -m "shiplog: trust root" "$TRUST_K" "$SIGNERS_K")
  nopath=$(make_path_without_ssh_keygen)

  run env PATH="$nopath" bash "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" \
    --old "$ADV_ZERO_OID" --new "$commit" --ref "$ADV_TRUST_REF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ssh-keygen"* ]]

  run env PATH="$nopath" SHIPLOG_ALLOW_TRUST_THRESHOLD_UNENFORCED=1 bash "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" \
    --old "$ADV_ZERO_OID" --new "$commit" --ref "$ADV_TRUST_REF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  rm -rf "$nopath"
}

# ---------------------------------------------------------------------------
# #137 #153 #112 bootstrap
# ---------------------------------------------------------------------------

@test "bootstrap: attestation mode lowercases sig_mode, signs the genesis and writes the genesis attestation" {
  adv_use_signing_key K
  adv_key_pub K > "$ADV_KEYS_DIR/K.pub"
  run env SHIPLOG_PLAIN=1 SHIPLOG_ASSUME_YES=1 "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-bootstrap-trust.sh" \
    --no-push --trust-sig-mode Attestation --trust-threshold 1 \
    --trust-maintainer "name=Shiplog Tester,email=$TESTER_EMAIL,key=$ADV_KEYS_DIR/K.pub"
  [ "$status" -eq 0 ]
  genesis=$(git rev-parse --verify refs/_shiplog/trust/root)
  run bash -c "git show '$genesis:trust.json' | jq -r .sig_mode"
  [ "$output" = "attestation" ]
  adv_assert_commit_signed "$genesis"
  run git ls-tree -r --name-only "$genesis"
  [[ "$output" == *".shiplog/trust_sigs/$TESTER_EMAIL.sig"* ]]
  [ -s ".shiplog/trust_sigs/$TESTER_EMAIL.sig" ]

  run env SHIPLOG_REQUIRE_SIGNED_TRUST=1 "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" \
    --old "$ADV_ZERO_OID" --new "$genesis" --ref "$ADV_TRUST_REF"
  [ "$status" -eq 0 ]
}

@test "bootstrap: without a signing key the genesis is unsigned and the SHIPLOG_SIGN_TRUST hint is printed" {
  adv_key_pub K > "$ADV_KEYS_DIR/K.pub"
  git config --unset user.signingkey >/dev/null 2>&1 || true
  run env GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME="Shiplog Tester" GIT_AUTHOR_EMAIL="$TESTER_EMAIL" \
    SHIPLOG_PLAIN=1 SHIPLOG_ASSUME_YES=1 "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-bootstrap-trust.sh" \
    --no-push --trust-sig-mode CHAIN --trust-maintainer "name=Shiplog Tester,email=$TESTER_EMAIL,key=$ADV_KEYS_DIR/K.pub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHIPLOG_SIGN_TRUST"* ]]
  genesis=$(git rev-parse --verify refs/_shiplog/trust/root)
  run bash -c "git cat-file commit '$genesis' | grep -c '^gpgsig'"
  [ "$output" = "0" ]
  run bash -c "git show '$genesis:trust.json' | jq -r .sig_mode"
  [ "$output" = "chain" ]
  run bash -c "git show '$genesis:trust.json' | jq -e '.maintainers[0].pgp_fpr == null and .maintainers[0].revoked == false'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# #138 trust-sync absolute path
# ---------------------------------------------------------------------------

@test "trust-sync: stores an absolute allowedSignersFile so verify-commit works from a subdirectory" {
  build_trust_k_docs
  adv_use_signing_key K
  commit=$(adv_trust_commit -S K -e "$TESTER_EMAIL" -m "shiplog: trust root" "$TRUST_K" "$SIGNERS_K")
  git update-ref "$ADV_TRUST_REF" "$commit"
  run git shiplog trust sync
  [ "$status" -eq 0 ]
  configured=$(git config gpg.ssh.allowedSignersFile)
  [[ "$configured" == /* ]]
  mkdir -p sub
  run bash -c "cd sub && git verify-commit '$commit'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# #116 validator diagnostics reach the pusher
# ---------------------------------------------------------------------------

@test "hook: policy validator diagnostics are printed before the push is declined" {
  shiplog_bootstrap_trust
  REMOTE_DIR=$(mktemp -d)
  git init -q --bare "$REMOTE_DIR"
  adv_install_hook "$REMOTE_DIR" SHIPLOG_REQUIRE_SIGNED_POLICY=0
  git remote remove "$REMOTE_NAME" >/dev/null 2>&1 || true
  git remote add "$REMOTE_NAME" "$REMOTE_DIR"
  run git push "$REMOTE_NAME" refs/_shiplog/trust/root
  [ "$status" -eq 0 ]

  # "version": 1 (numeric) is invalid for the policy schema.
  bad_policy='{"version": 1, "require_signed": false, "authors": {"default_allowlist": ["'"$TESTER_EMAIL"'"]}}'
  commit=$(adv_policy_commit "$bad_policy")
  git update-ref "$ADV_POLICY_REF" "$commit"
  run git push "$REMOTE_NAME" "$ADV_POLICY_REF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"policy.json failed validation"* ]]
  [[ "$output" == *"version"* ]]
}

# ---------------------------------------------------------------------------
# #109 lint: the non-existent Git variable is gone
# ---------------------------------------------------------------------------

@test "lint: GIT_SSH_ALLOWED_SIGNERS does not appear under bin/ lib/ scripts/ contrib/" {
  run grep -rn "GIT_SSH_ALLOWED_SIGNERS" "$SHIPLOG_PROJECT_ROOT/bin" "$SHIPLOG_PROJECT_ROOT/lib" "$SHIPLOG_PROJECT_ROOT/scripts" "$SHIPLOG_PROJECT_ROOT/contrib"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
