# Contributing to Shiplog

Thank you for your interest in contributing! We welcome issues, docs fixes, and PRs.

- Open issues with clear steps to reproduce or a concise proposal.
- For PRs, keep changes focused and include tests when touching behavior.
- Run locally: `make test` (Dockerized) and `gh pr create` to open PRs.
- Do not run Bats tests directly on your host. Always use `make test`.
- Keep progress bars current: run `make progress` if you update tasks under `docs/tasks/`.

Code of Conduct: see CODE_OF_CONDUCT.md.
Security reports: see SECURITY.md.

## Merging policy

- Do not merge PRs without explicit owner approval.
- All PRs must have the label `approved-by-owner` and a passing check from the `require-owner-approval` workflow.
- CODEOWNERS requires a review from @flyingrobots on all paths.

## Local pre-commit linters (optional but recommended)

- Enable repo-local hooks path (recommended): `git config core.hooksPath contrib/hooks`
- The pre-commit hook runs staged-file linters:
  - shellcheck (`bin/git-shiplog`, `contrib/hooks/*`, `scripts/bosun`, `*.sh`, `*.bash`, plus any staged file with a bash shebang)
  - markdownlint-cli2 (`*.md`)
  - yamllint (`*.yml`, `*.yaml`)
- If a tool is missing, the hook fails by default. To skip missing tools (not lint failures), set `SHIPLOG_LINT_SKIP_MISSING=1` for a single commit.
- Alternative (global hooks): `git config --global core.hooksPath ~/.config/git/hooks` then place Shiplog's pre-commit script there.

## Shell scripts & ShellCheck

- CI runs `shellcheck -S error -s bash` through `.github/workflows/lint.yml` against every tracked file with a bash shebang (selected with `git grep -l '^#!.*bash'`, which covers extensionless scripts such as `scripts/bosun`), plus `bin/git-shiplog`, every tracked `*.sh`/`*.bash`, and the full `contrib/hooks/**` tree (nested directories included). Dockerfiles and `*.bats` files are excluded.
- `scripts/dev/pre-commit-lints.sh` reuses the same severity so running the pre-commit hook (or invoking the script directly) matches CI behavior on staged files.
- Prefer fixes over suppressions. If you must keep a `# shellcheck disable=SCXXXX`, scope it narrowly and include a short justification (for example: `# shellcheck disable=SC2086 # intentional glob expansion`).
- To lint everything locally, run:
  ```sh
  { git grep -l -E '^#!.*\bbash\b' -- . ':!docs' ':!*.md' ':!*.bats' ':!Dockerfile' ':!*/Dockerfile'; \
    git ls-files -- bin/git-shiplog scripts/bosun '*.sh' '*.bash' 'contrib/hooks/*'; } \
    | sort -u | xargs shellcheck -S error -s bash
  ```
  (Add more globs if you introduce new shell-heavy directories.)
