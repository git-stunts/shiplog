# bosun confirm

Interactive confirmation prompts for Bosun CLI operations.

Prompt the user for a yes/no response with configurable output formats.

```
bosun confirm [--yes] [--default-yes] [--json] [--no-color] "Prompt"
```

- `--yes` (alias `-y`) answers yes without prompting and exits 0 (for non-interactive scripts).
- `--default-yes` makes Enter mean yes (`[Y/n]`), and answers yes when there is no terminal to prompt on.
- `--json` emits `{"ok":true}`, `{"ok":false}` or `{"ok":null}` instead of plain `yes`/`no` text.
- `--no-color` disables ANSI styling (also honored when the `NO_COLOR` environment variable is set).

## Exit codes

| Exit | Meaning | stdout |
| ---- | ------- | ------ |
| 0 | yes | `yes` (or `{"ok":true}`) |
| 1 | no | `no` (or `{"ok":false}`) |
| 2 | could not prompt: no terminal and neither `--yes` nor `--default-yes` | nothing (or `{"ok":null}`); a hint is printed on stderr |

The prompt itself is written to stderr, so `$(bosun confirm …)` captures only `yes`/`no`. Any answer other than `y`/`Y` (including an unrecognised key) counts as no.

## Non-interactive rule

Bosun prompts only when stdin is a terminal and stdout or stderr is a terminal (see `bosun help overview`). In a pipeline or CI job there is nothing to ask, so `confirm` exits 2 rather than silently answering no. Callers can tell "declined" (1) from "unavailable" (2) and decide whether to fall back to their own prompt; Shiplog's `shiplog_confirm` falls back only on 2 and treats 1 as an abort. Pass `--yes` or `--default-yes` when a script must proceed without a terminal.

Examples:

```bash
bosun confirm "Deploy to production?"
#> Deploy to production? [y/N] y
#> yes
# exit 0

bosun confirm "Abort release?"
#> Abort release? [y/N] n
#> no
# exit 1

bosun confirm --yes "Skip safety check"
#> yes
# exit 0

bosun confirm --default-yes "Continue?"
#> Continue? [Y/n]
#> yes
# exit 0 (Enter accepted the default)

bosun confirm --json "Continue?"
#> {"ok":true}
# exit 0

echo y | bosun confirm "Piped input is not a terminal"
#> bosun confirm: no terminal available to prompt (pass --yes or --default-yes)
# exit 2
```
