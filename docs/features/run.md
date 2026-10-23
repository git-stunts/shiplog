# Run Command

## Summary

`git shiplog run` wraps a shell command, captures its stdout/stderr, and records the execution as a Shiplog journal entry. Output is saved as a git note, and the structured trailer gains a `run` payload describing the invocation. Use `--dry-run` to preview the command, status, and trailer fields without executing the command or mutating the journal.

## Usage

```bash
# Standard execution (writes to the journal once the wrapped command runs)
git shiplog run --service deploy --reason "Smoke test" -- env printf hi

# Dry run: rehearse the invocation without executing or writing an entry
git shiplog run --dry-run --service deploy --reason "Smoke test" -- env printf hi
```

- `--service` is required in non-interactive mode (and strongly recommended for clarity).
- Place the command to execute after `--`; all arguments are preserved and logged.
- Successful executions inherit `--status-success` (default `success`); failures use `--status-failure` (default `failed`).

## Dry Run Mode (`--dry-run`)

- Prints a Bosun-formatted preview (or a plain message when Bosun/TTY styling is unavailable) showing the command that would execute.
- Skips command execution, journal entry creation, and log attachment entirely.
- Exits with status `0` when the dry-run invocation is well formed. Invalid flags, missing `--`, or unknown subcommands surface the same non-zero exit codes as the standard command.
- Deterministic output keeps automation safe while rehearsing deploy playbooks.

## Behavior (Standard Runs)

- Captures stdout/stderr to a temporary file. When not in `--boring` mode, output streams live through two named pipes (one per stream) while still being recorded; Shiplog waits for both writers before attaching the log, so the note holds the complete output. Because the streams travel separately, their interleaving in the log may differ slightly from what the terminal showed; each stream is complete and in order.
- Sets `SHIPLOG_BORING=1` and `SHIPLOG_ASSUME_YES=1` while delegating to `git shiplog write`, ensuring prompts are bypassed.
- Attaches a `run` block to the trailer (through the internal `SHIPLOG_RUN_JSON` channel; `run` is a reserved key that `SHIPLOG_EXTRA_JSON` cannot override) such as:
  ```json
  {
    "run": {
      "argv": ["env", "printf", "hi"],
      "cmd": "env printf hi",
      "exit_code": 0,
      "status": "success",
      "duration_s": 1,
      "started_at": "2025-09-30T00:00:00Z",
      "finished_at": "2025-09-30T00:00:01Z",
      "log_attached": true
    }
  }
  ```
- Attaches the captured log as a git note under `refs/_shiplog/notes/logs` when an entry is written successfully.
- Returns the wrapped command’s exit code so it can chain cleanly in scripts or CI pipelines.

### Confirmation Output

- After the wrapped command completes, Shiplog prints a minimal confirmation line.
- Default: a log emoji only (`🪵`).
- Customize with `SHIPLOG_CONFIRM_TEXT` (e.g., `> Shiplogged`, `Recorded`).
- The previous verbose preview is suppressed to keep terminals quiet; use `git shiplog show` if you want to inspect the entry that was written.

## Exit Codes

- Dry run
  - `0` when the preview succeeds.
  - Non-zero for malformed invocations or validation errors.
- Standard run
  - Mirrors the wrapped command’s exit status after the journal entry is recorded.
  - Propagates Shiplog errors directly if the CLI fails before wrapping the command.
  - If the journal write fails after the command ran, Shiplog prints the write error (for example a missing trust ref or an allowlist rejection) followed by `❌ shiplog: failed to record run entry; log preserved at <path>`. The exit code is the wrapped command’s non-zero status when it failed, otherwise `1`.

## Options

- `--dry-run` — Preview the command and metadata without executing or writing an entry.
- `--env <name>` — Target journal environment (defaults to `SHIPLOG_ENV` or `prod`).
- `--service <name>` — Service/component; required when prompts are disabled.
- `--reason <text>` — Optional free-form description.
- `--status-success <status>` — Status recorded when the wrapped command exits 0. Default `success`.
- `--status-failure <status>` — Status recorded when the command fails. Default `failed`.
- Both statuses must be one of `success`, `failed`, `in_progress`, `skipped`, `override`, `revert`, `finalize`. An invalid value is rejected before the command runs (`shiplog: invalid status 'bogus' ...`), so a typo never executes a deploy that then cannot be recorded.
- `--ticket <id>`, `--region <r>`, `--cluster <c>`, `--namespace <ns>` — Override standard write metadata.
- When there is no output, log attachment is skipped and `log_attached=false` is recorded in the trailer.
- Confirmation text: set `SHIPLOG_CONFIRM_TEXT` to override the default emoji (see above).

## Caveats

- **Secrets (standard runs):** the command's stdout and stderr are stored as a git note, the command line is recorded in the entry trailer (`run.argv`), and both are published with the journal (auto-push or `git shiplog publish`). Neither passes through the message plugins (they only see the commit message), and nothing is redacted (#86). `--dry-run` executes nothing and stores nothing. Do not wrap commands that print credentials, and do not pass secrets as arguments; read them from the environment or a file instead.
- Dry runs do not validate connectivity to downstream systems—it only checks CLI argument parsing and policy prerequisites.
- Ensure `perl` is available if you rely on Bosun rendering; otherwise Shiplog falls back to plain text.

## See Also

- `docs/features/write.md`
- `docs/features/command-reference.md`
- `docs/reference/env.md`
- `docs/notes/codex-feedback-on-shiplog.md`
- `docs/reference/json-schema.md`
