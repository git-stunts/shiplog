# Protecting Shiplog on GitHub

This runbook walks through protecting Shiplog refs on GitHub.com using Rulesets and CI checks.

## 1) Choose a Namespace

- Custom refs (default): `refs/_shiplog/**`
  - Pros: clean separation, no branch clutter; harder to mutate accidentally.
  - Cons: GitHub UI can’t protect custom refs; Actions don’t trigger on them.

- Branch namespace: `refs/heads/_shiplog/**`
  - Pros: visible in Branches UI; Branch Rulesets apply; Actions can trigger on pushes.
  - Cons: visible “system branches”; branch cleanup bots could target them if not excluded.

See [docs/hosting/github.md](../hosting/github.md) for a detailed tradeoff.

## 2) (Optional) Migrate to Branch Namespace

```
# Dry run migration
scripts/shiplog-migrate-ref-root.sh --to refs/heads/_shiplog --dry-run

# Mirror and push
scripts/shiplog-migrate-ref-root.sh --to refs/heads/_shiplog --push

# Point Shiplog at the new root
git config shiplog.refRoot refs/heads/_shiplog
```

## 3) Import a Ruleset (Branch Namespace)

Use the GitHub UI to import one of the examples under `docs/examples/github/`:

- `ruleset-branch-shiplog-protect.json`: block deletion and non‑FF, require linear history and signatures.
- `ruleset-branch-shiplog-restricted.json`: same plus an example of restricting who can push.

GitHub → Settings → Rules → Rulesets → New ruleset → Import from JSON.

Note: `required_signatures` enforces GitHub Account‑verified signatures; it does not enforce Shiplog’s trust/allowed signers.

## 4) Add Required Status Checks (Trust and Journals)

Add GitHub Actions workflows that verify Shiplog trust and journals on pushes to `_shiplog/**` (branch namespace). Import examples:

- Trust: `docs/examples/github/workflow-shiplog-trust-verify.yml`
- Journals/Policy: `docs/examples/github/workflow-shiplog-verify.yml`

Mark these checks as required in Branch Rulesets (preferred). Classic branch protections also work, but Rulesets are the modern, more flexible path.

## 5) Custom Refs (refs/_shiplog/**)

GitHub UI Rulesets do not match custom refs. You have two options:

- Add a periodic/audit workflow that fetches and verifies Shiplog refs. Import:
  - `docs/examples/github/workflow-custom-refs-audit.yml`
- Use a GitHub App to block pushes programmatically (advanced), or switch to branch namespace.

## 6) Sanity Checks

- List remote Shiplog refs: `git ls-remote origin 'refs/_shiplog/**'`
- Delete an unwanted journal ref (if permitted): `git push origin :refs/_shiplog/journal/prod`
- Verify latest journal entry locally: `git shiplog show --json`
