# Show Command

## Summary
`git shiplog show` displays the details for a shiplog entry. It defaults to the latest entry in the current environment’s journal when no target is specified. Output includes a human‑readable summary, the JSON trailer, and any attached Git notes (logs).

## Usage
```bash
git shiplog show [--json|--json-compact|--jsonl] [--boring] [COMMIT|REF]
```

## Behavior
- Default target: latest entry at the environment journal ref (`refs/_shiplog/journal/<ENV>`). ENV resolves from `--env`, then `SHIPLOG_ENV`, or `prod`.
- Flags may appear before or after the target (`git shiplog show <sha> --json`). At most one target is accepted and unknown flags are errors.
- `--json`: print only the JSON trailer of the entry (pretty if `jq` is present; raw otherwise).
- `--json-compact`/`--jsonl`: print a single compact JSON line.
- `--boring`: disable Bosun UI rendering and print plain text.
- Bosun present: renders sections in titled boxes; otherwise prints plain text.
- Notes: if a note exists at `NOTES_REF` (default `refs/_shiplog/notes/logs`), its contents are shown after the trailer.
- Error on missing trailer: if the entry body does not contain a JSON trailer, the command fails with a clear message.

## Related Code
- `lib/commands.sh` — `cmd_show()`
- `lib/git.sh` — `show_entry()` and helpers

## Tests
- `test/02_write_and_ls_show.bats`
- `test/04_notes_attachment.bats`
- `test/08_show_latest_default.bats`
