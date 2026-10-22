# 🚢🪵 Shiplog — Git‑Native Deployment Ledger

<!-- markdownlint-disable-next-line MD033 -->
<img alt="shiplog" src="https://github.com/user-attachments/assets/3c4d88fd-f46e-46f2-83ee-cc761ffdf9ef" height="500" align="right" />

Remember that 2 AM incident where no one knew which version was deployed or who changed the config? _(We've ruled out Jenkins... For now.)_

You spent hours digging through Slack threads and ephemeral CloudWatch logs trying to piece together what went wrong.

That's because your deployment logs live in dashboards you don't control, in formats you can't query, already rotated out.

**Shiplog fixes that.**

It turns your Git repo into a **cryptographically signed, append-only ledger** of every step of every deployment. It's not another workflow; Shiplog is the **deployment primitive**. Think of it like a `git commit`, but for deployments. **Keep your existing workflows!**

Run anything with:

```bash
git shiplog run <your-command>
```

Shiplog captures **stdout, stderr, exit code, timestamp, author, and reason**—everything you'd normally lose—and logs it in a signed, immutable ref right inside Git. Who/What/Where/When/Why/How; mystery solved. Deployment **logs now live with your codebase, but apart from it**. Provenance without clutter.

A built-in **allow list enforces policy at the source**: only trusted contributors can deploy, or multiple parties can sign off before a **quorum** is met. Every run is verified. Every log is auditable. Every action is permanent.

**Zero SaaS. Zero external infra. Zero guesswork. Policy as infrastructure, living right alongside your code.**

---

## Highlights

- **Git All the Way Down**: No new databases, no SaaS. All data lives under Git refs in your own repository.
- **Human & Machine-Readable**: Clean TTY views for humans and script-friendly structured output (`--json`, `--json-compact`, `--jsonl`).
- **Policy as Code**: Allow lists, per-environment requirements, and signature rules are stored and enforced directly in Git.
- **Multi-Sig Trust**: Choose between **Chain** (commit signatures) or **Attestation** (SSH -Y verify) for your required signing quorum.

---

## Quick Start

### 1. Install once on your workstation or CI runner

```bash
# Clone and set up the environment
git clone https://github.com/flyingrobots/shiplog.git "$HOME/.shiplog"
export SHIPLOG_HOME="$HOME/.shiplog"
export PATH="$SHIPLOG_HOME/bin:$PATH"

# Install dependencies (mostly jq) and verify
"$SHIPLOG_HOME/install-shiplog-deps.sh"
git shiplog --version
```

### 2. Initialize and Log

Initialize Shiplog in your repository and record your first entry.

```bash
cd your-repo
git shiplog init

# Set environment variables for the deployment context
export SHIPLOG_ENV=prod SHIPLOG_SERVICE=web

# Option A: Capture a command run
git shiplog run --service deploy --reason "canary" -- \
  kubectl rollout status deploy/web

# Option B: Manually write a journal entry (will prompt for metadata and enforce policy)
git shiplog write 

# Publish explicitly when ready (pushes journals, notes, policy, and trust refs)
git shiplog publish --env prod
```

> [!tip]  
> **Non-interactive/CI Tip**: Pass required fields via flags or environment variables to avoid prompts.
> ```bash
> SHIPLOG_ENV=prod SHIPLOG_SERVICE=web \
> git shiplog --boring --yes write --status success --reason "first ci run"
  
### 3. Browse History

Review the deployment history with clean TTY or structured output.

```bash
git shiplog ls --env prod
git shiplog show --json-compact      # Single entry, compact JSON
git shiplog export-json              # NDJSON stream for dashboards
```

---

## 🛠️ Requirements

Shiplog uses stock POSIX tooling. Ensure the following minimum versions are available:

| Tool | Minimum Version | Why it matters |
|------|-----------------|----------------|
| `git` | 2.35+ | Leans on modern refspec handling and `git ls-remote`/`update-ref`. |
| `bash` | 5.0+ | All helper scripts target `bash` (strict mode, mapfile, heredocs). |
| `jq` | 1.7+ | Policy validation and structured output. |
| `ssh-keygen` | OpenSSH 8.2+ | Required for attestation mode (`ssh-keygen -Y verify`). |

> [!tip]  
> Running `install-shiplog-deps.sh` (as done in the Quick Start) will install or upgrade `jq` for you.

---

## ⚙️ Configuration & Policy

Prefer to plan your policy first? Use the interactive config wizard.

```bash
# Prints a plan; add --apply to write policy/config
git shiplog config --interactive

# Emits example GitHub Rulesets to stdout
git shiplog config --interactive --emit-github-ruleset

# Emits a CI verify workflow to stdout
git shiplog config --interactive --emit-github-workflow
```

---

## How It Works: Ref Structure

Shiplog stores all its data in lightweight Git refs, separate from your main code branches.

- **Journals**: `refs/_shiplog/journal/<env>` (The append-only deployment history)
- **Policy**: `refs/_shiplog/policy/current` (Allow lists and rules)
- **Trust**: `refs/_shiplog/trust/root` (Root of the trusted signers/keys)
- **Notes**: Attachments (e.g., logs) under `refs/_shiplog/notes/logs` are associated with journal entries.

Policy resolution merges CLI/env overrides, local repo config, the policy ref, and working fallbacks. See [`docs/features/policy.md`](./docs/features/policy.md).

---

## Multi-Sig Trust Modes

Choose how maintainer approval is expressed. Both are supported.

### 1. Chain (`sig_mode=chain`)

- Maintainers co-sign trust commits. The policy requires a threshold of distinct signers over the same trust tree.
- **Pros**: Fully Git-native, excellent audit trail.
- **Cons**: Maintainers must sign trust commits (often via a dedicated workflow).

### 2. Attestation (`sig_mode=attestation`)

- Maintainers sign a canonical payload (tree OID + context); verified via `ssh-keygen -Y verify`.
- **Pros**: Flexible; easier to automate with SSH keys/CI.
- **Cons**: Requires additional artifact handling; precise canonicalization matters.

**Fast Pick**: Use chain if your maintainers are comfortable signing commits. Use attestation when signatures primarily come from automation or dedicated SSH keys.

> [!important]  
> See [`docs/TRUST.md`](./docs/TRUST.md) for bootstrapping and verifier details.

---

## Git Hosts & Enforcement

| Host Type | Enforcement Strategy | Recommended Ref Namespace |
|-----------|----------------------|-------------|
| GitHub.com (SaaS) | Use Branch/Push Rulesets + Required Status Checks. | SaaS does not run custom server hooks. Prefer a branch namespace (`refs/heads/_shiplog/**`) so rules apply. |
| Self-hosted (GH Enterprise, GitLab, Gitea) | Install the pre-receive hook (`contrib/hooks/pre-receive.shiplog`) to enforce policy/trust server-side. | The default ref namespace (refs/_shiplog/**) is fine. Switching namespaces is supported via `scripts/shiplog-migrate-ref-root.sh` and `git config shiplog.refRoot`. |

---

## What’s Live vs Roadmap

### Live Now

- Journals (append-only by env) with human + JSON views.
- Policy/trust refs; allow lists by env; threshold verification.
- Two trust modes (chain, attestation) + shared verifier script.
- Core commands: `run`, `write`, `append`, `ls`, `show`, `export-json`, `publish`.
- Hosting docs: GitHub SaaS guidance and self-hosted hooks; enforcement matrix.
- Dockerized cross-distro tests and CI linting/validation.

### Roadmap (Short-term)

- Setup Questionnaire improvements and emitters (Rulesets + CI snippets per host).
- Attestation E2E fixtures across distros.
- Flip CI linters to blocking after baseline cleanup.

---

## Contributing & Tests

- Please read [`AGENTS.md`](./AGENTS.md) before running tests or editing hooks/scripts.
- **Run tests inside Docker**: `make test` (optionally: `TEST_TIMEOUT_SECS=180 make test`).

> [!warning]
> Do not run Bats directly on your host!
> Shiplog tests perform destructive Git operations, and it's essential they run in isolation to avoid clobbering your host's Git setup.

---

## FAQ

| Question | Answer |
|----------|--------|
| What is AJV and why does CI mention it? | AJV is a fast JSON Schema validator for Node.js. CI uses it to validate `examples/policy.json`, the fixtures under `test/fixtures/policy/valid/`, and `.shiplog/policy.json` when present against `examples/policy.schema.json`, and asserts that the fixtures under `test/fixtures/policy/invalid/` are rejected. Locally, `git shiplog policy validate` performs `jq` checks. |
|Can Shiplog enforce policy on GitHub.com (SaaS)? | Yes, but via **Branch/Push Rulesets + Required Checks** and a branch namespace for Shiplog refs, as SaaS doesn't run custom server hooks. |
| Which trust mode should I use? | **Chain** if maintainers can sign commits; **attestation** if signatures come from automation/SSH. Both are fully supported. |

## License

MIT • © J. Kirby Ross • [flyingrobots](https://github.com/flyingrobots)

_Jenkins was not harmed in the making of this project._
