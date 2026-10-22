# Shiplog Contrib

Supporting assets that help you wire Shiplog into a larger deployment workflow.

## Hooks

- `hooks/pre-receive.shiplog` – sample server-side guard that enforces (requires: git ≥2.35, jq ≥1.6, bash). Note: Uses jq instead of yq for better cross-system availability:
  - fast-forward pushes to `refs/_shiplog/journal/*` and `refs/_shiplog/anchors/*`
  - commit signatures (GPG or SSH allowed signers)
  - author allowlists pulled from the active policy
  - trust verification via the shared verifier (`scripts/shiplog-verify-trust.sh`) honoring `sig_mode` (chain|attestation) and `threshold`
  - optional trust-commit signature gate controlled by `SHIPLOG_REQUIRE_SIGNED_TRUST` (recommended `1` in production)

To install on a bare repository (run from the repository root):

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [[ ! -f "contrib/hooks/pre-receive.shiplog" ]]; then
  echo "Error: contrib/hooks/pre-receive.shiplog not found" >&2
  exit 1
fi

cp contrib/hooks/pre-receive.shiplog /path/to/bare.git/hooks/pre-receive
chmod +x /path/to/bare.git/hooks/pre-receive
echo "Hook installed successfully"
```

The hook expects the policy file to be available under `refs/_shiplog/policy/current` and will fall back to `.shiplog/policy.json` if the ref is absent.

## CI Helpers

- `scripts/shiplog-sync-policy.sh` – validates `.shiplog/policy.json` with `scripts/policy/validate.sh` (aborting on failure) and publishes it to the policy ref as a fast-forward commit (does not push). The commit is signed when `git config user.signingkey` is set or `SHIPLOG_POLICY_SIGN=1`; otherwise it is unsigned and a hint is printed. Run this from the repository root (CI or local) after merging the policy change branch, then push the ref:

```bash
./scripts/shiplog-sync-policy.sh
git push origin refs/_shiplog/policy/current
```

## Policy Templates

- `examples/policy.json` – starter policy you can copy into `.shiplog/policy.json` before publishing with the sync script (for example: `cp examples/policy.json .shiplog/policy.json`).

## Suggested Workflow

1. Update `.shiplog/policy.json` in a branch.
2. Run `scripts/shiplog-sync-policy.sh` (in CI or locally) after merge to bump `refs/_shiplog/policy/current`.
3. The pre-receive hook validates writes to the Shiplog refs using that policy.

### Optional: Relaxed Mode (no trust/policy during bootstrap)

By default, the hook requires both trust and policy refs. If you want to allow journal pushes before those are set up (for example, while bootstrapping), you can set these environment variables for the hook user:

- `SHIPLOG_ALLOW_MISSING_POLICY=1` – allow missing policy ref; defaults to an open policy (`require_signed=false`, empty author allowlist).
- `SHIPLOG_ALLOW_MISSING_TRUST=1` – allow missing trust ref; skips `trust_oid` equality checks when policy does not require signatures.

Keep `SHIPLOG_REQUIRE_SEPARATE_SIGNERS=1` unless you intentionally want to permit trust commits without an `allowed_signers` blob.

Trust-commit signature gate:

- `SHIPLOG_REQUIRE_SIGNED_TRUST=1` — require the trust commit itself to be Git‑signed (in addition to meeting threshold). Default `0`. Case‑insensitive values: `1|true|yes|on` enable; `0|false|no|off` disable.

Note: If your policy sets `require_signed=true`, the hook still requires trust to verify signatures; the relaxations only apply when signatures are not required.

Feel free to adapt these assets to match your infrastructure (GitHub, GitLab, Gitea, etc.).
