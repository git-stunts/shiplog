# bosun style

Render text inside a decorated box with borders and an optional title for human-friendly terminal output.

```
bosun style [--title TEXT] [--width NUM] [--no-color] -- "text"
printf '%s\n' "text" | bosun style [--title TEXT] [--width NUM] [--no-color]
```

- `--title` adds a bold, colored caption in the top border.
- `--width` sets the overall box width in columns (default 80). Lines longer than the inner width are wrapped.
- `--no-color` removes ANSI styling (also implied by `NO_COLOR`).

Text comes from the positional arguments after `--`; when none are given it is read from stdin. Multi-line text is boxed line by line.

Examples:

```bash
bosun style --title "Preview" -- "Deploying api@v1.2.3 to prod"
#> ┌ Preview ─────────────────────────────────────────────────────────────────────┐
#> │ Deploying api@v1.2.3 to prod                                                 │
#> └──────────────────────────────────────────────────────────────────────────────┘

bosun style --width 40 --no-color -- "A narrower box"

cat release-notes.txt | bosun style --title "Release notes"
```

The command strips ANSI codes when computing layout so coloured titles remain aligned (see the `perl` note in `bosun help overview`).
