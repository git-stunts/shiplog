# AGENTS.md daily notes and release memoir (September–October 2025)

Archived from `AGENTS.md` on 2026-10-22 (#152) so that file holds only agent instructions.
Structured session logs from the same period live in `../../notes/session-logs/`.

## Daily Notes

### Daily Note – 2025-09-25

- Stabilized policy JSON output and CLI JSON paths:
  - `git shiplog policy show --json` now robustly returns valid JSON; trailing `--json` flag supported.
  - Added `git shiplog show --json` and `--json-compact` for single-entry JSON output.
- Test reliability and timeouts:
  - Enforced in-container timeout for Bats via the Docker test entrypoint; `TEST_TIMEOUT_SECS` env supported.
  - Default tests use `SHIPLOG_USE_LOCAL_SANDBOX=1` to avoid network clones; added `BATS_FLAGS` support for stderr on failure.
- Fixed Alpine/Arch CI:
  - Removed hard Perl dependency in Bosun (`strip_ansi` fallback) and installed `ssh-keygen` in matrix images.
  - Normalized policy writes (jq -S) and treated semantically-equal JSON as no-op to stop backup churn across distros.
- Installer safety:
  - `scripts/install-shiplog.sh` now fetches tool refs inside the installer repo (`$SHIPLOG_HOME`) and never mutates the caller repo; force-refreshes tool refs.
- GitHub hosting/docs/tooling:
  - Added docs/hosting/github.md and docs/runbooks/github-protection.md; explained custom refs vs branch namespace and protections.
  - Shipped a migration helper: `scripts/shiplog-migrate-ref-root.sh`; CLI wrapper `git shiplog refs migrate` plus `refs root show|set`.
  - Added importable Ruleset JSON and Actions workflows under `docs/examples/github/` for branch namespace and custom-refs auditing.
- README refresh:
  - Added “GitHub Hosting” links, Environment Reference, Quick copy/paste commands, JSON-only `show` examples.

### Daily Log – 2025-09-26

- MVP docs + release
  - Full features docs sweep; added docs/features/command-reference.md.
  - test/README.md aligned with snapshot runner, timeouts, local sandbox.
  - Tasks MoC generator (scripts/update-task-moc.sh) and populated docs/tasks/README.md; kept progress bars updated (scripts/update-task-progress.sh UTF‑8 fix).
  - Opened and merged MVP PR (feat/github → main); tagged and pushed v0.1.0-mvp.
- CI/CD signing
  - Fixed shiplog-sign workflow to bind to the selected environment and read CI_SSH_PUBLIC_KEY from environment variables (vars.*) instead of env.*.
- CLI improvements
  - git shiplog write: new flags (--service/--reason/--status/--ticket/--region/--cluster/--namespace/--image/--tag/--run-url, --env), non-Bosun prompt fallbacks.
  - Signing robustness: fixed unbound array expansion in sign_commit under set -u.
- README
  - Linked Command Reference; kept Overall bar mirrored from docs/tasks.

### Daily Log – 2025-09-24

- Fixed Bosun non-TTY input hang: scripts/bosun now properly handles empty stdin in non-interactive environments by implementing timeout-based input detection (resolves issue where CI pipelines would hang indefinitely).
- Completed setup wizard (Open/Balanced/Strict) with per-env strictness, non-interactive flags, backups/diffs, and --dry-run.
- Implemented per-environment `require_signed` in CLI and hook; policy show includes per-env mapping (plain + JSON).
- Hardened trust bootstrap (env-driven, removed stray prompt loop, repo-root paths, wizard uses --no-push).
- Synced policy ref layout to `.shiplog/policy.json` in the policy ref tree.
- Test harness: local sandbox option, remove upstream origin, non-interactive SSH signing; added wizard/per-env tests.
- Aligned CI artifact paths; added cross-distro bash matrix workflow.
- Full Dockerized test suite passes: all 40 Bats test cases complete successfully across Docker environments.
- Archived: Complete policy and sync tooling hardening (see docs/archives/AGENTS/completed-2025-09-25.md)
- Archived: Refactor installers and uninstallers for path safety (see docs/archives/AGENTS/completed-2025-09-25.md)

- Archived: Finish sandboxed test migration and isolation (see docs/archives/AGENTS/completed-2025-09-25.md)

> Note: All task checklists have been migrated to `docs/tasks/`.

For the current backlog, active work, and completed items, see:

- docs/tasks/backlog/
- docs/tasks/active/
- docs/tasks/complete/

Progress bars are now maintained in `docs/tasks/README.md` (and mirrored into the root README) by `scripts/update-task-progress.sh`.

## Memoir – Release v0.2.0 (The Cut of Your Jib)

### What We Attempted

Delivered Shiplog v0.2.0 “The Cut of Your Jib”: implemented `git shiplog run`, `git shiplog append`, `git shiplog trust show`, hardened tests, and polished release artifacts. Tag v0.2.0 is live.

### Key Decisions & Why

- Documented trailer schema (`docs/reference/json-schema.md`) to remove guesswork for consumers.
- Gave `test/17_append_and_trust.bats` a unique journal per run plus cleanup to stop cross-run failures.
- Used `release/v0.2.0` as staging branch for the PR/tag to keep history clean.

### What Worked

- `cmd_run` in `lib/commands.sh` captures structured run metadata and attaches logs as intended.
- `cmd_append` handles `--json`/stdin payloads and namespace defaults correctly.
- `cmd_trust show` surfaces trust roster/signers in both table and `--json` forms.
- Docs (README, `docs/releases/v0.2.0.md`, CHANGELOG) reference real paths/examples and pass review.

### What Failed or Was Painful

- CI flakiness from lingering journal refs in `test/17_append_and_trust.bats`; required unique env + cleanup trap.
- Initial release note file misnamed (`v020.md`) and needed cleanup.
- Too-strict empty-state assertions in the stdin append test caused rerun failures.

### Lessons & Patterns

- Tests manipulating Git refs must self-clean (`git update-ref -d`) and avoid assuming empty state.
- Generate unique identifiers per test (`$RANDOM`, `BATS_TEST_NUMBER`) to prevent collisions.
- Explicit documentation (schema, release notes, README) smooths review.

### Unresolved Threads

- UNKNOWN whether runbook task `SLT.BETA.015` will ship before next release.

### Next Moves

- NONE (release tagged and published).
