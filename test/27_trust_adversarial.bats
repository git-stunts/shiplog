#!/usr/bin/env bats
# bats file_tags=adversarial
#
# Adversarial trust suite (ROADMAP G2). Every test asserts the SECURE behavior:
# attacks are rejected, legitimate operations are accepted. Most of these are
# red against the current hook/verifier on purpose; G3 makes them green.
#
# Scenarios: #94 self-certify, #95 ref-delete, #96 one-key-quorum and
# wildcard-principal, #109 roster-swap and signed-journal-accepted,
# #110 shared-verifier-path, #111 genesis-threshold-1, #113 either-waives,
# #114 unsigned-policy. Per decision D1, attestation is the only N-of-M mode;
# chain mode appears only in the threshold-1 genesis acceptance test.
#
# Server side: the bare remote never has gpg.ssh.allowedSignersFile configured
# (the hook wrapper also hides the global git config). The only roster the
# server may use is the one in the trust ref.

load helpers/common
load helpers/trust_adversarial

REMOTE_NAME="shiplog-adv"
TESTER_EMAIL="shiplog-tester@example.com"

# Hook environment that represents the recommended production server (D1):
# trust commits must be signed and the quorum is attestation-based.
HOOK_ENV_ATTEST=(SHIPLOG_REQUIRE_SIGNED_TRUST=1 SHIPLOG_REQUIRE_SIGNED_TRUST_MODE=attestation)

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
  export SHIPLOG_ENV=prod

  adv_keys_init
  adv_keygen A a@example.com
  adv_keygen B b@example.com
  adv_keygen C c@example.com
  adv_keygen K "$TESTER_EMAIL"

  REMOTE_PARENT=$(mktemp -d)
  REMOTE_DIR="$REMOTE_PARENT/origin.git"
  git init -q --bare "$REMOTE_DIR"
  git remote remove "$REMOTE_NAME" >/dev/null 2>&1 || true
  git remote add "$REMOTE_NAME" "$REMOTE_DIR"
}

teardown() {
  git remote remove "$REMOTE_NAME" >/dev/null 2>&1 || true
  if [ -n "${REMOTE_PARENT:-}" ]; then
    rm -rf "$REMOTE_PARENT"
  fi
  if [ -n "${FAKE_HOME:-}" ]; then
    rm -rf "$FAKE_HOME"
  fi
  adv_keys_cleanup
  shiplog_cleanup_sandbox_repo
}

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

# Push one ref and fail loudly (with the hook output) if the server declines.
adv_push_ok() {
  run git push "$REMOTE_NAME" "$1"
  if [ "$status" -ne 0 ]; then
    echo "--- expected push of $1 to succeed ---"
    echo "$output"
    return 1
  fi
}

# Push one ref and fail loudly if the server accepts it.
adv_push_rejected() {
  run git push "$REMOTE_NAME" "$1"
  if [ "$status" -eq 0 ]; then
    echo "--- expected push of $1 to be rejected ---"
    echo "$output"
    return 1
  fi
}

make_entry() {
  SHIPLOG_SERVICE="adversarial" \
  SHIPLOG_STATUS="success" \
  SHIPLOG_REASON="trust suite" \
  SHIPLOG_TICKET="G2-1" \
  SHIPLOG_REGION="us-west-2" \
  SHIPLOG_CLUSTER="prod-1" \
  SHIPLOG_NAMESPACE="default" \
  SHIPLOG_IMAGE="ghcr.io/example/app" \
  SHIPLOG_TAG="v0.0.1" \
  SHIPLOG_RUN_URL="https://ci.example.local/run/1" \
  git shiplog --boring --yes write >/dev/null
}

# Roster of A and B, threshold 2, attestation mode, both attestations present,
# commit signed by A. Sets GENESIS_AB and the local trust ref.
build_genesis_ab() {
  TRUST_AB=$(adv_trust_json 2 attestation a@example.com b@example.com)
  SIGNERS_AB="$(adv_signers a@example.com=A b@example.com=B)"
  GENESIS_AB=$(adv_trust_commit -S A --sig a@example.com=A --sig b@example.com=B \
    -m "shiplog: trust root (A+B genesis)" "$TRUST_AB" "$SIGNERS_AB")
  git update-ref "$ADV_TRUST_REF" "$GENESIS_AB"
}

# Single-maintainer roster (the tester, key K), threshold 1, attestation mode,
# attested and signed by K. Sets GENESIS_K, the local trust ref, and syncs the
# client's allowed_signers from it.
build_genesis_k() {
  TRUST_K=$(adv_trust_json 1 attestation "$TESTER_EMAIL")
  SIGNERS_K="$(adv_signers_line "$TESTER_EMAIL" K)"
  GENESIS_K=$(adv_trust_commit -S K --sig "$TESTER_EMAIL=K" -e "$TESTER_EMAIL" \
    -m "shiplog: trust root (K genesis)" "$TRUST_K" "$SIGNERS_K")
  adv_assert_commit_signed "$GENESIS_K"
  git update-ref "$ADV_TRUST_REF" "$GENESIS_K"
  git shiplog trust sync >/dev/null
}

# Policy signed by K. Sets POLICY_TIP and the local policy ref.
build_policy_k() {
  local require_signed="$1" parent
  parent=$(git rev-parse -q --verify "$ADV_POLICY_REF" 2>/dev/null || true)
  POLICY_TIP=$(adv_policy_commit -S K -e "$TESTER_EMAIL" ${parent:+-p "$parent"} \
    "$(adv_policy_json "$require_signed" "$TESTER_EMAIL")")
  git update-ref "$ADV_POLICY_REF" "$POLICY_TIP"
  shiplog_write_local_policy
}

# Full legitimate server: hook (attestation gate), trust K, policy signed by K.
bootstrap_server_k() {
  local require_signed="$1"
  adv_install_hook "$REMOTE_DIR" "${HOOK_ENV_ATTEST[@]}"
  build_genesis_k
  adv_push_ok "$ADV_TRUST_REF"
  build_policy_k "$require_signed"
  adv_push_ok "$ADV_POLICY_REF"
  git shiplog init >/dev/null
}

# ---------------------------------------------------------------------------
# #94 self-certify
# ---------------------------------------------------------------------------

@test "self-certify: rotation signed only by a non-roster key is rejected" {
  adv_install_hook "$REMOTE_DIR" "${HOOK_ENV_ATTEST[@]}"
  build_genesis_ab
  adv_push_ok "$ADV_TRUST_REF"

  # Attacker C: fast-forward child that installs a one-key roster of C,
  # signed by C, attested by C. Valid against itself, void against A+B.
  trust_c=$(adv_trust_json 1 attestation c@example.com)
  signers_c="$(adv_signers_line c@example.com C)"
  hostile=$(adv_trust_commit -p "$GENESIS_AB" -S C --sig c@example.com=C \
    -m "shiplog: trust takeover" "$trust_c" "$signers_c")
  git update-ref "$ADV_TRUST_REF" "$hostile" "$GENESIS_AB"

  adv_push_rejected "$ADV_TRUST_REF"
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" = "$GENESIS_AB" ]
}

@test "trust-replay: re-pushing an earlier roster with its original attestations is rejected" {
  adv_install_hook "$REMOTE_DIR" "${HOOK_ENV_ATTEST[@]}"
  # S0: roster A, B, C (threshold 2), attested by A and B.
  trust_abc=$(adv_trust_json 2 attestation a@example.com b@example.com c@example.com)
  signers_abc="$(adv_signers a@example.com=A b@example.com=B c@example.com=C)"
  s0=$(adv_trust_commit -S A --sig a@example.com=A --sig b@example.com=B \
    -m "shiplog: trust root (A+B+C)" "$trust_abc" "$signers_abc")
  git update-ref "$ADV_TRUST_REF" "$s0"
  adv_push_ok "$ADV_TRUST_REF"

  # S1: A and B remove C (say C's key leaked).
  trust_ab=$(adv_trust_json 2 attestation a@example.com b@example.com)
  signers_ab="$(adv_signers a@example.com=A b@example.com=B)"
  s1=$(adv_trust_commit -p "$s0" -S A --sig a@example.com=A --sig b@example.com=B \
    -m "shiplog: remove C" "$trust_ab" "$signers_ab")
  git update-ref "$ADV_TRUST_REF" "$s1" "$s0"
  adv_push_ok "$ADV_TRUST_REF"

  # Replay by A alone: a child of S1, signed by A, that copies S0's tree with its
  # .sig files. B never approved going from S1 back to S0, so 2-of-2 is not met.
  replay=$(adv_commit_tree "$(git rev-parse "$s0^{tree}")" "$s1" A "shiplog: restore C" a@example.com)
  adv_assert_commit_signed "$replay"
  git update-ref "$ADV_TRUST_REF" "$replay" "$s1"

  adv_push_rejected "$ADV_TRUST_REF"
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" = "$s1" ]
}

@test "legit-rotation: A+B quorum adding maintainer C is accepted" {
  adv_install_hook "$REMOTE_DIR" "${HOOK_ENV_ATTEST[@]}"
  build_genesis_ab
  adv_push_ok "$ADV_TRUST_REF"

  trust_abc=$(adv_trust_json 2 attestation a@example.com b@example.com c@example.com)
  signers_abc="$(adv_signers a@example.com=A b@example.com=B c@example.com=C)"
  rotation=$(adv_trust_commit -p "$GENESIS_AB" -S A --sig a@example.com=A --sig b@example.com=B \
    -m "shiplog: add maintainer C" "$trust_abc" "$signers_abc")
  git update-ref "$ADV_TRUST_REF" "$rotation" "$GENESIS_AB"

  adv_push_ok "$ADV_TRUST_REF"
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" = "$rotation" ]
}

# ---------------------------------------------------------------------------
# #95 ref-delete
# ---------------------------------------------------------------------------

@test "ref-delete: deleting journal and trust refs is rejected" {
  bootstrap_server_k false
  make_entry
  adv_push_ok refs/_shiplog/journal/prod
  journal_tip=$(adv_remote_ref "$REMOTE_DIR" refs/_shiplog/journal/prod)
  [ -n "$journal_tip" ]

  adv_push_rejected ":refs/_shiplog/journal/prod"
  adv_push_rejected ":$ADV_TRUST_REF"
  adv_push_rejected ":$ADV_POLICY_REF"

  [ "$(adv_remote_ref "$REMOTE_DIR" refs/_shiplog/journal/prod)" = "$journal_tip" ]
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" = "$GENESIS_K" ]
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_POLICY_REF")" = "$POLICY_TIP" ]
}

@test "ref-delete: SHIPLOG_ALLOW_REF_DELETE=1 permits deletion and prints a warning" {
  bootstrap_server_k false
  make_entry
  adv_push_ok refs/_shiplog/journal/prod

  adv_install_hook "$REMOTE_DIR" "${HOOK_ENV_ATTEST[@]}" SHIPLOG_ALLOW_REF_DELETE=1
  run git push "$REMOTE_NAME" ":refs/_shiplog/journal/prod"
  [ "$status" -eq 0 ]
  [ -z "$(adv_remote_ref "$REMOTE_DIR" refs/_shiplog/journal/prod)" ]
  shopt -s nocasematch
  [[ "$output" == *warn* ]]
  shopt -u nocasematch
}

# ---------------------------------------------------------------------------
# #96 one-key-quorum / wildcard-principal / revoked
# ---------------------------------------------------------------------------

@test "one-key-quorum: one key under two principals cannot satisfy threshold 2" {
  adv_install_hook "$REMOTE_DIR" "${HOOK_ENV_ATTEST[@]}"
  trust=$(adv_trust_json 2 attestation a@example.com b@example.com)
  # Both roster lines carry the SAME public key (A). Two .sig files, one signer.
  signers="$(adv_signers a@example.com=A b@example.com=A)"
  commit=$(adv_trust_commit -S A --sig a@example.com=A --sig b@example.com=A \
    -m "shiplog: one key, two names" "$trust" "$signers")
  git update-ref "$ADV_TRUST_REF" "$commit"

  adv_push_rejected "$ADV_TRUST_REF"
  [ -z "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" ]
}

@test "wildcard-principal: a '* <key>' roster line cannot inflate the attestation count" {
  adv_install_hook "$REMOTE_DIR" "${HOOK_ENV_ATTEST[@]}"
  trust=$(adv_trust_json 2 attestation a@example.com b@example.com)
  signers="$(printf '* %s\n' "$(adv_key_pub A)")"
  commit=$(adv_trust_commit -S A --sig a@example.com=A --sig b@example.com=A \
    -m "shiplog: wildcard roster" "$trust" "$signers")
  git update-ref "$ADV_TRUST_REF" "$commit"

  adv_push_rejected "$ADV_TRUST_REF"
  [ -z "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" ]
}

@test "revoked-maintainer: an attestation from a revoked maintainer does not count" {
  adv_install_hook "$REMOTE_DIR" "${HOOK_ENV_ATTEST[@]}"
  trust=$(adv_trust_json 2 attestation a@example.com b@example.com:revoked)
  signers="$(adv_signers a@example.com=A b@example.com=B)"
  commit=$(adv_trust_commit -S A --sig a@example.com=A --sig b@example.com=B \
    -m "shiplog: revoked co-signer" "$trust" "$signers")
  git update-ref "$ADV_TRUST_REF" "$commit"

  adv_push_rejected "$ADV_TRUST_REF"
  [ -z "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" ]
}

# ---------------------------------------------------------------------------
# #109 signed-journal-accepted / roster-swap
# ---------------------------------------------------------------------------

@test "signed-journal-accepted: signed entry by a roster key passes with no allowedSignersFile on the server" {
  bootstrap_server_k true
  [ -z "$(adv_server_signers_config "$REMOTE_DIR")" ]

  adv_use_signing_key K
  export SHIPLOG_SIGN=1
  make_entry
  entry=$(git rev-parse refs/_shiplog/journal/prod)
  adv_assert_commit_signed "$entry"

  adv_push_ok refs/_shiplog/journal/prod
  [ "$(adv_remote_ref "$REMOTE_DIR" refs/_shiplog/journal/prod)" = "$entry" ]
  [ -z "$(adv_server_signers_config "$REMOTE_DIR")" ]
}

@test "roster-swap: a signed entry is rejected after the roster drops the signing key" {
  bootstrap_server_k true
  adv_use_signing_key K
  export SHIPLOG_SIGN=1
  make_entry
  adv_push_ok refs/_shiplog/journal/prod
  first=$(adv_remote_ref "$REMOTE_DIR" refs/_shiplog/journal/prod)
  [ -n "$first" ]

  # Legitimate rotation approved by the prior roster (K) that hands the trust
  # root to A and drops K.
  trust_a=$(adv_trust_json 1 attestation a@example.com)
  signers_a="$(adv_signers_line a@example.com A)"
  rotation=$(adv_trust_commit -p "$GENESIS_K" -S K --sig "$TESTER_EMAIL=K" --sig a@example.com=A \
    -e "$TESTER_EMAIL" -m "shiplog: hand over to A" "$trust_a" "$signers_a")
  git update-ref "$ADV_TRUST_REF" "$rotation" "$GENESIS_K"
  adv_push_ok "$ADV_TRUST_REF"

  # The client still signs with K (its local allowed_signers is stale on purpose).
  make_entry
  second=$(git rev-parse refs/_shiplog/journal/prod)
  [ "$second" != "$first" ]
  adv_push_rejected refs/_shiplog/journal/prod
  [ "$(adv_remote_ref "$REMOTE_DIR" refs/_shiplog/journal/prod)" = "$first" ]
}

# ---------------------------------------------------------------------------
# #114 unsigned-policy
# ---------------------------------------------------------------------------

@test "unsigned-policy: an unsigned policy update is rejected when a trust ref exists" {
  bootstrap_server_k true

  # Attacker flips require_signed and adds themself to the allowlist.
  hostile=$(adv_policy_commit -p "$POLICY_TIP" -e c@example.com \
    "$(adv_policy_json false "$TESTER_EMAIL" c@example.com)")
  git update-ref "$ADV_POLICY_REF" "$hostile" "$POLICY_TIP"

  adv_push_rejected "$ADV_POLICY_REF"
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_POLICY_REF")" = "$POLICY_TIP" ]
}

@test "unsigned-policy: a policy update signed by a non-roster key is rejected" {
  bootstrap_server_k true

  hostile=$(adv_policy_commit -p "$POLICY_TIP" -S C -e c@example.com \
    "$(adv_policy_json false "$TESTER_EMAIL" c@example.com)")
  git update-ref "$ADV_POLICY_REF" "$hostile" "$POLICY_TIP"

  adv_push_rejected "$ADV_POLICY_REF"
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_POLICY_REF")" = "$POLICY_TIP" ]
}

@test "signed-policy-accepted: a policy update signed by a roster key is accepted" {
  bootstrap_server_k true
  build_policy_k false
  adv_push_ok "$ADV_POLICY_REF"
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_POLICY_REF")" = "$POLICY_TIP" ]
}

@test "empty-policy-tree: a policy commit without .shiplog/policy.json is rejected" {
  bootstrap_server_k true

  hostile=$(adv_policy_commit -p "$POLICY_TIP" -S K -e "$TESTER_EMAIL" --empty)
  git update-ref "$ADV_POLICY_REF" "$hostile" "$POLICY_TIP"

  adv_push_rejected "$ADV_POLICY_REF"
  [[ "$output" == *policy.json* ]]
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_POLICY_REF")" = "$POLICY_TIP" ]
}

@test "policy-bootstrap: an unsigned policy push is accepted on a server with no trust ref" {
  adv_install_hook "$REMOTE_DIR" "${HOOK_ENV_ATTEST[@]}"
  [ -z "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" ]

  policy=$(adv_policy_commit "$(adv_policy_json false "$TESTER_EMAIL")")
  git update-ref "$ADV_POLICY_REF" "$policy"

  adv_push_ok "$ADV_POLICY_REF"
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_POLICY_REF")" = "$policy" ]
}

# ---------------------------------------------------------------------------
# #113 either-waives
# ---------------------------------------------------------------------------

# Child of GENESIS_AB with the same roster, a valid commit signature by A, and
# two .sig files that do NOT verify against the roster (signed by outsider C).
build_either_bait() {
  EITHER_BAIT=$(adv_trust_commit -p "$GENESIS_AB" -S A --sig a@example.com=C --sig b@example.com=C \
    -m "shiplog: one signature, zero valid attestations" "$TRUST_AB" "$SIGNERS_AB")
}

@test "either-waives: verifier rejects MODE=either with one commit signature and zero valid attestations at threshold 2" {
  build_genesis_ab
  git shiplog trust sync >/dev/null

  # Control: the same invocation accepts a child that carries valid A+B attestations,
  # so the rejection below is about the bait, not a verifier that rejects everything.
  legit=$(adv_trust_commit -p "$GENESIS_AB" -S A --sig a@example.com=A --sig b@example.com=B \
    -m "shiplog: two valid attestations" "$TRUST_AB" "$SIGNERS_AB")
  run env SHIPLOG_REQUIRE_SIGNED_TRUST=1 SHIPLOG_REQUIRE_SIGNED_TRUST_MODE=either \
    "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" \
    --old "$GENESIS_AB" --new "$legit" --ref "$ADV_TRUST_REF"
  if [ "$status" -ne 0 ]; then
    echo "--- control: verifier rejected a valid A+B child ---"
    echo "$output"
  fi
  [ "$status" -eq 0 ]

  build_either_bait
  run env SHIPLOG_REQUIRE_SIGNED_TRUST=1 SHIPLOG_REQUIRE_SIGNED_TRUST_MODE=either \
    "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" \
    --old "$GENESIS_AB" --new "$EITHER_BAIT" --ref "$ADV_TRUST_REF"
  [ "$status" -ne 0 ]
}

@test "either-waives: hook rejects MODE=either with one commit signature and zero valid attestations at threshold 2" {
  adv_install_hook "$REMOTE_DIR" SHIPLOG_REQUIRE_SIGNED_TRUST=1 SHIPLOG_REQUIRE_SIGNED_TRUST_MODE=either
  build_genesis_ab
  adv_push_ok "$ADV_TRUST_REF"
  build_either_bait
  git update-ref "$ADV_TRUST_REF" "$EITHER_BAIT" "$GENESIS_AB"

  adv_push_rejected "$ADV_TRUST_REF"
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" = "$GENESIS_AB" ]
}

# ---------------------------------------------------------------------------
# #111 genesis-threshold-1
# ---------------------------------------------------------------------------

@test "genesis-threshold-1: a signed threshold-1 genesis push is accepted (hook and verifier)" {
  adv_install_hook "$REMOTE_DIR" SHIPLOG_REQUIRE_SIGNED_TRUST=1
  [ -z "$(adv_server_signers_config "$REMOTE_DIR")" ]

  # No sig_mode: the verifier's default (chain) collapses to one signed commit.
  trust=$(adv_trust_json 1 - "$TESTER_EMAIL")
  signers="$(adv_signers_line "$TESTER_EMAIL" K)"
  genesis=$(adv_trust_commit -S K -e "$TESTER_EMAIL" -m "shiplog: trust root v1 (GENESIS)" "$trust" "$signers")
  adv_assert_commit_signed "$genesis"
  git update-ref "$ADV_TRUST_REF" "$genesis"
  git shiplog trust sync >/dev/null

  adv_push_ok "$ADV_TRUST_REF"
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" = "$genesis" ]

  run env SHIPLOG_REQUIRE_SIGNED_TRUST=1 \
    "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" \
    --old "$ADV_ZERO_OID" --new "$genesis" --ref "$ADV_TRUST_REF"
  if [ "$status" -ne 0 ]; then
    echo "--- verifier output ---"
    echo "$output"
  fi
  [ "$status" -eq 0 ]
}

@test "genesis-threshold-1: a threshold-2 genesis without attestations is rejected by the verifier" {
  # Control: the same invocation accepts the signed threshold-1 genesis, so the
  # rejection below is about the threshold, not a verifier that rejects every genesis.
  trust1=$(adv_trust_json 1 - "$TESTER_EMAIL")
  signers1="$(adv_signers_line "$TESTER_EMAIL" K)"
  genesis1=$(adv_trust_commit -S K -e "$TESTER_EMAIL" -m "shiplog: trust root v1 (GENESIS)" "$trust1" "$signers1")
  git update-ref "$ADV_TRUST_REF" "$genesis1"
  git shiplog trust sync >/dev/null
  run env SHIPLOG_REQUIRE_SIGNED_TRUST=1 \
    "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" \
    --old "$ADV_ZERO_OID" --new "$genesis1" --ref "$ADV_TRUST_REF"
  if [ "$status" -ne 0 ]; then
    echo "--- control: verifier rejected a signed threshold-1 genesis ---"
    echo "$output"
  fi
  [ "$status" -eq 0 ]

  trust=$(adv_trust_json 2 - a@example.com b@example.com)
  signers="$(adv_signers a@example.com=A b@example.com=B)"
  genesis=$(adv_trust_commit -S A -m "shiplog: unsatisfiable genesis" "$trust" "$signers")
  git update-ref "$ADV_TRUST_REF" "$genesis"
  git shiplog trust sync >/dev/null

  run env SHIPLOG_REQUIRE_SIGNED_TRUST=1 \
    "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" \
    --old "$ADV_ZERO_OID" --new "$genesis" --ref "$ADV_TRUST_REF"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# #110 shared-verifier-path
# ---------------------------------------------------------------------------

@test "shared-verifier-path: the hook runs the shared verifier from SHIPLOG_HOME" {
  SENTINEL="$REMOTE_PARENT/verifier-ran"
  FAKE_HOME=$(adv_fake_home_with_recording_verifier "$SENTINEL")
  adv_install_hook "$REMOTE_DIR" "${HOOK_ENV_ATTEST[@]}" "SHIPLOG_HOME=$FAKE_HOME"
  [ -z "$(adv_server_signers_config "$REMOTE_DIR")" ]

  build_genesis_k
  adv_push_ok "$ADV_TRUST_REF"
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" = "$GENESIS_K" ]
  [ -s "$SENTINEL" ]
}

@test "shared-verifier-path: a decoy verifier next to the bare repo is never executed" {
  DECOY_SENTINEL="$REMOTE_PARENT/decoy-ran"
  mkdir -p "$REMOTE_PARENT/scripts"
  printf '#!/bin/sh\ntouch %s\nexit 0\n' "$DECOY_SENTINEL" >"$REMOTE_PARENT/scripts/shiplog-verify-trust.sh"
  chmod 0755 "$REMOTE_PARENT/scripts/shiplog-verify-trust.sh"

  adv_install_hook "$REMOTE_DIR" "${HOOK_ENV_ATTEST[@]}"
  build_genesis_ab
  adv_push_ok "$ADV_TRUST_REF"

  trust_c=$(adv_trust_json 1 attestation c@example.com)
  signers_c="$(adv_signers_line c@example.com C)"
  hostile=$(adv_trust_commit -p "$GENESIS_AB" -S C --sig c@example.com=C \
    -m "shiplog: takeover via decoy" "$trust_c" "$signers_c")
  git update-ref "$ADV_TRUST_REF" "$hostile" "$GENESIS_AB"

  adv_push_rejected "$ADV_TRUST_REF"
  [ "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" = "$GENESIS_AB" ]
  [ ! -e "$DECOY_SENTINEL" ]
}

@test "shared-verifier-path: a group-writable SHIPLOG_VERIFY_TRUST_BIN is refused" {
  unsafe="$REMOTE_PARENT/verify-group-writable.sh"
  cp "$SHIPLOG_PROJECT_ROOT/scripts/shiplog-verify-trust.sh" "$unsafe"
  chmod 0775 "$unsafe"
  adv_install_hook "$REMOTE_DIR" "${HOOK_ENV_ATTEST[@]}" "SHIPLOG_VERIFY_TRUST_BIN=$unsafe"

  build_genesis_k
  adv_push_rejected "$ADV_TRUST_REF"
  [[ "$output" == *verify-group-writable.sh* ]]
  [ -z "$(adv_remote_ref "$REMOTE_DIR" "$ADV_TRUST_REF")" ]
}
