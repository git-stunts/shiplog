#!/usr/bin/env bats

load helpers/common

setup() {
  shiplog_standard_setup
}

teardown() {
  shiplog_standard_teardown
}

@test "attestation mode requires threshold signatures via ssh-keygen" {
  # Skip if ssh-keygen -Y not available in this container
  if ssh-keygen -Y sign -f /dev/null -n shiplog-trust /dev/null 2>&1 | grep -qi 'unknown option'; then
    skip "ssh-keygen without -Y support"
  fi
  mkdir -p .shiplog
  # Trust json with threshold 2 and sig_mode attestation
  cat > .shiplog/trust.json <<'JSON'
{
  "version": 1,
  "id": "shiplog-trust-root",
  "threshold": 2,
  "sig_mode": "attestation",
  "maintainers": [ {"name":"A","email":"a@example.com"}, {"name":"B","email":"b@example.com"} ]
}
JSON
  # Generate two ephemeral SSH keys and allowed_signers
  tmpa=$(mktemp -d); tmpb=$(mktemp -d)
  ssh-keygen -q -t ed25519 -N '' -C 'a@example.com' -f "$tmpa/id_ed25519"
  ssh-keygen -q -t ed25519 -N '' -C 'b@example.com' -f "$tmpb/id_ed25519"
  puba=$(ssh-keygen -y -f "$tmpa/id_ed25519")
  pubb=$(ssh-keygen -y -f "$tmpb/id_ed25519")
  {
    printf 'a@example.com %s\n' "$puba"
    printf 'b@example.com %s\n' "$pubb"
  } > .shiplog/allowed_signers

  # Prepare blobs for trust.json and allowed_signers; create BASE payload and sign with both keys
  oid_trust=$(git hash-object -w .shiplog/trust.json)
  oid_sigs=$(git hash-object -w .shiplog/allowed_signers)
  tab=$'\t'
  base=$(printf "100644 blob %s${tab}trust.json\n100644 blob %s${tab}allowed_signers\n" "$oid_trust" "$oid_sigs" | git mktree)
  echo "signing base=$base"
  printf 'shiplog-trust-tree-v2\n%s\n%s\n%s\n%s\n' "$base" "shiplog-trust-root" "2" "0000000000000000000000000000000000000000" > payload.txt
  mkdir -p .shiplog/trust_sigs
  ssh-keygen -Y sign -q -f "$tmpa/id_ed25519" -n shiplog-trust payload.txt >/dev/null
  mv payload.txt.sig .shiplog/trust_sigs/a@example.com.sig
  ssh-keygen -Y sign -q -f "$tmpb/id_ed25519" -n shiplog-trust payload.txt >/dev/null
  mv payload.txt.sig .shiplog/trust_sigs/b@example.com.sig
  # Sanity-check local verification before committing (FULL mode)
  run bash -lc 'ssh-keygen -Y verify -n shiplog-trust -f .shiplog/allowed_signers -I a@example.com -s .shiplog/trust_sigs/a@example.com.sig < payload.txt'
  [ "$status" -eq 0 ]
  run bash -lc 'ssh-keygen -Y verify -n shiplog-trust -f .shiplog/allowed_signers -I b@example.com -s .shiplog/trust_sigs/b@example.com.sig < payload.txt'
  [ "$status" -eq 0 ]
  # Capture local SHA256s for debug comparison
  run bash -lc "sha256sum payload.txt | awk '{print \$1}'"
  local_payload_sha256=${lines[0]}
  run bash -lc "sha256sum .shiplog/trust_sigs/a\\@example.com.sig | awk '{print \$1}'"
  local_sig_a_sha256=${lines[0]}
  run bash -lc "sha256sum .shiplog/trust_sigs/b\\@example.com.sig | awk '{print \$1}'"
  local_sig_b_sha256=${lines[0]}

  # Commit trust tree (now including sig blobs) and run verifier (BASE mode)
  oid_sa=$(git hash-object -w .shiplog/trust_sigs/a@example.com.sig)
  oid_sb=$(git hash-object -w .shiplog/trust_sigs/b@example.com.sig)
  tree_sigs=$(printf '100644 blob %s\ta@example.com.sig\n100644 blob %s\tb@example.com.sig\n' "$oid_sa" "$oid_sb" | git mktree)
  tree_shipdir=$(printf '040000 tree %s\ttrust_sigs\n' "$tree_sigs" | git mktree)
  tree_root=$(printf '040000 tree %s\t.shiplog\n100644 blob %s\tallowed_signers\n100644 blob %s\ttrust.json\n' "$tree_shipdir" "$oid_sigs" "$oid_trust" | git mktree)
  commit=$(git commit-tree "$tree_root" -m "shiplog: trust attestation E2E")

  # (Optional local re-verify with committed blobs removed here to focus on the shared verifier behavior)

  run bash -lc 'SHIPLOG_DEBUG_SSH_VERIFY=1 "${SHIPLOG_HOME}/scripts/shiplog-verify-trust.sh" --old 0000000000000000000000000000000000000000 --new '"$commit"' --ref refs/_shiplog/trust/root'
  if [ "$status" -ne 0 ]; then
    echo "--- verifier output ---"
    echo "$output"
    echo "--- local sha256 ---"
    echo "payload(local)=$local_payload_sha256"
    echo "sig_a(local)=$local_sig_a_sha256"
    echo "sig_b(local)=$local_sig_b_sha256"
    echo "--- repo sha256 ---"
    run bash -lc "git show '"$commit"':.shiplog/trust_sigs/a@example.com.sig | sha256sum | awk '{print \$1}'"
    echo "sig_a(repo)=${lines[0]}"
    run bash -lc "git show '"$commit"':.shiplog/trust_sigs/b@example.com.sig | sha256sum | awk '{print \$1}'"
    echo "sig_b(repo)=${lines[0]}"
    echo "-----------------------"
  fi
  [ "$status" -eq 0 ]
}
