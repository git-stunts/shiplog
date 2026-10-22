# Shiplog Test Suite

## Table of Contents

- [Overview](#overview)
- [Test Runner](#test-runner)
- [Adding or Updating Tests](#adding-or-updating-tests)
- [Running Specific Tests](#running-specific-tests)
- [Troubleshooting](#troubleshooting)

## Overview

The `test/` directory contains the Bats-based integration suite that exercises the Shiplog CLI via the `git shiplog` porcelain. Each file ending in `.bats` is automatically picked up by the Docker test harness, and helper scripts live under `test/helpers/`.

## Test Runner

- `make test` builds the local Docker image (if needed) and runs all Bats files with signing disabled. The image bakes a snapshot of your working tree into `/workspace` (`COPY . /workspace` in the `Dockerfile`), so a local `make test` runs `/usr/local/bin/run-tests` against that snapshot with nothing bind-mounted. CI (`.github/workflows/ci.yml`) runs the same image with the checkout bind-mounted over `/workspace` (`docker run -v "$PWD":/workspace`) so the container tests the exact commit under test.
- The `run-tests` entrypoint copies `/workspace` (snapshot or mount) to a temporary directory, strips any configured Git remotes, and sets `SHIPLOG_HOME` to that copy before executing Bats.
- Default test mode avoids network clones: `SHIPLOG_USE_LOCAL_SANDBOX=1` (set to `0` only if you explicitly need to hit the remote sandbox).
- Timeouts: the in-container entrypoint applies a timeout only when `TEST_TIMEOUT_SECS` is set to a positive integer (for example `TEST_TIMEOUT_SECS=180 make test`); when it is unset the run has no timeout. The legacy `test.sh` wrapper still defaults to `180`; [#132](https://github.com/git-stunts/shiplog/issues/132) unifies the two paths. Use a higher value when signing is enabled (`make test-signing`), and capture container logs when a timeout fires. Add `BATS_FLAGS` (e.g., `--print-output-on-failure -T`) for verbose runs.
- `make test-signing` performs the same flow with `ENABLE_SIGNING=true`, generating a throw‑away GPG key inside the container to exercise signed‑commit verification.
- The entrypoint installs `bin/git-shiplog` into `/usr/local/bin/git-shiplog` and exports `SHIPLOG_BOSUN_BIN`, then runs Bats (`bats -r`).
- Each Bats file calls `load helpers/common`, whose `shiplog_install_cli` helper ensures the CLI is present and executable before tests begin.

## Adding or Updating Tests

1. Create a new `*.bats` file or update an existing one under `test/`.
2. Reuse shared setup logic via `load helpers/common` and environment variables (`SHIPLOG_*`) rather than duplicating installation code.
3. Use the global `--yes` flag instead of piping `yes |` when a test needs to auto-confirm prompts.
4. Keep tests hermetic: they should initialize their own temporary repos, configure required policy files, and avoid relying on host state.
5. Document new scenarios by updating `docs/features/` or the README feature table so tooling stays in sync.
6. When simulating read-only `.git/config` behavior in tests, set `SHIPLOG_FORCE_REMOTE_RESTORE_SKIP=1` inside a subshell; the helper uses this flag to exercise the skip path since Docker runs as root.

## Running Specific Tests

- Build the test image once with `make build` (produces the `shiplog-tests` image used below).
- Run a single test file (after `make build`): `docker run --rm shiplog-tests bats test/05_verify_authors.bats`.
- Add verbosity or timeouts: `docker run --rm -e BATS_FLAGS="--print-output-on-failure -T" -e TEST_TIMEOUT_SECS=180 shiplog-tests bats test/05_verify_authors.bats`.
- Launch an interactive shell for ad‑hoc runs: `./shiplog-sandbox.sh` starts a shell in the same environment; from there run `bats` directly.
- Always run tests inside Docker; host execution is unsupported and may skip required setup.

## Troubleshooting

- “RUN THESE ONLY IN DOCKER YOU FOOL”
  - You tried to run `test.sh` on the host. Always use `make test` (Dockerized).

- Author identity unknown / “fatal: unable to auto‑detect email address”
  - Tests create temp repos and set identity automatically, but if you run ad‑hoc:
    - Inside the temp repo: `git config user.name "Shiplog Test" && git config user.email "shiplog-test@example.local"`

- Bosun UI issues or unexpected colors
  - Force plain mode: `SHIPLOG_BORING=1 git shiplog <cmd>`
  - In non‑TTY, Bosun does not prompt; tests run with safe fallbacks.

- Hanging or very slow tests
  - Opt in to the timeout guard: `TEST_TIMEOUT_SECS=180 BATS_FLAGS="--print-output-on-failure -T" make test` (raise it when signing is enabled). Capture container logs if the timeout triggers.
  - Local sandbox (no network clones) is default: `SHIPLOG_USE_LOCAL_SANDBOX=1` (set to `0` only if required).

- “Signing support not enabled” or skipped signing tests
  - Default runs disable signing. Use `make test-signing` to enable signing paths (generates a throw‑away key in the container).

- “ssh-keygen: command not found” (matrix containers)
  - The CI matrix images install an SSH client/keygen. If you see this in a custom image, add the package (e.g., `openssh-client` on Debian/Ubuntu; `openssh-clients` on Fedora; `openssh-keygen` on Alpine).

- “fatal: not in a git directory” during setup/teardown in tests
  - Ensure helper functions are used (`shiplog_use_sandbox_repo` in setup, `shiplog_cleanup_sandbox_repo` in teardown) before calling `git config`.

- Local repo contains test journals (refs/_shiplog/journal/*)
  - Tests should never write to your project repo, but if it happened historically:
    - Remove local journals: `git for-each-ref 'refs/_shiplog/journal/*' --format='%(refname)' | xargs -r -I{} git update-ref -d {}`
    - Force‑refresh local refs to match origin: `git fetch origin '+refs/_shiplog/*:refs/_shiplog/*'`

- Run a single test with verbosity
  - `docker run --rm -e BATS_FLAGS="--print-output-on-failure -T" shiplog-tests bats test/05_verify_authors.bats`
