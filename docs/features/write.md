# Write Command

## Summary

`git shiplog write` records a deployment entry as a signed empty-tree commit under `refs/_shiplog/journal/<env>`. It gathers metadata via prompts (or environment variables in boring mode) and enforces policy allowlists before appending.

## Usage

```bash
git shiplog write [ENV] \
  [--service NAME] [--status success|failed|in_progress|skipped|override|revert|finalize] \
  [--reason TEXT] [--ticket ID] \
  [--region R] [--cluster C] [--namespace NS] \
  [--image IMG] [--tag TAG] [--run-url URL]

# Non-interactive
SHIPLOG_BORING=1 git shiplog --yes write prod --service release --reason "MVP release"
```

Tip (non‑interactive/CI): avoid prompts by passing required fields via flags or env and using `--boring --yes` when appropriate.

## Behavior

- Resolves the journal environment as positional `ENV` > `--env` > `SHIPLOG_ENV` > `prod`, accepts at most one positional, and rejects names that fail `git check-ref-format --allow-onelevel`, contain whitespace or `..`, or start with `-`.
- Rejects unknown flags (`unknown write option: --log`) instead of ignoring them, so a typo can never promote the next word to an environment and create a stray journal.
- Validates the author against the resolved allowlist and performs a signing precheck when signatures are required.
- Prompts for service, status, change details, and artifact information. You can prefill or bypass prompts with flags (`--service`, `--reason`, etc.) or environment variables listed below.
- Defaults the namespace to the journal environment when left blank (e.g., `prod`).
- Generates both a human-readable header and a JSON trailer; optionally attaches NDJSON logs via `SHIPLOG_LOG`.
- Human-readable header hides missing location parts: if you only provide `env=prod`, it renders `→ prod` (no placeholders for region/cluster/namespace).
- Accepts `--yes` to skip confirmation prompts (sets `SHIPLOG_ASSUME_YES=1`).
- Fast-forwards the journal ref; aborts if the ref is missing or would require a force update.
- Automatically pushes the updated journal (and attached notes) to `origin` when available; disable with `SHIPLOG_AUTO_PUSH=0` or `--no-push`.

## Flags and Environment Overrides

| Variable | Purpose | Accepted values | Default | Example |
|----------|---------|-----------------|---------|---------|
| `SHIPLOG_ENV` | Target environment when `[ENV]` argument omitted | Any journal name | `prod` | `SHIPLOG_ENV=staging` |
| `SHIPLOG_SERVICE` | Service/component name | Free-form text | Prompted | `SHIPLOG_SERVICE=api` |
| `SHIPLOG_STATUS` | Deployment outcome | `success`, `failed`, `in_progress`, `skipped`, `override`, `revert`, `finalize` | `success` | `SHIPLOG_STATUS=failed` |
| `SHIPLOG_REASON` | Summary of change | Free-form text | Prompted | `SHIPLOG_REASON="rollout hotfix"` |
| `SHIPLOG_TICKET` | Ticket/PR reference | Free-form text | Prompted | `SHIPLOG_TICKET=OPS-4242` |
| `SHIPLOG_REGION` | Target region (where) | Free-form text | Prompted | `SHIPLOG_REGION=us-east-1` |
| `SHIPLOG_CLUSTER` | Target cluster | Free-form text | Prompted | `SHIPLOG_CLUSTER=prod-a` |
| `SHIPLOG_NAMESPACE` | Namespace/environment segment | Free-form text | Prompted | `SHIPLOG_NAMESPACE=frontend` |
| `SHIPLOG_IMAGE` | Artifact image | Free-form text | Prompted | `SHIPLOG_IMAGE=ghcr.io/acme/web` |
| `SHIPLOG_TAG` | Artifact tag | Free-form text | Prompted | `SHIPLOG_TAG=v1.2.3` |
| `SHIPLOG_RUN_URL` | CI/CD run link | URL/text | Prompted | `SHIPLOG_RUN_URL=https://ci/run/123` |
| `SHIPLOG_LOG` | Path to NDJSON log to attach as a note | File path | unset | `SHIPLOG_LOG=log.ndjson` |
| `SHIPLOG_AUTO_PUSH` | Auto-push journals to the configured remote | `1`/`true`/`yes`/`on` or `0`/`false`/`no`/`off` | `1` | `SHIPLOG_AUTO_PUSH=0` |
|  |  |  |  | Precedence: `--push`/`--no-push` > `git config shiplog.autoPush` > env > default on. Unknown values are errors. When off and a remote exists, `write` prints a "remember to publish" hint. |
| `SHIPLOG_BORING` | Non-interactive mode (disables prompts) | `1` or `0` | `0` | `SHIPLOG_BORING=1` |
| `SHIPLOG_ASSUME_YES` | Auto-confirm prompts (`--yes`) | `1` or `0` | `0` | `SHIPLOG_ASSUME_YES=1` |

## Related Code

- `lib/commands.sh:15`
- `lib/git.sh:52`
- `lib/common.sh:20`

## Tests

- `test/02_write_and_ls_show.bats:22`
- `test/05_verify_authors.bats:9`
- `test/10_boring_mode.bats:31`
- `test/17_append_and_trust.bats`

## Programmatic Append

Need to script entries without prompts? Use `git shiplog append`:

```bash
printf '{"checks": {"canary": "green"}}' | \
  git shiplog append --service deploy --status success \
    --reason "Post-release smoke" --json -
```

- Accepts the same metadata flags as `write` but runs in boring/auto-confirm mode.
- `--json` (or `--json-file path`) must contain a JSON object; Shiplog merges it into the structured trailer via `SHIPLOG_EXTRA_JSON`.
- Attach logs with `--log <path>` if desired.
