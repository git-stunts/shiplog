# Security Modes and Signing

Shiplog supports two modes of operation:

- Unsigned mode (default): Entries are not required to be signed. Useful for fast adoption and local trials.
- Signed mode: Entries must be signed and verified against a trusted signer roster. Enables strong provenance.

Policy controls which mode is active. You can switch at any time without rewriting history. For multi‑sig trust updates, see `docs/TRUST.md` (sig_mode: chain or attestation).

## Current Mode and Defaults

- Default mode: unsigned. The CLI does not sign by default unless the policy requires it or you set `SHIPLOG_SIGN=1`.
- To view the effective policy: `git shiplog policy show` (add `--json` for machine output). The policy document lives in the policy ref `<ref root>/policy/current` (default root `refs/_shiplog`; see `git shiplog refs root show`) or in `.shiplog/policy.json`.

## Enabling Signing

### 1. Bootstrap trust (once)

- Create a signed trust commit at `refs/_shiplog/trust/root` containing `trust.json` and `allowed_signers`.
- Interactive: `./scripts/shiplog-bootstrap-trust.sh`
- Non-interactive (env-driven):

```
export SHIPLOG_TRUST_COUNT=1
export SHIPLOG_TRUST_ID="shiplog-trust-root"
export SHIPLOG_TRUST_1_NAME="Your Name"
export SHIPLOG_TRUST_1_EMAIL="you@example.com"
export SHIPLOG_TRUST_1_ROLE="root"
export SHIPLOG_TRUST_1_PGP_FPR=""
export SHIPLOG_TRUST_1_SSH_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
export SHIPLOG_TRUST_1_PRINCIPAL="you@example.com"
export SHIPLOG_TRUST_1_REVOKED="no"
export SHIPLOG_TRUST_THRESHOLD=1
export SHIPLOG_TRUST_COMMIT_MESSAGE="shiplog: trust root v1 (GENESIS)"
export SHIPLOG_ASSUME_YES=1 SHIPLOG_PLAIN=1
./scripts/shiplog-bootstrap-trust.sh
```

### 2. Distribute allowed signers

- Install the signer roster on each machine and point Git at it:

```
./scripts/shiplog-trust-sync.sh
```

### 3. Require signatures in policy (global or per‑environment)

- Edit `.shiplog/policy.json` and set:

```
{"version": 1, "require_signed": true, ...}
```

- Publish the policy ref and push:

```
./scripts/shiplog-sync-policy.sh
git push origin refs/_shiplog/policy/current
```

### 4. Configure clients/CI to sign

- Either rely on policy, or explicitly set `SHIPLOG_SIGN=1` on jobs.
- Configure the signing key (`git config gpg.format ssh` + `user.signingkey` for SSH).

### Per‑environment strictness

A per‑environment `require_signed` overrides the global value **in both directions**: `prod: {require_signed: true}` tightens a global `false`, and `staging: {require_signed: false}` relaxes a global `true`. The hook and the CLI use an explicit `has("require_signed")` check, so an explicit `false` is honored rather than treated as absent.

Use `deployment_requirements.<env>.require_signed=true` to require signatures only in selected environments (e.g., prod):

```
{
  "version": 1,
  "require_signed": false,
  "deployment_requirements": {
    "prod": { "require_signed": true }
  }
}
```

The CLI setup wizard supports this via `--strict-envs "prod staging"`.

## Disabling Signing

### 1. Flip policy off and publish

```
# Edit .shiplog/policy.json
{"version": "1.0.0", "require_signed": false, ...}

./scripts/shiplog-sync-policy.sh
git push --no-verify origin refs/_shiplog/policy/current   # <ref root>/policy/current
```

Per-environment entries win over the global value: an environment with `deployment_requirements.<env>.require_signed: true` (or one that inherits it from `deployment_requirements.default`) still requires signatures after the global value becomes `false`. To disable signing everywhere, also remove those entries or set them to `false`.

### 2. Clients stop signing automatically

- CLI default is unsigned; remove `SHIPLOG_SIGN=1` if you were setting it.
- Keep the trust ref: `write` still requires it even when `require_signed` is false, because every entry records the trust tip as `trust_oid` and the hook checks it (#63).

## Server Enforcement and Bootstrap

By default, the pre-receive hook requires trust and policy and enforces signatures when policy requires it. During bootstrap, you may allow missing refs:

- `SHIPLOG_ALLOW_MISSING_POLICY=1` — accept journal pushes without a policy ref; treats policy as `require_signed=false` and empty author allowlist.
- `SHIPLOG_ALLOW_MISSING_TRUST=1` — accept journal pushes when the trust ref is missing; skips `trust_oid` equality checks. If `require_signed=true`, trust is still required to verify signatures.

Set these as environment variables for the Git server user running the hook. See `contrib/README.md` for details.

## FAQ

- Do I need to rewrite existing entries when switching? No. Enforcement applies to new pushes.
- Can I sign some environments but not others? Yes. Set `deployment_requirements.<env>.require_signed=true` for selected envs (e.g., prod only). The wizard exposes this via `--strict-envs`.
- What if CI can’t sign yet? Keep `require_signed=false` until CI’s key is provisioned. You can still enforce fast‑forward and authors via policy.

## Setup Wizard

Use `git shiplog setup` to choose your strictness level and write a starter policy. The wizard supports:

- Open, Balanced, or Strict (global or per‑environment via `--strict-envs`).
- Non‑interactive mode via env (`SHIPLOG_SETUP_STRICTNESS`, `SHIPLOG_SETUP_STRICT_ENVS`, `SHIPLOG_SETUP_AUTHORS`).
- `--auto-push` to push the policy ref (and trust ref in non‑interactive Strict mode) to origin.

See docs/features/setup.md for details.
