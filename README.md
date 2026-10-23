# 🚢🪵 Shiplog

**Simple tools, in the repo.** A deployment ledger made of `git` and `bash`. No service. No database. No logger. No dashboard that rotates your evidence out at 3 a.m. Just refs.

```bash
git shiplog run --service web --reason "canary" -- kubectl rollout status deploy/web
```

Ship it. Then prove you shipped it.

---

## Dry dock

> [!IMPORTANT]
> **Shiplog is in dry dock.** A full audit on 2026-10-21 found that the hull was sound and the locks were not: the storage layer (refs, trailers, compare-and-swap updates, fast-forward checks) passed review; the *enforcement* layer (trust quorum, signature verification, the pre-receive hook) had P0 defects. The locks have since been rebuilt (roadmap G2 and G3): one shared trust verifier, prior-roster checks, a key-based N-of-M quorum, refused ref deletion and signed policy updates, proven by the adversarial suite `test/27_trust_adversarial.bats`, which now blocks CI. Still open: a few policy, ref-root and CLI issues, dogfooding (G9) and the 0.5.0 release (G10).
>
> **Use Shiplog today as a ledger.** Do not make it your only access-control system until it leaves dry dock.
>
> Plan: [`ROADMAP.md`](./ROADMAP.md) · live status: [tracking issue #155](https://github.com/git-stunts/shiplog/issues/155) · what's wrong, in detail: issues labeled [`audit-2026-10`](https://github.com/git-stunts/shiplog/issues?q=label%3Aaudit-2026-10). This section flips to "seaworthy" with release 0.5.0 (G10): every `audit-2026-10` issue closed and `test/27_trust_adversarial.bats` blocking and green. Not before.

---

## The 2 a.m. problem

Something is on fire. Nobody knows what's deployed. The deploy bot posted to a Slack channel that got archived. CloudWatch kept 7 days of logs and this started 9 days ago. Jenkins says "SUCCESS" in green letters about a build nobody can find.

Your deployment history lives in systems you don't control, in formats you can't `grep`, with retention you didn't choose.

**Shiplog puts it in the one place that already has retention, replication, signatures, and `grep`: your Git repository.**

Every deployment becomes a commit under `refs/_shiplog/journal/<env>`: who, what, where, when, why, how, exit code, and the full log as a Git note. It's `git log` for the thing `git log` never told you — what actually happened after you pushed.

---

## Simple tools, in the repo

The whole philosophy:

| Instead of | Shiplog uses | Because |
|---|---|---|
| A deploy-tracking SaaS | Git refs | Your repo is already replicated to every clone and every host |
| A database | Commits with a JSON trailer | `jq` is a database. Fight me |
| A log aggregator | Git notes | Logs attached to the exact deployment, forever, offline |
| A permissions service | A policy file in a ref | Policy is code. Code is reviewed |
| A signing service | SSH keys you already have | `ssh-keygen -Y` has been there since OpenSSH 8.2 |
| An agent on every box | `bash` | It's already there. It's always been there |

Dependencies: `git`, `bash`, `jq`, `ssh-keygen`. If your deploy host can run `git push`, it can run Shiplog. If the vendor goes under, your ledger doesn't.

---

## Quick start

### Install (once per workstation or runner)

```bash
git clone https://github.com/git-stunts/shiplog.git "$HOME/.shiplog"
export SHIPLOG_HOME="$HOME/.shiplog"
export PATH="$SHIPLOG_HOME/bin:$PATH"
"$SHIPLOG_HOME/install-shiplog-deps.sh"   # installs jq if you don't have it
git shiplog --version
```

### Record a deployment

```bash
cd your-repo
git shiplog init

# Once per repo: name the maintainers and their SSH keys (the trust roster).
# Every entry records which roster it was written under, so writes need one.
"$SHIPLOG_HOME/scripts/shiplog-bootstrap-trust.sh"   # interactive; flags in docs/TRUST.md

export SHIPLOG_ENV=prod SHIPLOG_SERVICE=web

# Wrap the real command. stdout, stderr, exit code, timing: all captured.
git shiplog run --reason "canary 5%" -- kubectl rollout status deploy/web

# Or write an entry by hand (prompts for anything you didn't pass).
git shiplog write --status success --reason "manual hotfix, ticket OPS-421"

# With a remote, entries push as they are written. To hold them until the
# deploy is done: git config shiplog.autoPush false (or --no-push), then
git shiplog publish --env prod      # journal + notes; --policy / --trust for those refs
```

### Read it back

```bash
git shiplog ls --env prod              # table for humans
git shiplog show                       # latest entry, full detail + attached log
git shiplog show --json-compact        # same, for machines
git shiplog export-json > deploys.ndjson   # one JSON object per line, for dashboards
```

> [!TIP]
> **CI / non-interactive:** pass everything as flags or env and add `--boring --yes`. No prompts, no colors, no questions.
>
> ```bash
> SHIPLOG_ENV=prod SHIPLOG_SERVICE=web \
>   git shiplog --boring --yes write --status success --reason "ci run $GITHUB_RUN_ID"
> ```

---

## How it works

Shiplog never touches your branches. Everything lives in its own ref namespace:

| Ref | Holds |
|---|---|
| `refs/_shiplog/journal/<env>` | The append-only ledger for one environment. One commit per deployment. |
| `refs/_shiplog/notes/logs` | Captured output, attached to journal commits as Git notes. |
| `refs/_shiplog/policy/current` | `policy.json`: author allowlist, per-env signing rules. |
| `refs/_shiplog/trust/root` | `trust.json` + `allowed_signers`: who the maintainers are and their keys. |
| `refs/_shiplog/anchors/<env>` | Optional markers ("this is what's live") for replay tooling. |

A journal commit looks like this:

```text
Deploy: web → prod/us-east-1/prod-a/web
Reason: canary 5% (OPS-421)
Status: SUCCESS (0s) @ 2026-10-22T14:03:11Z
Seq:    17 (parent 8f1c2d0, trust a91e4b7, anchor (none))
Author: deploy-bot@example.com
Repo:   3b5e9c1…

---  # structured trailer for machines
{"version":1,"env":"prod","seq":17,"status":"success",
 "what":{"service":"web","artifact":null,"repo_head":"3b5e9c1…"},
 "where":{"env":"prod","region":"us-east-1","cluster":"prod-a","namespace":"web"},
 "why":{"reason":"canary 5%","ticket":"OPS-421"},
 "run":{"cmd":"kubectl rollout status deploy/web","exit_code":0,"duration_s":42,"log_attached":true,…},
 "journal_parent":"8f1c2d0…","trust_oid":"a91e4b7…",…}
```

Humans read the top. Machines read the bottom. `seq` and `journal_parent` chain entries so a gap or rewrite is detectable; `trust_oid` pins which roster was current when the entry was written. Updates use `git update-ref` with an expected old value, so two runners racing to append cannot clobber each other. One wins; the other's update is refused, and re-running it appends on top with the next `seq`.

Full trailer schema: [`docs/reference/json-schema.md`](./docs/reference/json-schema.md).

---

## Policy and trust

Two files, both in refs, both reviewed like code.

**Policy** (`.shiplog/policy.json`) says who may write to which environment and whether entries must be signed:

```json
{
  "version": "1.0.0",
  "require_signed": false,
  "authors": { "default_allowlist": ["deploy-bot@example.com", "oncall@example.com"] },
  "deployment_requirements": { "prod": { "require_signed": true } }
}
```

**Trust** (`trust.json` + `allowed_signers`) says who the maintainers are, their SSH public keys, and how many of them must approve a change to the roster itself.

```bash
git shiplog setup --strictness balanced     # guided: open / balanced / strict
git shiplog policy show --json
git shiplog policy validate
git shiplog trust show
```

Entries are signed with the SSH key you already use for Git (`SHIPLOG_SIGN=1`). No new PKI, no new accounts, no signing service with a status page.

> [!NOTE]
> **Rebuilt in the audit (see [Dry dock](#dry-dock)):** the *server-side* verification of these rules. Trust changes are verified against the *previous* roster, the N-of-M quorum counts distinct, unrevoked maintainer keys, ref deletion is refused, and when a trust ref exists, policy changes must be signed by a current maintainer. Details: [`docs/TRUST.md`](./docs/TRUST.md).

---

## Where does enforcement actually run?

Honest answer, because the hosting world is split in two:

| You host on | Server-side hooks? | What enforces Shiplog policy |
|---|---|---|
| **Self-hosted** Git (GitLab, Gitea, Gerrit, GHE server, bare repo over SSH) | Yes | Install [`contrib/hooks/pre-receive.shiplog`](./contrib/hooks/pre-receive.shiplog). Set `receive.denyDeletes`. Policy, trust and fast-forward rules are checked on every push. |
| **GitHub.com / SaaS** | No custom hooks | Move Shiplog refs under `refs/heads/_shiplog/**` so **branch rulesets** apply, and run `git shiplog verify` as a **required status check**. Templates in [`docs/examples/github/`](./docs/examples/github/). |

Either way the ledger is the same bytes. Only the bouncer changes. The full matrix: [`docs/hosting/matrix.md`](./docs/hosting/matrix.md).

---

## Commands

| Command | What it does |
|---|---|
| `git shiplog init` | Configure the repo (fetch refspecs; nothing pushed) |
| `git shiplog run [-- cmd…]` | Run a command; record outcome, timing and log |
| `git shiplog write [ENV]` | Record an entry by hand |
| `git shiplog append --json '{…}'` | Append an entry from structured input (automation) |
| `git shiplog ls [--env E]` | List entries |
| `git shiplog show [SHA] [--json]` | One entry with its attached log |
| `git shiplog export-json` | NDJSON stream of a journal |
| `git shiplog verify [ENV]` | Check authors and signatures against policy |
| `git shiplog publish [--env E] [--all] [--policy] [--trust]` | Push Shiplog refs (and nothing else) |
| `git shiplog policy show\|validate\|require-signed` | Inspect and edit policy |
| `git shiplog trust show\|sync` | Inspect the roster; export `allowed_signers` |
| `git shiplog setup` / `config --interactive` | Wizards: strictness level, host-aware plan, `--apply` |
| `git shiplog refs root show\|set` / `refs migrate` | Switch between `refs/_shiplog` and `refs/heads/_shiplog` |

Everything accepts `--boring` (no color, no prompts) and `--yes`. Full reference: [`docs/features/command-reference.md`](./docs/features/command-reference.md). Environment variables: [`docs/reference/env.md`](./docs/reference/env.md).

---

## Requirements

| Tool | Minimum | Why |
|---|---|---|
| `git` | 2.35 | `update-ref` with expected value, modern refspecs, SSH signing |
| `bash` | 5.0 | arrays, `mapfile`, strict mode. macOS: `brew install bash` |
| `jq` | 1.6 | trailer construction and policy validation |
| `ssh-keygen` | OpenSSH 8.2 | `-Y sign` / `-Y verify` / `-Y find-principals` |

That's the list. If you were hoping for a Helm chart, we have some bad news and some good news, and they're the same news.

---

## FAQ

**Is this a CD tool?**
No. Ship it however you ship it. Shiplog records that you did, and what happened. It's the ship's log, not the ship.

**Why not just tag releases?**
Tags say what was *meant* to ship. Shiplog says what *did*, including the 3 failed attempts, the rollback, the exit codes, and who was holding the keyboard.

**Why Git refs instead of a database?**
Because you already back them up, replicate them, access-control them, and sign them. Also because "the deploy database is down" is a sentence nobody should have to say during an incident.

**Does it work offline / in an air-gapped environment?**
Yes. It's `git` and `bash`. Push when you can.

**Can an attacker rewrite history?**
Journals are fast-forward-only and chained by `seq`/`journal_parent`, so a rewrite is detectable. Whether it's *prevented* depends on your host's enforcement: the pre-receive hook on self-hosted Git, rulesets and a required check on SaaS. That layer was rebuilt in the audit and the adversarial suite now runs blocking in CI, but we are not going to call it bulletproof until it leaves [dry dock](#dry-dock) with 0.5.0.

**Does Shiplog use Shiplog?**
Not yet, and yes, we heard you. Roadmap goal G9 makes this repo record its own CI runs and releases in its own ledger, on GitHub.com, under the branch namespace, with `verify` as a required check. A deploy ledger that doesn't log its own deploys would be a bit much.

**What's the `--boring` flag?**
Turns off colors and prompts. Named for how deploys should feel.

**Why "Shiplog"?**
Because "ship it" is a verb, a log is a noun, and sailors have been writing down what happened on watch for about 4,000 years longer than SaaS has existed. Ship happens. Log it.

---

## Contributing and tests

```bash
make test        # builds the Docker image and runs the whole Bats suite inside it
```

> [!WARNING]
> **Never run Bats directly on your machine.** The suite creates and destroys Git repositories, remotes and refs. It runs in Docker on Debian, Ubuntu, Alpine and Arch so that "works on my machine" is a reproducible claim and not a feeling. See [`AGENTS.md`](./AGENTS.md) and [`test/README.md`](./test/README.md).

Plan of record: [`ROADMAP.md`](./ROADMAP.md). Pick an issue from [#155](https://github.com/git-stunts/shiplog/issues/155); each one carries a ready-to-run prompt, the regression tests it must pass, and a recommended model if you're pairing with one. Guidelines: [`CONTRIBUTING.md`](./CONTRIBUTING.md) · [`SECURITY.md`](./SECURITY.md) · [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md).

---

## License

MIT © J. Kirby Ross · [git-stunts](https://github.com/git-stunts)

*Jenkins was not harmed in the making of this project. We're still not sure what Jenkins is doing, but it says SUCCESS.*
