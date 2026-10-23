# Config Wizard (Interactive Questionnaire)

## Summary

`git shiplog config` helps new users pick sensible, host‑aware defaults. It asks a short set of questions (or reads a JSON answers file) and prints a recommended plan. With `--apply`, it writes a starter `.shiplog/policy.json` and sets a couple of repo configs. It never pushes by itself.

## Usage

```bash
# Interactive TTY questionnaire
git shiplog config --interactive            # or: --wizard

# Apply the recommended settings locally (policy file + repo config)
git shiplog config --interactive --apply

# Non-interactive: provide answers via JSON
cat > answers.json <<'JSON'
{"host":"github.com","ref_root":"refs/heads/_shiplog","threshold":2,"sig_mode":"attestation","require_signed":"prod-only","autoPush":0}
JSON
git shiplog config --answers-file answers.json --apply
 
# Emit GitHub examples (prints to stdout; does not write files)
git shiplog config --interactive --emit-github-ruleset      # Branch Rulesets JSON
git shiplog config --interactive --emit-github-workflow     # Verify workflow YAML
```

## What It Does

- Detects your Git host from `remote.origin.url` to choose good defaults.
- Asks about:
  - Git host (GitHub.com, GitLab.com, Bitbucket.org, self-hosted)
  - Ref namespace (custom `refs/_shiplog/**` vs branch `refs/heads/_shiplog/**`)
  - Team size → threshold hint (1, 2, or 3)
  - Signing mode (chain vs attestation). The default is `attestation` when the threshold is above 1. `chain` supports threshold 1 only, and the wizard rejects `chain` with a higher threshold (decision D1, `docs/TRUST.md`). An unknown value is rejected by name.
  - Require signatures (none, prod-only, or global)
  - Auto‑push during deploys (enable/disable)
- Prints a compact plan JSON. Example:

```json
{"host":"github.com","ref_root":"refs/heads/_shiplog","sig_mode":"attestation","threshold":2,"require_signed":"prod-only","autoPush":0}
```

## Apply Mode

- With `--apply`, the wizard:
  - Sets `git config shiplog.refRoot <ref>`.
  - Sets `git config shiplog.autoPush <true|false>`.
  - Writes `.shiplog/policy.json` reflecting your signing choice (global or prod‑only).
- It does not create or push trust/policy refs automatically; see “Next steps” below.

## Next Steps (always printed)

- Bootstrap trust (choose `sig_mode` and `threshold`): see `docs/TRUST.md`.
- On SaaS (e.g., GitHub.com), add Required Checks and (if using branch namespace) import a Ruleset: see `docs/hosting/matrix.md` and `docs/hosting/github.md`.
- If you disabled auto‑push, finish with `git shiplog publish` at the end of your deploy.

## Notes

- The existing `git shiplog setup` command still provides a non-interactive way to materialize a policy and (optionally) bootstrap trust. Use `config` when you want guidance; use `setup` when you already know exactly what you want.
- `--apply` is local; nothing is pushed. Use `git shiplog publish --policy` to push the policy ref later if desired.
