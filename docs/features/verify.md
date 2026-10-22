# Verify Command

## Summary
`git shiplog verify` validates entries in the shiplog journal (git commit history) against configured signing policies and author allowlists. It reports counts of valid entries, commits with bad signatures, and commits from unauthorized authors.

## Usage
```bash
git shiplog verify [ENV] [--allow-empty]
```

### Parameters
- `ENV` (optional): journal environment to verify (for example `prod`, `staging`, `dev`). When omitted, the command uses the resolved default environment (`SHIPLOG_ENV` or `prod`). Only one positional is accepted.
- `--allow-empty`: treat a result with `OK=0` as success. Without it a verification that confirmed nothing fails, so a CI gate cannot go green on an empty or unfetched journal.

## Behavior
- Resolves policy inputs from multiple sources in order of precedence: environment variables, git config, working tree, then policy ref.
- Uses `git verify-commit` (with `GIT_SSH_ALLOWED_SIGNERS` when provided) to check signatures when required by policy.
- Fails before scanning when the journal ref does not exist: `journal refs/_shiplog/journal/<ENV> not found`. A typo'd environment is an error, not a passing report.
- Scans all entries and prints a summary: `Verified: OK=<n>, BadSig=<n>, Unauthorized=<n>`.
- Exit code is non‑zero if any bad signatures or unauthorized authors are found, or if `OK=0` (unless `--allow-empty`); zero otherwise.

## Related Code
- `lib/commands.sh` — `cmd_verify()`
- `lib/git.sh` — `ensure_signed_on_verify()`, `author_allowed()`
- `lib/policy.sh` — policy resolution

## Tests
- `test/05_verify_authors.bats:22`
- `test/05_verify_authors.bats:28`
- `test/06_verify_signatures_signed_build.bats:18`
- `test/32_cli_parsing.bats` (missing journal, extra arguments, unknown flags)
