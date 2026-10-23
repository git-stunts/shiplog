# Bosun Overview

Bosun provides lightweight TUI primitives implemented in pure Bash, designed to work in both interactive shells and non-interactive environments while honoring `NO_COLOR`.

> **ANSI stripping:** Bosun uses `perl` to strip ANSI sequences when it measures coloured text for box layout (`bosun style`). When `perl` is not installed it falls back to a no-op (`cat`): output still renders, but a coloured title can misalign the top border by the width of the escape codes. Making `perl` a hard requirement is tracked in [#74](https://github.com/git-stunts/shiplog/issues/74).

## Interactive detection

Bosun prompts only when it has a terminal to prompt on. It treats a session as interactive when **stdin and stderr are both terminals** (stdout may be redirected or captured). Shiplog calls Bosun as `answer=$(bosun input …)`, which turns stdout into a pipe; stderr is still attached to the terminal, so detection succeeds and the prompt appears. When stderr is redirected away from the terminal there is nowhere to show a prompt, so Bosun behaves as non-interactive even if stdout is a terminal.

- Prompts, menus and spinner frames are rendered on **stderr**. Stdout carries only the answer, so `$(…)` captures exactly the value. A script that merges the streams (`2>&1`) will see prompt text mixed into the output; keep stderr separate when capturing.
- Without a terminal: `input` reads stdin when stdin is a pipe or a non-empty regular file and otherwise returns its default; `choose` returns its default (or the first option); `confirm` exits 2 ("cannot prompt") unless `--yes` or `--default-yes` is given; `spin` runs the command with no animation.
- `BOSUN_FORCE_TTY=1` forces interactive mode regardless of the probe.

## Commands

- `bosun --version` — Prints the currently installed build identifier (git describe when available, otherwise short SHA).
- `bosun confirm` — Prompts for a yes/no response, honouring colors unless `NO_COLOR`/`--no-color` is set. Flags include `--yes` for non-interactive acceptance, `--default-yes` to make Enter (or no terminal) mean yes, and `--json` to emit `{"ok":true}`, `{"ok":false}` or `{"ok":null}`. Exit 0 on yes, 1 on no, 2 when there is no terminal to ask on. Example: `bosun confirm "Deploy?"` → `Deploy? [y/N] y` then `yes`.
- `bosun input` — Reads a single line from the user or stdin with optional `--placeholder`, `--value/--default`, `--json` and `--no-color` flags. Falls back to the provided default when stdin is empty and exits 0 with the captured text. Example: `bosun input --placeholder "Artifact" --value latest` prints `latest` when the user presses enter.
- `bosun choose` — Displays a numbered menu of options supplied as positional arguments. Supports `--header`, `--default`, `--json`, `--no-color`, and obeys `NO_COLOR`. Returns the chosen value (or the default in non-TTY mode); `bosun choose --header "Env" dev stage prod` selects an environment.
- `bosun style` — Formats text inside a bordered box; accepts `--title`, `--width`, and `--no-color`. Useful for pretty previews such as `bosun style --title "Preview" -- "Deploying api@v1"`.
- `bosun table` — Renders tab-separated data as fixed-width columns. Requires `--columns`; optional `--rows-file` and `--no-color`. Empty cells are allowed. Example: `printf 'svc\tstatus\nweb\tready\n' | bosun table --columns "Service,Status"`.
- `bosun spin` — Wraps a command with a spinner while it runs; `--title` configures the message and `--no-color` removes styling. Returns the exit code of the wrapped command, e.g. `bosun spin --title "Running tests" -- make test`.

Use `bosun help <command>` for full details and examples of each helper.

Docs and code are kept in step by `scripts/dev/check-bosun-docs.sh`, which fails when a `--flag` documented here or in a command page is missing from `scripts/bosun`, or vice versa.
