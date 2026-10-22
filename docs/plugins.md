# Shiplog Plugin Hooks (Experimental)

Plugins let you customize Shiplog without patching the core scripts. At the moment we support a single filter stage, `pre-commit-message`, which receives the commit message as plain text on stdin and expects the modified message on stdout. Scripts are executed sequentially in lexicographic order, with each script's output becoming the next script's input. This is useful for scrubbing secrets or appending metadata.

## Directory Layout

Shiplog looks for executable scripts under `.shiplog/plugins/<stage>.d/`. For example:

```bash
.shiplog/
  plugins/
    pre-commit-message.d/
      10-scrub-secrets.sh
      20-add-metadata
      30-shared -> ../common/shared-filter.sh
```

## Discovery Rule

An entry of the stage directory runs when all of the following hold:

- it is a regular file, or a symlink that resolves to a regular file;
- the resolved file is executable (`chmod +x`);
- the resolved file lives inside the plugins directory (`.shiplog/plugins` or `SHIPLOG_PLUGINS_DIR`) after symlinks are resolved. A symlink pointing outside is reported on stderr and skipped.

The name does not matter: `10-scrub`, `10-scrub.sh` and `10-scrub.py` all run. Entries run in lexicographic order of their names in the stage directory. Non-executable files are ignored silently; subdirectories are never entered.

## Script Interface

Scripts receive the stage name as `$1` and the current payload on `stdin`. They must write the transformed payload to `stdout`.

Shiplog aborts the write when:

- a script exits non-zero (`shiplog: plugin <path> failed during stage <stage>`), or
- a script exits zero but its output no longer contains a parseable JSON trailer, including empty output (`shiplog: plugin <name> removed the structured trailer during stage <stage>`).

The trailer check runs after every plugin, so a broken plugin is named and no corrupt entry is written. Keep the sentinel line `---  # structured trailer for machines` and the JSON object after it intact; add metadata to the human header above the sentinel (see `docs/reference/json-schema.md` for the layout).

Example scrubber:

> [!WARNING]
>  This is a trivial example. Real secret detection requires comprehensive patterns for AWS keys, GitHub tokens, API keys, etc.

```bash
#!/usr/bin/env bash
set -euo pipefail
awk '{ gsub(/secret-[A-Za-z0-9]+/, "[REDACTED]"); print }'
```

Example that adds a header line without touching the trailer:

```bash
#!/usr/bin/env bash
set -euo pipefail
awk '/^---  # structured trailer for machines$/ && !done { print "X-Plugin: ran"; done = 1 } { print }'
```

Place a script at `.shiplog/plugins/pre-commit-message.d/10-scrub`, make it executable (`chmod +x`), and Shiplog will run it before writing the journal entry.

## Safety Notes

- Plugins run with the same privileges as the CLI. Keep scripts under version control and review them like any other code.
- Shiplog ignores scripts whose resolved path is outside the declared plugins directory to prevent accidental traversal.
- The plugin system is experimental; more stages (post-write, log attachment, etc.) will arrive as we flesh out the extension framework.

## Custom Plugin Directory

Set `SHIPLOG_PLUGINS_DIR` to override the default `.shiplog/plugins`. This is handy if you need to share a central plugin repository across multiple repos.

```bash
export SHIPLOG_PLUGINS_DIR="$HOME/.config/shiplog/plugins"
```

Shiplog will still look for stage subdirectories inside the custom directory.
