# Export JSON Command

## Summary
`git shiplog export-json` emits NDJSON records for journal entries so downstream systems can ingest Shiplog data. Each line combines the stored JSON trailer with the commit SHA in a `commit` field.

## Usage
```bash
git shiplog export-json [ENV] [--lenient] | jq '.'
```

## Behavior
- Requires `jq` to be available.
- Streams commits in reverse chronological order and appends a `commit` field to each JSON payload.
- Emits exactly one line per journal commit. When a commit has no trailer, or its trailer is not a single JSON object, the line is an error record and the export continues:

  ```json
  {"commit":"<sha>","error":"invalid trailer","subject":"<first line of the commit message>"}
  ```

  Consumers should branch on the presence of `error` before reading entry fields.
- Exit status: `0` when every entry was valid; `3` when at least one entry was flagged (a summary goes to stderr). `--lenient` keeps the error records in the stream but exits `0`.
- A journal that does not exist is an error (`journal <ref> not found`), not an empty export.
- Uses the same environment resolution rules as other commands (argument, `--env`, `SHIPLOG_ENV`, default `prod`). Only one positional `ENV` is accepted; unknown flags are errors.

```bash
# Dashboards: keep going on bad entries, but surface them
git shiplog export-json prod --lenient | jq -c 'select(.error) | {commit, subject}'
```

## Related Code
- `lib/commands.sh` — `cmd_export_json()`

## Tests
- `test/03_export_json_ndjson.bats:11`
- `test/32_cli_parsing.bats` (malformed trailers, exit 3, `--lenient`, missing journal)
