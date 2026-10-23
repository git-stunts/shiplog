# git shiplog ls - List Journal Entries

## Summary
`git shiplog ls` displays recent journal entries for an environment. In interactive shells, it renders entries in a formatted table via the built-in Bosun helper. When Bosun is unavailable or when running in non-interactive mode, it outputs tab-separated values instead.

## Usage
```bash
git shiplog ls [ENV] [LIMIT]
```

## Parameters
- `ENV` *(optional)* — target environment name. When omitted, Shiplog resolves the environment in this order: command argument, `--env` flag, `SHIPLOG_ENV`, and finally the tool’s default environment.

## Examples
```bash
# List entries for the default environment
git shiplog ls

# List entries for production explicitly
git shiplog ls production

# List entries for staging using the --env flag
git shiplog --env staging ls
```

## Behavior
- **Environment Resolution**: Uses environment specified by:
  1. Command line argument `[ENV]`
  2. `--env` flag
  3. `SHIPLOG_ENV` environment variable
  4. Falls back to default (`prod`) if none specified
- **Journal Reference**: Lists from `refs/_shiplog/journal/<env>`. If the ref has no entries, the command fails with an error.
- **Entry Processing**: When `jq` is available, `ls` reads values from the JSON trailer for robustness. Otherwise it falls back to subject/body parsing.
- **Columns**: Status, Service, Env, Author, Date.
- **Missing values**: Rendered as `-` (columns are kept stable; no noisy `?`).
- **LIMIT**: Caps the number of entries returned (default `20`). Must be a positive integer; anything else, a third argument or an unknown flag is an error. `--` ends option parsing (`git shiplog ls -- staging`).
- **Output**: In interactive mode with Bosun, renders a table. Otherwise prints TSV with header.

## Related Code
- `lib/commands.sh` — `cmd_ls()`
- `lib/git.sh` — `pretty_ls()` and journal helpers

## Tests
- `test/01_init_and_empty_ls.bats:25`
- `test/02_write_and_ls_show.bats:31`
