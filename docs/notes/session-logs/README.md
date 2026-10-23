# Session logs

Structured logs of agent working sessions, one file per session, named
`YYYY-MM-DD-HHMM.json` and pretty-printed with `jq -S`.

These lines used to be appended verbatim to `AGENTS.md`; they were moved here on
2026-10-22 (#152) so that file holds only instructions. Older free-form daily notes
live in [`docs/archives/AGENTS/`](../../archives/AGENTS/).

Each file carries `date`, `time`, `summary`, `topics[]` (what/why/context/issue/
resolution/future_work), `key_decisions[]` and `action_items[]`. Add a new file per
session; do not edit `AGENTS.md` for this.
