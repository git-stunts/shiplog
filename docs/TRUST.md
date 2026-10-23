# Trust Bootstrap and Enforcement

Shiplog keeps the signer roster and policy under Git references so every promotion is auditable.
This guide explains the one-time bootstrap, the rules the server applies to every later update,
how to mirror trust material, and how to keep local installations in sync.

## The rules in one paragraph

The trust ref (`refs/_shiplog/trust/root`) holds `trust.json` (threshold, maintainers, `sig_mode`)
and `allowed_signers` (principal → SSH public key). **The current roster approves the next roster:**
every update after genesis is verified against the roster stored at the *previous* tip, never against
the content being pushed. The quorum counts **distinct, unrevoked maintainer keys** — a signature is
bound to a public key (`ssh-keygen -Y find-principals`), the key to a roster principal, and the
principal to a `trust.json` maintainer with `revoked != true`. Filenames, author e-mails and wildcard
principals never count. `sig_mode=attestation` is the only N-of-M mode; `sig_mode=chain` means one
signed trust commit and supports threshold 1 only (decision D1, ROADMAP.md). Deleting a Shiplog ref is
refused. Policy updates must be signed by a current maintainer once a trust ref exists.

One module implements these rules — `lib/trust-verify.sh` — and both enforcement points source it:
the pre-receive hook (`contrib/hooks/pre-receive.shiplog`) and the CI verifier
(`scripts/shiplog-verify-trust.sh`). The adversarial suite `test/27_trust_adversarial.bats` is the
executable specification.

## jq Requirement

All trust and policy validation uses `jq` (1.6+; the hook prefers `/usr/local/bin/jq`, then `jq` on
`PATH`, or `SHIPLOG_JQ_BIN`). Containers, CI and server hooks should install the same build.

## One-Time Trust Bootstrap

Genesis is the only update verified against its own content. Protect it: the server must not have
the ref yet (the hook refuses deletions, so a published trust root cannot be reset by a pusher), and
the pusher should be a server admin. After genesis, every update must be fast-forward and approved by
the quorum of the *prior* roster.

### Fast Path: `scripts/shiplog-bootstrap-trust.sh`

```bash
./scripts/shiplog-bootstrap-trust.sh                               # interactive
./scripts/shiplog-bootstrap-trust.sh --no-push                     # prepare locally, push later
./scripts/shiplog-bootstrap-trust.sh --trust-sig-mode attestation --trust-threshold 2 \
  --trust-maintainer "name=Alice,email=alice@example.com,key=/path/alice.pub" \
  --trust-maintainer "name=Bob,email=bob@example.com,key=/path/bob.pub" --no-push
```

The script will:

1. Collect maintainer names, e-mails, roles, optional OpenPGP fingerprints and SSH public keys.
2. Write `.shiplog/trust.json` (valid JSON, `sig_mode` lowercased) and `.shiplog/allowed_signers`.
3. **Sign the genesis commit by default when `git config user.signingkey` is set.** Without a key it
   prints a hint and creates an unsigned commit. `SHIPLOG_SIGN_TRUST=1|0` overrides
   (`SHIPLOG_TRUST_SIGN` is a deprecated alias).
4. In attestation mode, write the bootstrapping maintainer's attestation to
   `.shiplog/trust_sigs/<principal>.sig` when the configured SSH signing key (`gpg.format ssh`)
   matches one of the roster keys. A threshold above 1 needs more attestations before the push:
   each extra maintainer runs `scripts/shiplog-trust-sign.sh` and the `.sig` files are committed.
5. Offer to push the ref to the configured remote.

Distribute the roster afterwards with `./scripts/shiplog-trust-sync.sh`.

### Manual Bootstrap

```bash
cat > .shiplog/trust.json <<'JSON'
{ "version": 1, "id": "shiplog-trust-root", "sig_mode": "attestation", "threshold": 2,
  "maintainers": [
    {"name": "Alice", "email": "alice@example.com", "pgp_fpr": null, "role": "root", "revoked": false},
    {"name": "Bob",   "email": "bob@example.com",   "pgp_fpr": null, "role": "root", "revoked": false}
  ]
}
JSON
cat > .shiplog/allowed_signers <<'SIGS'
alice@example.com ssh-ed25519 AAAAC3Nz...alice-key...
bob@example.com   ssh-ed25519 AAAAC3Nz...bob-key...
SIGS

OID_TRUST=$(git hash-object -w .shiplog/trust.json)
OID_SIGS=$(git hash-object -w .shiplog/allowed_signers)
BASE=$(printf "100644 blob %s\ttrust.json\n100644 blob %s\tallowed_signers\n" "$OID_TRUST" "$OID_SIGS" | git mktree)
# Commit the base tree first so each maintainer can attest it:
TMP=$(git commit-tree "$BASE" -m "shiplog: trust root (base)")
scripts/shiplog-trust-sign.sh --principal alice@example.com "$TMP"   # Alice, with her key
scripts/shiplog-trust-sign.sh --principal bob@example.com   "$TMP"   # Bob, with his key
# Then commit trust.json + allowed_signers + .shiplog/trust_sigs/*.sig together, signed:
GENESIS=$(git commit-tree <tree with the .sig files> -S -m "shiplog: trust root v1 (GENESIS)")
git update-ref refs/_shiplog/trust/root "$GENESIS"
git push origin refs/_shiplog/trust/root
```

## Signing Modes (sig_mode)

`trust.json.sig_mode` selects how the quorum is expressed:

- `attestation` (recommended; **the only N-of-M mode**): each maintainer stores a detached SSH
  signature under `.shiplog/trust_sigs/<principal>.sig`. The update is accepted when at least
  `threshold` attestations verify over the canonical payload and come from distinct, unrevoked
  maintainer keys of the prior roster.
- `chain` (default when absent; threshold 1 only): the trust commit itself is the approval. A rotation
  is accepted when the commit carries a valid signature from a key that maps to an unrevoked
  maintainer of the prior roster. Chain mode with `threshold > 1` is rejected with a message pointing
  to attestation mode, because a Git commit carries exactly one signature and co-sign chains cannot
  bind N signatures to N keys.

### Attestations: payload, creation, verification

The canonical payload is built by `trust_verify_payload` in `lib/trust-verify.sh` and nowhere else:

```
shiplog-trust-tree-v2
<base_tree_oid>
<trust_id>
<threshold>
<prior_oid>
```

`<base_tree_oid>` is the tree holding only `trust.json` and `allowed_signers` of the commit being
pushed (never the `trust_sigs` directory), `<trust_id>` is `trust.json.id` and `<threshold>` is
`trust.json.threshold` of that same commit. `<prior_oid>` is the trust commit this update replaces
(the server's current tip; 40 zeros at genesis). Signatures use the `shiplog-trust` namespace.

An attestation therefore approves one transition, not a document: it cannot be copied onto another
history to restore an earlier roster (for example, to bring back a removed maintainer). `v1`
payloads, which lacked `<prior_oid>`, are not accepted.

```bash
scripts/shiplog-trust-sign.sh --message-only <commit>                 # print the exact payload
scripts/shiplog-trust-sign.sh --principal you@example.com <commit>    # write .shiplog/trust_sigs/you@example.com.sig
scripts/shiplog-trust-sign.sh --parent <current-tip> <commit>         # explicit prior (default: local trust ref tip)
```

Fetch the trust ref before attesting a rotation: the default `<prior_oid>` is your local
`refs/_shiplog/trust/root`, and an attestation made against a stale tip is rejected.

Verification of each `.sig`:

1. `ssh-keygen -Y find-principals -s <sig> -f <prior allowed_signers>` binds the signature to a roster
   key and its principal(s). A `.sig` made by a key outside the prior roster is ignored.
2. Wildcard principals (`*`, `*@example.com`, `?`) are ignored: they cannot be bound to a maintainer.
   Do not use wildcard lines in a trust roster.
3. The principal must match a `trust.json` maintainer (`email` or `principal`) with `revoked != true`.
4. `ssh-keygen -Y verify -n shiplog-trust -I <principal>` must succeed over the payload.
5. The key fingerprint is recorded; the same key under two names counts once.

The legacy `SHIPLOG_ATTEST_PAYLOAD_MODE=full` and `SHIPLOG_ATTEST_BACKCOMP` options are gone: a
signature over the full commit tree can never match once a `.sig` file is part of that tree.

## Trust-Commit Signature Gate (Server Hook)

`SHIPLOG_REQUIRE_SIGNED_TRUST` controls **one thing**: whether the trust commit itself must carry a
valid signature from a current (prior-roster) maintainer. It never replaces the quorum.

- Default `0`: the commit signature is not required (in chain mode a rotation still needs the
  maintainer signature, because that signature *is* the quorum; only a chain-mode genesis may be
  unsigned).
- Recommended for production: `1`. Values are case-insensitive (`1|true|yes|on`).
- `SHIPLOG_REQUIRE_SIGNED_TRUST_MODE` is **ignored** (a warning is printed). The `either` shortcut,
  which let one commit signature waive the attestation quorum, has been removed (#113).
- `SHIPLOG_ALLOW_TRUST_THRESHOLD_UNENFORCED=1` is the only escape hatch. It skips the quorum and
  prints a loud warning on every push; use it for staged migrations only.

## Policy Ref Authentication

Once a trust ref exists on the server, every update to `refs/_shiplog/policy/current` must:

- contain `.shiplog/policy.json` (an empty or foreign tree is rejected, naming the path);
- pass the policy validator (`scripts/policy/validate.sh` / `scripts/lib/policy_validate.jq`);
- carry a valid signature whose key maps to an unrevoked maintainer of the current trust roster
  (SSH keys via the roster principal, OpenPGP keys via `maintainers[].pgp_fpr`).

`SHIPLOG_REQUIRE_SIGNED_POLICY` overrides the default (`1` when a trust ref exists, `0` otherwise) so a
fresh server can receive its first policy before trust is pushed. Bootstrap order: trust first, then
policy. Sign policy commits with `SHIPLOG_POLICY_SIGN=1 scripts/shiplog-sync-policy.sh`.

## Deletions and server configuration

The hook refuses `git push origin :refs/_shiplog/...` for the trust ref, the policy ref, journals and
anchors. A deleted ref would turn the next push into a "genesis" and let anyone rewrite history.
`SHIPLOG_ALLOW_REF_DELETE=1` in the hook environment permits deletion for emergency recovery and logs a
warning. Add defense in depth on the bare repository:

```bash
git --git-dir=/srv/git/your.git config receive.denyDeletes true
git --git-dir=/srv/git/your.git config receive.denyNonFastForwards true
```

## Installing the hook on a server

The hook is one file, but it sources `lib/trust-verify.sh` and runs `scripts/shiplog-verify-trust.sh`
and `scripts/policy/validate.sh` from a Shiplog checkout it trusts. Install a checkout owned by the git
user, not writable by the group or others, and point the hook at it:

```bash
sudo -u git git clone https://github.com/git-stunts/shiplog /srv/shiplog
sudo -u git chmod -R go-w /srv/shiplog
sudo -u git cp /srv/shiplog/contrib/hooks/pre-receive.shiplog /srv/git/your.git/hooks/pre-receive
sudo -u git chmod 0755 /srv/git/your.git/hooks/pre-receive
# hook environment (how depends on your git server; a wrapper that exports these works everywhere)
SHIPLOG_HOME=/srv/shiplog
SHIPLOG_REQUIRE_SIGNED_TRUST=1
```

Discovery rules (fail closed): the hook sources `$SHIPLOG_HOME/lib/trust-verify.sh` (or
`SHIPLOG_TRUST_VERIFY_LIB`) and runs `$SHIPLOG_HOME/scripts/shiplog-verify-trust.sh` (or
`SHIPLOG_VERIFY_TRUST_BIN`). Only files under `SHIPLOG_HOME`, the hooks directory or the repository
directory are accepted, and never files that are group/world writable. The parent of the repository
directory is not trusted. The hook exports an absolute `GIT_DIR` before running anything, so the
verifier works from a bare repository. Without a module the hook refuses every push with a message
naming `SHIPLOG_HOME`.

## Keeping Clients in Sync

```bash
./scripts/shiplog-trust-sync.sh                    # refs/_shiplog/trust/root → .shiplog/allowed_signers
./scripts/shiplog-trust-sync.sh refs/_shiplog/trust/root ~/.config/shiplog/allowed_signers
```

The script reads `allowed_signers` from the trust tip, writes it to the destination and sets
`gpg.ssh.allowedSignersFile` to the **absolute** path, so `git verify-commit` works from any directory.

## Server Enforcement Checklist

![Trust Modes](img/trust-modes.svg)

*Source: [trust-modes.mmd](img/trust-modes.mmd)*

- Fail closed when the trust ref, `trust.json`, `allowed_signers` or the shared module is missing.
- Verify every non-genesis trust update against the prior roster; refuse non-fast-forward updates.
- Count distinct unrevoked maintainer keys; chain mode is threshold 1 only.
- Require the trust commit itself to be signed when `SHIPLOG_REQUIRE_SIGNED_TRUST=1`.
- Require policy updates to be signed by a current maintainer and to contain a valid `policy.json`.
- Refuse deletions; set `receive.denyDeletes` and `receive.denyNonFastForwards` as well.
- For journal entries: fast-forward only, signature verified against the roster from the trust ref
  (`git -c gpg.ssh.allowedSignersFile=<roster> verify-commit`), trailer fields and `trust_oid` checked.
- Mirror `refs/_shiplog/{trust,policy,journal}` to a second remote or WORM storage for recovery.

## Troubleshooting Verification

Export `SHIPLOG_DEBUG_SSH_VERIFY=1` in the hook environment (self-hosted) or the CI job. The debug
output names the module and verifier paths in use, the roster commit used for the quorum, the
principals found in `allowed_signers`, the payload tree OID and SHA-256, the maintainer each signature
was bound to (or why it was ignored: not a roster key, wildcard principal, revoked, duplicate key), and
the `git verify-commit` output on failure.

Common rejections:

- `is not signed by a current maintainer` — the signing key is not in the *prior* roster, its principal
  is a wildcard, or the maintainer is revoked.
- `verified N distinct maintainer attestation(s); threshold is T` — too few valid `.sig` files from
  distinct keys. Check that each maintainer signed the payload of the commit being pushed
  (`scripts/shiplog-trust-sign.sh --message-only <commit>`).
- `sig_mode=chain supports threshold 1 only` — switch the roster to `sig_mode=attestation`.
- `shared trust verification module lib/trust-verify.sh not found` — set `SHIPLOG_HOME`.

## Solo Maintainer Trust Setup

When you are the only maintainer, create several independent SSH signing identities (laptop key,
hardware token, CI key) and set `threshold` to 2 with `sig_mode=attestation`. Each identity gets its
own `allowed_signers` line with a distinct principal and a matching `trust.json` maintainer entry.
Use real principals; wildcards are never counted.

## Emergency Recovery

- Add or remove a maintainer, change the threshold: edit `trust.json` and `allowed_signers`, commit as
  a fast-forward child, collect `threshold` attestations from the *current* maintainers, push.
- Revoke a compromised key: set `revoked: true` and remove its `allowed_signers` line in the same way.
- Lost quorum (keys gone, or a roster that approved itself before this rule existed): a server admin
  resets the ref directly on the bare repository (`git --git-dir=… update-ref`), or deletes it with
  `SHIPLOG_ALLOW_REF_DELETE=1` and pushes a new genesis. Record the reason in your audit log and
  re-establish a healthy roster immediately.

Always follow up with `./scripts/shiplog-trust-sync.sh` on workstations and runners.

## Recommended Runbook Entries

See `docs/runbooks/release.md` for an end-to-end "use Shiplog to release Shiplog" flow. Runbooks for
key loss, trust rotation and mirror recovery are not written yet (#77); until then, follow the rotation
and revocation steps in this document.
