# bosun table

Format tab-separated rows into a padded table.

```
bosun table --columns "Col1,Col2" [--rows-file file.tsv] [--no-color]
```

- `--columns` (required) defines the column headers, comma-separated.
- `--rows-file` reads rows from a TSV file instead of stdin.
- `--no-color` disables ANSI styling (also implied by `NO_COLOR`).

Column widths are sized automatically to the widest header or cell.

## Input rows

Rows are tab-separated and must contain exactly as many cells as there are headers. **Empty cells are allowed**: consecutive tabs, a leading tab or a trailing tab each denote an empty cell, which renders as blank padding. Blank lines are skipped.

```bash
printf 'web\t\tready\n' | bosun table --columns "Svc,Ticket,Status"
#> Svc  Ticket  Status
#> ───  ──────  ──────
#> web          ready
```

## Exit codes

| Exit | Meaning |
| ---- | ------- |
| 0 | table rendered |
| 2 | usage error: missing `--columns`, empty column name, or unreadable `--rows-file` |
| 3 | a row's cell count does not match the number of headers (the offending count is reported on stderr) |

Examples:

```bash
printf 'abc\tREADY\nxyz\tFAILED\n' | \
  bosun table --columns "Service,Status"

bosun table --columns "Env,Result" --rows-file results.tsv
```
