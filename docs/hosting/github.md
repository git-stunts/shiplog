# GitHub and Shiplog Refs

This guide explains how Shiplog’s Git refs work on GitHub, why you don’t see them in the web UI, and how to protect them using Rulesets.

See also: Git Hosting Enforcement Matrix (docs/hosting/matrix.md) for a side‑by‑side of SaaS vs self‑hosted capabilities and recommended configurations.

## Where Shiplog Stores Data

- Shiplog writes commits under custom refs, not branches or tags:
  - Journals: `refs/_shiplog/journal/<env>` (e.g., `prod`)
  - Anchors:  `refs/_shiplog/anchors/<env>`
  - Policy:   `refs/_shiplog/policy/current`
  - Trust:    `refs/_shiplog/trust/root`
  - Notes:    `refs/_shiplog/notes/logs` (attached logs)
- All of them hang off one ref root (`refs/_shiplog` by default). `SHIPLOG_REF_ROOT` or
  `git config shiplog.refRoot` moves every one of them together; `git shiplog refs root show`
  prints the effective root, where it came from (env, config or default) and each derived ref.

GitHub’s web UI only shows branches (`refs/heads/*`) and tags (`refs/tags/*`), so these custom refs won’t appear in the Branches/Tags pages. They do exist on the remote; you can list them with CLI commands.

## Viewing Shiplog Refs on GitHub Repos

- List remote Shiplog refs:
  - `git ls-remote origin 'refs/_shiplog/**'`
- List local Shiplog refs:
  - `git show-ref 'refs/_shiplog/*'`
- Inspect a commit referenced by those refs in the GitHub web UI:
  - Copy the SHA from `ls-remote` and open: `https://github.com/<owner>/<repo>/commit/<SHA>`

## Protecting Shiplog Refs on GitHub

On GitHub.com there are no server-side hooks (like `pre-receive`) for public SaaS repos. Use Rulesets to protect pushes instead.

### Option A — Protect Custom Refs via Push Rulesets (if supported)

Some plans allow rulesets targeting arbitrary ref names. Use a “push” ruleset that includes `refs/_shiplog/**`.

- Target: `push`
- Conditions:
  - `ref_name.include = ["refs/_shiplog/**"]`
- Rules to enable:
  - `deletion`                 (block deletes)
  - `non_fast_forward`         (block force pushes)
  - `creation` and `update`    (ensure pushes go through the ruleset)
  - `required_linear_history`  (keeps history straight)
  - Optional: `required_signatures` (GitHub verification; see caveat below)

Validate:

- Try deleting a journal ref: `git push origin :refs/_shiplog/journal/prod` → should be rejected with a ruleset message.

### Option B — Use Branch Namespace to Leverage Branch Rules

If your plan cannot protect arbitrary refs, move Shiplog refs under branches so Branch Rules can protect them.

- New layout (examples):
  - `refs/heads/_shiplog/journal/<env>`
  - `refs/heads/_shiplog/anchors/<env>`
  - `refs/heads/_shiplog/policy/current`
  - `refs/heads/_shiplog/trust/root`
  - `refs/heads/_shiplog/notes/logs`
- Then create a Branch ruleset targeting `_shiplog/**` with the same rules: block deletion, non-FF, require linear history.

Migration sketch:

1) Mirror current tips to the new namespace and push them (the helper handles every ref kind, nested names included, and records the new root in `git config shiplog.refRoot`):
   - `git shiplog refs migrate --to refs/heads/_shiplog --dry-run` (preview)
   - `git shiplog refs migrate --to refs/heads/_shiplog --push`
   - Avoid hand-rolled `git for-each-ref 'refs/_shiplog/*'` loops: `*` does not cross `/`, so `journal/<env>`, `policy/current`, `trust/root` and `notes/logs` are skipped.
2) Make sure every client uses the new root: the helper sets `git config shiplog.refRoot refs/heads/_shiplog` in the repo it ran in; other clones set it too, or export `SHIPLOG_REF_ROOT=refs/heads/_shiplog` (env wins over config).
3) Update CI/automation to use the new ref names. Self-hosted servers running `contrib/hooks/pre-receive.shiplog` must export `SHIPLOG_REF_ROOT=refs/heads/_shiplog` in the hook environment, or the hook enforces nothing under the branch namespace.

### Worked example: this repository (ROADMAP G9)

`git-stunts/shiplog` runs Option B on itself:

- Trust (`_shiplog/trust/root`), policy (`_shiplog/policy/current`) and the `ci` and `release` journals live under `refs/heads/_shiplog/**`; every clone sets `git config shiplog.refRoot refs/heads/_shiplog`.
- Ruleset [`ruleset-branch-shiplog-append-only.json`](../examples/github/ruleset-branch-shiplog-append-only.json) (active, no bypass): deletion and non-fast-forward updates are blocked for everyone.
- Ruleset [`ruleset-branch-shiplog-writers.json`](../examples/github/ruleset-branch-shiplog-writers.json) restricts creation and updates to admins and deploy keys. It is imported but **disabled** here: a repository ruleset cannot list the GitHub Actions app as a bypass actor, and deploy keys are disabled for the organization, so no CI identity could write. Enable it once CI pushes with a deploy key (or another bypassable identity).
- Until then CI appends with the workflow's `GITHUB_TOKEN` (`contents: write`), and the `shiplog-verify` job in `.github/workflows/ci.yml` is a required status check on `main`: it verifies the trust chain, validates the policy ref and checks every `ci` entry's author against the policy allowlist, so an entry from anyone else turns every pull request red.
- Import a ruleset: Settings → Rules → Rulesets → New ruleset → Import a ruleset, or `gh api -X POST repos/OWNER/REPO/rulesets --input <file>.json`.

## Switching Ref Root (Toggle Branch vs Custom Refs)

Teams can switch between custom refs (`refs/_shiplog`) and branch namespace (`refs/heads/_shiplog`) per repo. Use the migration helper and update your config.

### One‑shot migration with the helper

```
# Dry run: see what would be mirrored
scripts/shiplog-migrate-ref-root.sh --to refs/heads/_shiplog --dry-run

# Mirror and push the new refs
scripts/shiplog-migrate-ref-root.sh --to refs/heads/_shiplog --push

# (Optional) Remove old refs after mirroring
scripts/shiplog-migrate-ref-root.sh --to refs/heads/_shiplog --remove-old --push
```

`git shiplog refs migrate ...` wraps the same script. The helper mirrors journals, anchors, policy, trust and notes, and writes `git config shiplog.refRoot <new root>` for the repository it ran in. Other clones need the same setting, or the per-process override:

```
git config shiplog.refRoot refs/heads/_shiplog
# or per-process (takes precedence over git config):
export SHIPLOG_REF_ROOT=refs/heads/_shiplog
```

Check what is in effect with `git shiplog refs root show` (add `--json` for scripts).

To switch back to custom refs, mirror in reverse:

```
scripts/shiplog-migrate-ref-root.sh --from refs/heads/_shiplog --to refs/_shiplog --push
```

Self-hosted servers: the pre-receive hook learns the root only from its own environment. Export `SHIPLOG_REF_ROOT` there to match the clients (see `contrib/README.md`).

### Update protection

- Branch namespace: use Branch Rulesets targeting `_shiplog/**`.
- Custom refs: use a Push Ruleset on `refs/_shiplog/**` (if supported), or a required status check that validates Shiplog policy.

## Signatures and Allowed Authors (Caveat)

- GitHub’s `required_signatures` enforces “Verified” signatures tied to users’ GitHub accounts. This is not the same as Shiplog’s trust roster (`allowed_signers`).
- To enforce Shiplog policy (allowed authors, trust-based signatures) on GitHub.com:
  - Use a required status check from CI or a GitHub App that validates pushes against the policy and trust refs, and fails the check when violations occur.
  - Self-hosted Git servers can enforce these checks in `pre-receive` hooks.

## Quick Commands and Checks

- Compare local vs remote journals:
  - `git rev-parse refs/_shiplog/journal/prod`
  - `git ls-remote origin refs/_shiplog/journal/prod`
- Force-refresh local Shiplog refs to match origin (safe for local only):
  - `git fetch origin '+refs/_shiplog/*:refs/_shiplog/*'`
- Show latest entry (human): `git shiplog show`
- JSON only: `git shiplog show --json` (or `--json-compact`)
- NDJSON of all entries: `git shiplog export-json`

## Troubleshooting

- “I don’t see Shiplog refs on GitHub”: expected — they’re custom refs. Use CLI or the GitHub API (`/git/matching-refs/refs/_shiplog/`).
- “Ruleset doesn’t block deletions”: ensure the ruleset targets `push` and includes `refs/_shiplog/**` (not `refs/heads/_shiplog/**`). Branch Target rulesets only protect `refs/heads/*`.
- “Non‑FF still allowed”: enable both `non_fast_forward` and `required_linear_history` in the ruleset.

## Resources

- Ruleset JSON (branch namespace `_shiplog/**`):
  - docs/examples/github/ruleset-branch-shiplog-protect.json
  - docs/examples/github/ruleset-branch-shiplog-restricted.json
- Workflows:
  - Trust verify: docs/examples/github/workflow-shiplog-trust-verify.yml
  - Journal/policy verify: docs/examples/github/workflow-shiplog-verify.yml
