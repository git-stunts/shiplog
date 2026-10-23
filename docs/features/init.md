# Init Command

## Summary

`git shiplog init` lets a repository receive other people's Shiplog entries. It adds a fetch refspec for the ref root (default `refs/_shiplog/*`) and turns on reflogs for every ref (`core.logAllRefUpdates`). It does not install push refspecs: Shiplog publishes its own refs (auto-push after `write`/`run`/`append`, or `git shiplog publish`).

## Prerequisites

- Run inside a Git repository.
- The remote is `SHIPLOG_REMOTE`, else `git config shiplog.remote`, else `origin`.

## Usage

```bash
git shiplog init                  # recommended
git shiplog init --push-refspecs  # opt in: a plain `git push` also sends the ledger
```

## Examples

### First-time setup

```text
$ git shiplog init
Configured the fetch refspec for refs/_shiplog/* and enabled reflogs.
```

### Upgrading a repository initialized by an older version

```text
$ git shiplog init
ℹ️ shiplog: Removed push refspecs refs/_shiplog/*:refs/_shiplog/* and HEAD from remote.origin (a plain git push behaves normally again; Shiplog publishes its own refs).
Configured the fetch refspec for refs/_shiplog/* and enabled reflogs.
```

## Behavior

- **Fetch, not forced.** Adds `<root>/*:<root>/*` to `remote.<remote>.fetch` and replaces the forced `+<root>/*:<root>/*` that older versions wrote. If someone rewrites the remote ledger, `git fetch` fails with a "rejected (non-fast-forward)" error and your local copy, the evidence, is kept.
- **No push refspecs by default (#140).** Any `remote.<remote>.push` entry makes a plain `git push` ignore `push.default`, send the ledger along with your code, and run your pre-push hooks on it; a hook rejection of one Shiplog ref then fails your code push. Shiplog does not need them: its own pushes name each ref and use `--no-verify`.
- **Cleanup of older installs.** Removes the `<root>/*:<root>/*` push refspec older versions wrote. The `HEAD` push refspec is removed too only when it was the companion Shiplog added to an otherwise empty push config; user push refspecs are never touched.
- **Opt-in.** `--push-refspecs` installs `<root>/*:<root>/*` (plus `HEAD` when the remote had no push config), records `shiplog.pushRefspecs=true` so later `init` runs keep them, and prints a warning. To undo: `git config --unset shiplog.pushRefspecs && git shiplog init`.
- Enables `core.logAllRefUpdates`, so prior object IDs of every ref stay in the reflog for recovery.
- Idempotent.

## Publishing

With auto-push on (the default when a remote exists), entries are pushed as they are written. With auto-push off, each write prints a reminder; publish with `git shiplog publish`.

## Related Code

- `lib/commands.sh` (`cmd_init`, `shiplog_config_unset_value`)

## Tests

- `test/01_init_and_empty_ls.bats`
