# AGENTS.md — working agreements for coding agents

This file holds instructions only. Session logs go to `docs/notes/session-logs/`
(one `YYYY-MM-DD-HHMM.json` per session); older daily notes are archived under
`docs/archives/AGENTS/`. CI fails if this file grows past 8 KB or contains a raw
`{"date":...}` log line.

## ⚠️ CRITICAL WARNING

> [!WARNING]
> **NEVER RUN SHIPLOG TESTS LOCALLY OR DIRECTLY.** Shiplog tests manipulate Git
> repositories and can cause irreversible damage to your working repository if run
> outside the controlled Docker environment.

How to run tests safely (Dockerized):

- Use `make test` from the repo root. It builds the image and runs the full Bats suite
  in an isolated container. Never invoke Bats or individual `.bats` files on the host.
- CI runs the same flow via the bash matrix. For distro-specific runs locally, use
  `ci-matrix/run-all.sh`.
- Tests default to `SHIPLOG_USE_LOCAL_SANDBOX=1` (no network clones); set it to `0`
  only when you explicitly need the remote sandbox repo.
- Timeouts, `BATS_FLAGS`, and how to run a single file: see `test/README.md`
  (#132 unifies the timeout default; do not restate it here).

## Where the plan lives

- `ROADMAP.md` holds the goals, decisions D1–D4 and each goal's definition of done.
  Live status is tracking issue #155; the checker ticks the boxes, humans do not.
- GitHub issues are the source of truth (label `audit-2026-10` for the audit set).
- `docs/tasks/` is a **frozen** historical ledger. Do not add task files. Run
  `make progress` and `scripts/update-task-moc.sh` only when repairing that snapshot.
- Docs index: `docs/README.md`. Hosting guidance: `docs/hosting/`. Trust model:
  `docs/TRUST.md`.

## Git workflow

- Never push directly to `main`. Branch from `main` with a descriptive prefix
  (`feature/`, `bugfix/`, `hotfix/`, `docs/`) and open a pull request.
- Never amend commits or force-push to shared branches without explicit user approval;
  amending local, unpushed commits is encouraged.
- If a task appears to require a force push, stop and ask first. When approved, use
  `git push --force-with-lease`, never `--force`.
- Keep branches focused and short-lived; sync with `main` regularly; delete them after
  merge.
- Write conventional, atomic commits. No "WIP" or "fix typo" commits in the final PR
  history; for shared branches add commits rather than rewriting.
- Run the full suite (`make test`) before pushing to a shared branch, in the same
  environment CI uses.

## Lessons learned

- Tests that exercise Bosun must run inside the container; native runs can pass while
  tab parsing fails under Docker. Validate UI paths where CI runs them.
- Build Bosun tables column-by-column with `$'\t'` concatenation; literal tabs inside
  one string invite quoting surprises.
- Plugin scripts run with full privileges. Enforce canonical path checks and a clear
  execution contract so extensions cannot escape the sandbox; document the security
  expectations next to the hooks.
- Tests that touch Git refs must self-clean (`git update-ref -d`) and must not assume
  an empty state; give each test a unique identifier (`$RANDOM`, `BATS_TEST_NUMBER`).
- A green check must check something. Keep CI steps blocking; fix the baseline instead
  of disabling a rule.

## Project-specific rules

- Runtime and test dependencies are stock POSIX tools plus `jq` (1.6 or newer). Do not
  introduce other external binaries.
- Docs are checked in CI: `scripts/dev/check-md-fences.sh` (every code fence closed) and
  `scripts/dev/check-md-links.sh` (every relative link resolves). Run both before
  opening a docs PR.
- Keep `README.md` as the single README; `shiplog_readme.md` is a pointer stub only.
