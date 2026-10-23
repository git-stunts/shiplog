# 🚢🪵 Shiplog — Git‑Native Deployment Ledger

Your deployment history belongs next to your code. Shiplog turns deployments, rollbacks, hotfixes, and ops events into immutable Git records — human‑readable for people, structured for machines.

—

## Highlights

- Git all the way down: no new databases, no SaaS; data lives under refs in your repo.
- Human + JSON: clean TTY views and script‑friendly output (`--json`, `--json-compact`, `--jsonl`).
- Policy as code: allowlists, per‑env requirements, and signature rules stored in Git.
- Multi‑sig trust: choose chain (commit signatures) or attestation (SSH `-Y verify`) quorum.
- Opt‑in publish: write locally, publish when you decide; avoids noisy hooks mid‑deploy.

—

## Quick Start

Install once on your workstation or CI runner:

```bash
git clone https://github.com/flyingrobots/shiplog.git "$HOME/.shiplog"
export SHIPLOG_HOME="$HOME/.shiplog" && export PATH="$SHIPLOG_HOME/bin:$PATH"
"$SHIPLOG_HOME/install-shiplog-deps.sh"
git shiplog --version
```

Initialize in your repo and record the first entry:

```bash
cd your-repo
git shiplog init
export SHIPLOG_ENV=prod SHIPLOG_SERVICE=web
git shiplog write    # prompts for metadata; enforces policy/allowlists

# Publish explicitly when ready (journals + notes)
git shiplog publish --env prod
```

### Requirements

Shiplog leans on the standard Git toolchain. Verify these are available first:

| Tool | Minimum Version | Why it matters |
|------|-----------------|----------------|
| git  | 2.35+ | Recent Git releases handle the refspecs and fast-forward checks Shiplog performs. |
| bash | 5.0+ | Helper scripts run under bash with `set -euo pipefail`, arrays, and `mapfile`. |
| jq   | 1.7+ | Policy validation, JSON exports, and the CLI’s structured output require jq – run `install-shiplog-deps.sh` to install it. |
| ssh-keygen | OpenSSH 8.2+ (for `ssh-keygen -Y verify`) | Needed when using attestation trust mode or verifying SSH signatures. |

`scripts/install-shiplog.sh` clones Shiplog under `$SHIPLOG_HOME` and invokes `install-shiplog-deps.sh`, which provisions jq. Match or exceed these versions on CI runners (see Dockerfile matrix) to avoid surprises.

Both `scripts/install-shiplog.sh` and `scripts/uninstall-shiplog.sh` refuse to reset or remove a directory unless it is strictly inside an allowed base (`SHIPLOG_ALLOWED_BASES`, default `$HOME:/opt/shiplog`), is not a symlink, and is a Shiplog checkout (`bin/git-shiplog` present and `remote.origin.url` matching `SHIPLOG_REPO_URL`). `--dry-run` runs the same checks and exits non-zero on refusal. The uninstaller's `--force-unsafe` skips only the checkout check.

Prefer a plan first? Use the config wizard:

```bash
git shiplog config --interactive        # Prints a plan; add --apply to write policy/config
git shiplog config --interactive --emit-github-ruleset    # Prints example GitHub Rulesets
git shiplog config --interactive --emit-github-workflow   # Prints a CI verify workflow
```

Browse history (human + JSON):

```bash
git shiplog ls --env prod
git shiplog show --json-compact     # single entry, compact JSON
git shiplog export-json             # NDJSON stream for dashboards
```

Wrap and capture a run:

```bash
git shiplog run --service deploy --reason "canary" -- \
  kubectl rollout status deploy/web
# Prints a minimal confirmation (default "🪵"); set SHIPLOG_CONFIRM_TEXT to override
```

Non‑interactive/CI tip: pass required fields via flags or env to avoid prompts.

```bash
SHIPLOG_ENV=prod SHIPLOG_SERVICE=web \
  git shiplog --boring --yes write --status success --reason "first run"

printf '{"checks":{"smoke":"green"}}' | \
  git shiplog append --service web --status success --json -
```

—

## How It Works

- Refs (where data lives)
  - Journals: `refs/_shiplog/journal/<env>` (append‑only, fast‑forward)
  - Policy:   `refs/_shiplog/policy/current`
  - Trust:    `refs/_shiplog/trust/root`
- Policy resolution: merges CLI/env overrides, repo config, policy ref, and working fallback. See docs/features/policy.md.
- Notes: attachments (e.g., logs) under `refs/_shiplog/notes/logs` are associated with entries.

—

## Multi‑Sig Trust Modes

Choose how maintainer approval is expressed. Both are supported; pick what fits your workflow.

- Chain (sig_mode=chain)
  - Maintainers co‑sign trust commits; threshold distinct signers over the same trust tree.
  - Pros: fully Git‑native, great audit trail.
  - Cons: maintainers sign trust commits (often via a maintainer workflow).

- Attestation (sig_mode=attestation)
  - Maintainers sign a canonical payload (tree OID + context); verified via `ssh-keygen -Y verify`.
  - Pros: flexible; easy to automate with SSH keys.
  - Cons: additional artifact handling; precise canonicalization matters.

Fast pick: chain if maintainers can sign commits; attestation when signatures come from automation/SSH. See docs/TRUST.md for bootstrapping and verifier details.

—

## Git Hosts & Enforcement

- GitHub.com (SaaS): no custom server hooks. Protect Shiplog refs with Branch/Push Rulesets and Required Status Checks. For SaaS, prefer a branch namespace (`refs/heads/_shiplog/**`) so rules apply. See docs/hosting/github.md.
- Self‑hosted (GH Enterprise, GitLab self‑managed, Gitea, Bitbucket DC): install the pre‑receive hook (`contrib/hooks/pre-receive.shiplog`) to enforce policy/trust server‑side.
- Matrix & recipes: docs/hosting/matrix.md summarizes capabilities and recommended configs.

Switching namespaces (custom refs ↔ branch namespace) is supported via scripts/shiplog-migrate-ref-root.sh and `git config shiplog.refRoot`.

—

## Publish vs Auto‑push

To avoid tripping hooks mid‑deploy, Shiplog separates writing from publishing.

- Precedence: command flags > `git config shiplog.autoPush` > environment/default.
- Publish explicitly when ready:

```bash
git shiplog publish [--env <env>|--all] [--no-notes] [--policy] [--trust]
```

Examples:
- Disable auto‑push per repo: `git config shiplog.autoPush false` then publish at the end of a deploy: `git shiplog publish --env prod`.
- Force a one‑off publish: `git shiplog write --push` (overrides config).

—

## What’s Live vs Roadmap

Live now
- Journals (append‑only by env) with human + JSON views.
- Policy/trust refs; allowlists by env; threshold verification.
- Two trust modes (chain, attestation) + shared verifier script.
- Commands: `run`, `write`, `append`, `ls`, `show`, `export-json`, `publish`.
- Hosting docs: GitHub SaaS guidance and self‑hosted hooks; enforcement matrix.
- Dockerized cross‑distro tests; CI lint (shell/markdown/yaml); policy validate (CLI + CI schema).

Roadmap (short‑term)
- Setup Questionnaire improvements and emitters (Rulesets + CI snippets per host).
- Attestation E2E fixtures across distros.
- Flip CI linters to blocking after baseline cleanup.

—

## Upgrading

See RELEASE_NOTES.md for version‑specific guidance (e.g., namespace changes, publish defaults, or trust signature gates like `SHIPLOG_REQUIRE_SIGNED_TRUST`).

### Upgrading attestation signatures (legacy → canonical)

Older experimental builds used a “full tree” attestation payload that included the commit’s tree OID, which created a circular dependency when signatures were stored under `.shiplog/trust_sigs/`. Shiplog now uses a canonical “base tree” payload (default) that excludes the `trust_sigs` directory:

```
shiplog-trust-tree-v1
<base_tree_oid_of(trust.json + allowed_signers)>
<trust_id>
<threshold>
```

Compatibility:
- The hook/verifier accept both modes. Set `SHIPLOG_ATTEST_BACKCOMP=1` to allow legacy signatures during a transition.
- To prefer a specific mode: `SHIPLOG_ATTEST_PAYLOAD_MODE=base|full` (default `base`).
- We recommend re‑signing with the base payload going forward. See TRUST.md for the exact `ssh-keygen -Y sign`/`-Y verify` commands.

—

## Contributing & Tests

- Please read AGENTS.md before running tests or editing hooks/scripts.
- Run tests inside Docker: `make test` (optionally: `TEST_TIMEOUT_SECS=180 make test`). Do not run Bats directly on your host.

—

## FAQ

- What is AJV and why does CI mention it?
  - AJV is a fast JSON Schema validator for Node.js. CI uses it to validate `.shiplog/policy.json` against `examples/policy.schema.json`. Locally, `git shiplog policy validate` performs jq‑based checks without Node.

- Can Shiplog enforce policy on GitHub.com (SaaS)?
  - SaaS doesn’t run custom server hooks; use Branch/Push Rulesets + Required Checks and a branch namespace so rules apply to Shiplog refs. See docs/hosting/github.md and docs/hosting/matrix.md.

- Should I use chain or attestation for multi‑sig?
  - Chain if maintainers can sign commits; attestation if signatures come from automation/SSH. Both are supported.

—

## License

MIT © J. Kirby Ross (@flyingrobots)

Jenkins was not harmed in the making of this project.

—

## FAQ

- What is AJV and why does CI mention it?
  - AJV is a fast JSON Schema validator for Node.js. We use it in CI to validate `.shiplog/policy.json` (and examples) against `examples/policy.schema.json` so malformed policies are caught early. Locally, `git shiplog policy validate` performs jq‑based structural checks without requiring Node.

- Can Shiplog enforce policy on GitHub.com (SaaS)?
  - GitHub SaaS does not run custom server hooks. Use Branch/Push Rulesets and Required Status Checks to protect a branch namespace (e.g., `refs/heads/_shiplog/**`) and run verification in CI. For self‑hosted Git, install the pre‑receive hook for server‑side enforcement. See `docs/hosting/matrix.md` and `docs/hosting/github.md`.

- Should I use chain or attestation for multi‑sig?
  - Chain uses signed Git commits; attestation uses `ssh-keygen -Y verify` over a canonical payload. Chain is simplest when maintainers can sign commits; attestation is great when signatures are produced by automation using SSH keys. Both are supported; pick during setup and document in TRUST.md.
