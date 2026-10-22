# Notes Attachments

## Summary
Shiplog can attach NDJSON logs or other artifacts to journal entries using Git notes. Notes are stored under one resolved notes ref: the policy `notes_ref` if set, else `SHIPLOG_NOTES_REF`, else `<ref root>/notes/logs` (`refs/_shiplog/notes/logs` by default). `write`, `show`, `export-json` and `publish` all resolve the same ref, so attached logs stay visible and get published. The attachments appear in `git shiplog show` output.

## Usage
```bash
SHIPLOG_LOG=path/to/log.ndjson git shiplog write prod
```

## Behavior
- When `SHIPLOG_LOG` points to a readable file, the write flow saves it as a note on the newly created commit using `git notes --ref=$NOTES_REF add`.
- `git shiplog show` streams the note contents in the interactive UI or plain output.
- Notes live under a dedicated ref so they can be fetched and pushed alongside journals; `git shiplog publish` pushes it and fails if entries claim `log_attached=true` while the resolved notes ref is missing locally.

## Storage detail: the `refs/notes/` alias
`git notes --ref=X` operates on `refs/notes/X` unless `X` already starts with `refs/notes/`. Shiplog keeps notes under the ref root (so they are published and protected together with the journals), so it makes `refs/notes/<notes ref>` a local symbolic ref pointing at the real ref, e.g. `refs/notes/refs/_shiplog/notes/logs -> refs/_shiplog/notes/logs`. Any `git notes --ref=refs/_shiplog/notes/logs ...` call therefore reads and writes the real ref. Notes written by older Shiplog versions at the legacy location `refs/notes/refs/_shiplog/notes/logs` are adopted into the real ref the first time a command touches notes.

## Related Code
- `lib/git.sh:52`
- `lib/git.sh:178`

## Tests
- `test/04_notes_attachment.bats:20`
