# Releasing Shiplog with Shiplog (MVP)

This runbook shows how to cut a Shiplog MVP release using Shiplog itself. It covers local operator steps and an optional CI outline. Follow this in order on a clean branch.

## Prerequisites

- Trust is bootstrapped and pushed to the canonical remote (`refs/_shiplog/trust/root`). Use `scripts/shiplog-bootstrap-trust.sh` if not done yet.
- Policy exists locally in `.shiplog/policy.json` and is published at `refs/_shiplog/policy/current` (see below).
- Your workstation has Git 2.35+ and jq 1.6 or newer. Run releases from Docker/Dev Container if unsure.
- Ref names below use the default root `refs/_shiplog`. If you set `SHIPLOG_REF_ROOT` or `git config shiplog.refRoot` (for example `refs/heads/_shiplog`), substitute that root; the scripts follow it automatically.

## 1) Sync Allowed Signers

Fetch the repo and install the signer roster from the signed trust ref. This avoids copying files by hand.

```
git fetch --prune --all
./scripts/shiplog-trust-sync.sh                       # → ./.shiplog/allowed_signers + git config
```

If you prefer a central location:

```
./scripts/shiplog-trust-sync.sh refs/_shiplog/trust/root ~/.shiplog/allowed_signers
```

## 2) Publish Current Policy Ref

Keep `.shiplog/policy.json` under review in normal branches. After merge, publish a signed fast‑forward commit to the policy ref:

```
./scripts/shiplog-sync-policy.sh           # updates refs/_shiplog/policy/current
git push origin refs/_shiplog/policy/current
```

Notes:

- The script validates `.shiplog/policy.json` with the canonical validator (`scripts/policy/validate.sh`) and refuses to move the ref when it fails. It signs the commit when `user.signingkey` is set (override with `SHIPLOG_POLICY_SIGN=1|0`); once a trust ref exists, the pre-receive hook requires a current maintainer's signature on policy updates unless the server sets `SHIPLOG_REQUIRE_SIGNED_POLICY=0`.
- CI can run the same script after a policy PR merges.

## 3) Capture Release Logs (optional but recommended)

Pipe build/test/deploy output to a file so it can be attached as notes to the journal entry.

```
LOG=$(mktemp)
make build 2>&1 | tee -a "$LOG"
make test  2>&1 | tee -a "$LOG"
```

## 4) Write the Journal Entry

Set parameters via environment (non‑interactive, CI‑friendly) and attach logs via `SHIPLOG_LOG`.

```
export SHIPLOG_ENV=prod
export SHIPLOG_SERVICE=release
export SHIPLOG_STATUS=success
export SHIPLOG_REASON="MVP cut"
export SHIPLOG_TICKET="REL-0001"
export SHIPLOG_IMAGE="ghcr.io/your-org/shiplog"
export SHIPLOG_TAG="v0.1.0"
export SHIPLOG_LOG="$LOG"

git shiplog --boring --yes write
```

If policy requires signatures and your key is configured, the commit is signed automatically. If signatures are required but missing, the server will reject the push (see Troubleshooting).

## 5) Push the Journal

Push to the environment journal. The pre‑receive hook enforces fast‑forward, validates the structured trailer, checks `trust_oid` freshness, and verifies signatures against the trust roster.

```
git push origin refs/_shiplog/journal/prod
```

## Troubleshooting (Failure Paths)

- Missing trust ref on server
  - Symptom: `❌ shiplog: trust ref refs/_shiplog/trust/root missing`
  - Fix: Push the trust ref first: `git push origin refs/_shiplog/trust/root`.

- Stale trust OID in entry
  - Symptom: `❌ shiplog: commit <…> trust_oid <X> does not match current trust <Y>`
  - Fix: `git fetch --all` then re‑run `git shiplog write` so the trailer embeds the current trust tip.

- Unsigned entry when signatures are required
  - Symptom: `❌ shiplog: commit <…> missing required signature`
  - Fix: Configure signing and allowed signers:
    - `./scripts/shiplog-trust-sync.sh` to install `allowed_signers`
    - Configure Git signing (SSH or GPG). For SSH: `git config user.signingkey <your SSH key>` and `git config gpg.format ssh`

- Trust update missing `allowed_signers`
  - Symptom: `❌ shiplog: trust ref refs/_shiplog/trust/root missing allowed_signers`
  - Fix: Use `shiplog-bootstrap-trust.sh` or include both `trust.json` and `allowed_signers` in the trust tree.

## Optional: CI Release Sketch

Use a protected GitHub Environment to store the signing key (SSH preferred). In a release job:

- Check out the repo, load the SSH key to `~/.ssh/id_ed25519`, and configure Git for SSH signatures.
- `./scripts/shiplog-trust-sync.sh refs/_shiplog/trust/root ~/.shiplog/allowed_signers` (the first argument is the trust ref, the second the destination)
- Stream build/test logs to a file and run `git shiplog --boring --yes write`
- `git push origin refs/_shiplog/journal/prod`

Keep this job manual or restricted to tag merges until your process matures.
