# Command Reference

A concise, code-sourced reference for Shiplog commands, flags, and examples. Global flags apply to all subcommands unless noted.

## Global Options

- `--env <ENV>` — Target environment (default `prod`; can also set `SHIPLOG_ENV`). Environment precedence: positional `ENV` on the subcommand > subcommand `--env` > global `--env` > `SHIPLOG_ENV` > `prod`. The selected environment drives both the journal ref and policy resolution (per-environment `require_signed` and author overrides).
- `--boring` — Non-interactive mode (plain output; prompts disabled). Also `SHIPLOG_BORING=1`.
- `--yes` — Auto-confirm prompts (sets `SHIPLOG_ASSUME_YES=1`).
- `--no-push` / `--push` — Control auto-push behavior for commands that push refs.
- `--dry-run[=VALUE]` — Preview actions without updating Shiplog journals or notes (`SHIPLOG_DRY_RUN=1`). `VALUE` accepts `1|true|yes|on|0|false|no|off` (any case); anything else is an error.
- `--version` `-V` — Print version and exit.
- `--help` `-h` — Show usage.

## Commands

- `config [--interactive|--wizard] [--answers-file file] [--apply] [--dry-run] [--emit-github-ruleset] [--emit-github-workflow]`
  - Purpose: host‑aware questionnaire that recommends settings and optionally applies them locally.
  - Usage:
    - Interactive: `git shiplog config --interactive`
    - Apply: `git shiplog config --interactive --apply`
    - Non‑interactive: `git shiplog config --answers-file answers.json --apply`
    - Emit GitHub examples (stdout only):
      - Rulesets: `git shiplog config --interactive --emit-github-ruleset`
      - Verify workflow: `git shiplog config --interactive --emit-github-workflow`
  - Notes: Writes `.shiplog/policy.json` and sets `shiplog.refRoot` / `shiplog.autoPush` when `--apply` is provided. It never pushes. See `docs/features/config.md`.

- `version`
  - Purpose: print Shiplog version.
  - Usage: `git shiplog version`

- `init`
  - Purpose: configure refspecs for `refs/_shiplog/*` and enable `core.logAllRefUpdates`.
  - Usage: `git shiplog init`
  - Notes: idempotent; adds safe `push=HEAD` only if none present.

- `write [ENV]`
  - Purpose: append a new entry to `refs/_shiplog/journal/<env>`.
  - Usage:
    - Interactive: `git shiplog write prod`
    - Non-interactive: `SHIPLOG_BORING=1 git shiplog --yes write prod`
  - Env: `SHIPLOG_SERVICE`, `SHIPLOG_STATUS`, `SHIPLOG_REASON`, `SHIPLOG_TICKET`, `SHIPLOG_REGION`, `SHIPLOG_CLUSTER`, `SHIPLOG_NAMESPACE`, `SHIPLOG_IMAGE`, `SHIPLOG_TAG`, `SHIPLOG_RUN_URL`, `SHIPLOG_LOG`, `SHIPLOG_AUTO_PUSH`.
  - Flags: accepts `--dry-run` to preview the entry after prompts without appending to the journal or pushing notes.
  - Effects: honors allowlists/signing per policy; pushes journal (+notes) to origin unless disabled.

- `append [OPTIONS]`
  - Purpose: append a new entry non-interactively by supplying a JSON payload via CLI, stdin, or file.
  - Usage: `printf '{"deployment":"green"}' | git shiplog append --service deploy --status success --json -`
  - Flags: mirrors `write` (`--service`, `--status`, `--reason`, `--ticket`, `--region`, `--cluster`, `--namespace`, `--image`, `--tag`, `--run-url`, `--log`, `--env`, `--dry-run`).
  - Notes: sets `SHIPLOG_EXTRA_JSON` automatically with the provided object and runs `write` in boring/auto-confirm mode.

- `run [OPTIONS] -- <command ...>`
  - Purpose: wrap a shell command, tee its output (when interactive), and append a Shiplog entry describing the run.
  - Usage:
    - Success case: `git shiplog run --service deploy --reason "Smoke test" -- env printf hi`
    - Failure case: `git shiplog run --service deploy --status-failure failed -- false`
  - Flags: `--service`, `--reason`, `--status-success`, `--status-failure`, `--ticket`, `--region`, `--cluster`, `--namespace`, `--env`, `--dry-run`.
  - Notes: captures stdout/stderr to a temporary log that is attached as a git note (skipped if empty) and merges `{run:{...}}` into the JSON trailer via `SHIPLOG_EXTRA_JSON`. Prints a minimal confirmation after the run (default `🪵`), configurable via `SHIPLOG_CONFIRM_TEXT`. `--dry-run` prints the command that would execute and exits without running it or writing a journal entry. See `docs/features/run.md` for details.

- `ls [ENV] [LIMIT]`
  - Purpose: list recent entries.
  - Usage: `git shiplog ls prod 20`
  - Output: Bosun table when available; otherwise TSV with header.

- `show [--json|--json-compact|--jsonl] [--boring] [COMMIT|REF]`
  - Purpose: display a single entry (human + trailer + notes).
  - Usage:
    - Latest (default env): `git shiplog show`
    - JSON only: `git shiplog show --json`
    - Compact JSON: `git shiplog show --json-compact`
  - Notes: defaults to latest at `refs/_shiplog/journal/<ENV>`; fails if no trailer.

- `validate-trailer [COMMIT]`
  - Purpose: validate an entry’s JSON trailer.
  - Usage: `git shiplog validate-trailer <commit-or-ref>`
  - Exit: 0 on valid; non-zero with errors on invalid.

- `verify [ENV]`
  - Purpose: verify signatures/authors for entries in a journal.
  - Usage: `git shiplog verify prod`
  - Output: `Verified: OK=<n>, BadSig=<n>, Unauthorized=<n>`; non-zero exit if any issues.

- `export-json [ENV]`
  - Purpose: NDJSON export; each line is trailer + `commit` field.
  - Usage: `git shiplog export-json prod | jq '.'`
  - Requires: `jq`.

- `publish [ENV] [--no-notes] [--policy] [--trust] [--all]`
  - Purpose: push Shiplog refs (journals/notes, and optionally policy/trust) to origin without writing a new entry.
  - Usage: `git shiplog publish` (current env), `git shiplog publish --env prod`, `git shiplog publish --all --policy`
  - Notes: use this at the end of a deployment if you disable auto-push. Precedence for pushing: command flags > `git config shiplog.autoPush` > `SHIPLOG_AUTO_PUSH`.

- `policy [show|validate|require-signed|toggle] [--env ENV] [--json] [--boring]`
  - Purpose: inspect/change effective policy and signing requirement.
  - Usage:
    - Show (plain): `git shiplog policy show` (for another environment: `git shiplog policy show --env staging`)
    - Show (JSON): `git shiplog policy show --json`
    - Validate the working-tree file (or the ref when no file exists): `git shiplog policy validate`
    - Validate the published ref: `git shiplog policy validate --ref`; any file: `git shiplog policy validate --file path.json`
    - Require signed: `git shiplog policy require-signed true`
    - Toggle: `git shiplog policy toggle`
  - Notes: `show` reports the source of every field (`sources` in JSON, `(from ...)` in plain text) and only warns when signing is on but the signers file is missing; `write`/`run`/`append`/`verify` refuse in that state. `require-signed`/`toggle` abort before moving the local policy ref when the resulting document fails validation. A policy document that fails validation stops every command (no fallback to defaults). See `docs/features/policy.md` for the precedence table.
  - JSON: includes `env_require_signed` map from `deployment_requirements`, `sources`, `allowed_signers_file_exists` and `warnings`.

- `trust sync [REF] [DEST]`
  - Purpose: sync allowed signers from a trust ref to a local file.
  - Usage: `git shiplog trust sync refs/_shiplog/trust/root .shiplog/allowed_signers`

- `trust show [REF] [--json]`
  - Purpose: display trust metadata (ID, threshold, maintainer roster, signer list and count).
  - Usage:
    - Human readable: `git shiplog trust show`
    - JSON: `git shiplog trust show --json`

- `refs root show|set`
  - Purpose: view or set the Shiplog ref root.
  - Usage:
    - Show: `git shiplog refs root show`
    - Set: `git shiplog refs root set refs/heads/_shiplog`

- `refs migrate [--to <refs/...>] [--from <refs/...>] [--push] [--remove-old] [--dry-run]`
  - Purpose: migrate/mirror refs between roots using the helper script.
  - Usage: `git shiplog refs migrate --to refs/heads/_shiplog --dry-run`

- `setup [--strictness open|balanced|strict] [--authors "a@x b@y"] [--strict-envs "prod staging"] [--auto-push|--no-auto-push] [--dry-run] [TRUST_OPTS...]`
  - Purpose: write `.shiplog/policy.json`, sync local policy ref, optionally bootstrap trust and push.
  - Env: `SHIPLOG_SETUP_STRICTNESS`, `SHIPLOG_SETUP_AUTHORS`, `SHIPLOG_SETUP_STRICT_ENVS`, `SHIPLOG_SETUP_AUTO_PUSH`, `SHIPLOG_SETUP_DRY_RUN`.
  - Trust options: `--trust-id`, `--trust-threshold`, `--trust-maintainer`, `--trust-message`.

## See Also

- Features docs: init, write, ls, show, export-json, validate-trailer, verify, policy, setup, notes.
- Modes and signing policy: `docs/features/modes.md`
- GitHub hosting and protections: `docs/hosting/github.md`, `docs/runbooks/github-protection.md`
