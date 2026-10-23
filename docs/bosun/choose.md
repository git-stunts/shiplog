# bosun choose

Display a numbered menu and return the selected option.

```
bosun choose [--header TEXT] [--default OPTION] [--json] [--no-color] OPTION...
```

- `--header` prints a heading above the menu.
- `--default` specifies the fallback option for non-interactive runs.
- `--json` emits `{ "value": "…" }` instead of the raw choice.
- `--no-color` disables ANSI styling (also implied by `NO_COLOR`).

The header, menu and `>` prompt are written to stderr; stdout receives only the chosen option, so `env=$(bosun choose …)` still shows the menu and captures exactly the selection. A selection that is not a listed number prints `invalid selection` on stderr and exits 1. Calling without options exits 2.

Examples:

```bash
env=$(bosun choose --header "Select environment" dev stage prod)

bosun choose --default stage --json dev stage prod <<<''
#> {"value":"stage"}

# Interactive usage
bosun choose --header "Select environment" dev stage prod
# Select environment
#   1) dev
#   2) stage
#   3) prod
# > 2
# stage
# (exit status 0)
```

When running without a terminal (see `bosun help overview`) the command picks the default option (or the first value if no default is given).
