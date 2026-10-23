# bosun input

Collect a single line of text, optionally with a default value.

```
bosun input [--placeholder TEXT] [--value VALUE] [--json] [--no-color]
```

- `--placeholder` sets the prompt shown when running interactively (default `>`).
- `--value` (alias `--default`) seeds the input; if the user presses enter, the default is returned.
- `--json` emits `{ "value": "…" }` instead of the raw string.
- `--no-color` disables ANSI styling (also implied by `NO_COLOR`).

The prompt is written to stderr; stdout receives only the answer, so `name=$(bosun input …)` still prompts on the terminal and captures exactly what was typed.

Examples:

```bash
name=$(bosun input --placeholder "Who is deploying?" --value "$USER")

bosun input --value "v1.2.3" --json <<<'v1.2.4'
#> {"value":"v1.2.4"}
# exit 0

# Empty stdin with no default: returns empty string, exit 0
bosun input <<<''
#>
# exit 0

# Non-interactive CI example: stdin closed, falls back to default then exits 0
CI=1 bosun input --placeholder "Ticket" --value "UNKNOWN" --json </dev/null
#> {"value":"UNKNOWN"}
# exit 0

# Placeholder + default when user presses enter (prompt on stderr, answer on stdout)
bosun input --placeholder "Artifact tag" --value "latest"
#> Artifact tag
#> latest
# exit 0
```

Non-interactive mode (no terminal; see `bosun help overview`) reads stdin when it is a pipe or a non-empty regular file and falls back to the default value when no data is provided.
