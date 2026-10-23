# Shiplog Environment Variables

This is a compact reference for key `SHIPLOG_*` environment variables. Most can also be set via Git config or CLI flags; see feature docs for details.

## Core

- `SHIPLOG_REF_ROOT` — Root for Shiplog refs
  - Default: `refs/_shiplog`
  - Alternate (branch namespace): `refs/heads/_shiplog`
  - Affects journals/policy/trust/notes ref resolution.

- `SHIPLOG_POLICY_REF` — Policy ref (JSON file lives at `.shiplog/policy.json` inside the ref)
  - Default: `refs/_shiplog/policy/current`

- `SHIPLOG_TRUST_REF` — Trust ref (tree with `.shiplog/trust.json` and `.shiplog/allowed_signers`)
  - Default: `refs/_shiplog/trust/root`

- `SHIPLOG_NOTES_REF` — Git notes ref for attached logs (NDJSON)
  - Default: `refs/_shiplog/notes/logs`

- `SHIPLOG_ENV` — Default journal environment when omitted on commands
  - Default: `prod`

- `SHIPLOG_AUTO_PUSH` — Auto-push Shiplog refs to the configured remote when available (`write`, some `setup` flows)
  - Values: `1` (default) or `0`
  - Precedence: command flags > `git config shiplog.autoPush` > `SHIPLOG_AUTO_PUSH`.

- `SHIPLOG_REMOTE` — Remote name shiplog commands use for fetch/publish/push operations
  - Default: `origin` (or `git config shiplog.remote` when set)
  - Applies to `write` auto-push, `publish`, setup helpers, and bootstrap scripts.

- `SHIPLOG_BORING` — Non-interactive/plain mode (disables Bosun UI)
  - Values: `1` or `0` (default)

- `SHIPLOG_ASSUME_YES` — Auto-confirm prompts (same as `--yes`)
  - Values: `1` or `0` (default)

## UX

- `SHIPLOG_CONFIRM_TEXT` — Override the confirmation line printed by `git shiplog run` after a successful write.
  - Default: the log emoji `🪵`
  - Example: `export SHIPLOG_CONFIRM_TEXT="> Shiplogged"`

## Policy & Signing

- `SHIPLOG_AUTHORS` — Space-separated allowlist of authors (emails). Overrides policy.
- `SHIPLOG_ALLOWED_SIGNERS` — Path to allowed signers file (SSH). Overrides policy.
- `SHIPLOG_SIGN` — Require signing for `write` operations in this session (policy may still require it).
  - Values: `1` or `0` (default)

- `SHIPLOG_REQUIRE_SIGNED_TRUST` — Server‑side gate (hook and `scripts/shiplog-verify-trust.sh`): the trust commit itself must carry a valid signature from a current (prior‑roster) maintainer.
  - Default: `0`. Recommended `1` in production.
  - Decides only whether the commit must be signed; the quorum (attestations, or the single signed commit in chain mode) always applies and is never waived.
  - Case‑insensitive: `1|true|yes|on` enables; `0|false|no|off` disables.

- `SHIPLOG_REQUIRE_SIGNED_TRUST_MODE` — **Ignored** (a warning is printed when set). The former `either` shortcut let one commit signature waive the attestation quorum and was removed (decision D1, #113).

- `SHIPLOG_ALLOW_TRUST_THRESHOLD_UNENFORCED` — When `1`, the trust quorum is not enforced and a loud warning is printed on every push. The only escape hatch; for staged migrations only.

- `SHIPLOG_REQUIRE_SIGNED_POLICY` — Hook: policy ref updates must be signed by a current maintainer of the trust roster and contain `.shiplog/policy.json`.
  - Default: `1` when a trust ref exists on the server, `0` otherwise (so a fresh server can receive its first policy before trust).

- `SHIPLOG_ALLOW_REF_DELETE` — Hook: when `1`, deleting a Shiplog ref (`git push origin :refs/_shiplog/...`) is permitted and a warning is logged. Default: deletions are refused.

- `SHIPLOG_SIGN_TRUST` — `scripts/shiplog-bootstrap-trust.sh`: sign the genesis trust commit (`1`) or not (`0`).
  - Default: `1` when `git config user.signingkey` is set, otherwise `0` with a printed hint. `SHIPLOG_TRUST_SIGN` is a deprecated alias.

- `SHIPLOG_HOME` (server) — Shiplog checkout the hook trusts for `lib/trust-verify.sh`, `scripts/shiplog-verify-trust.sh` and the policy validator. Overrides: `SHIPLOG_TRUST_VERIFY_LIB`, `SHIPLOG_VERIFY_TRUST_BIN` (must be under a safe prefix and not group/world writable, or the push is refused).

- `SHIPLOG_DEBUG_SSH_VERIFY` — Verbose debug for trust verification (shared module, verifier script and hook).
  - Values: `1` or `0` (default)
  - Prints the module/verifier paths in use, the roster commit used for the quorum, principals discovered in `allowed_signers`, the payload tree OID and SHA‑256, per‑signature decisions (counted, duplicate key, wildcard, not a maintainer, revoked) and `git verify-commit` output on failure.

- Removed: `SHIPLOG_GPG_FORMAT` (Git detects the signature type from the signature itself), `SHIPLOG_ATTEST_PAYLOAD_MODE` and `SHIPLOG_ATTEST_BACKCOMP` (a full‑tree payload can never verify once `.sig` files are in the tree).

## Write Inputs (non-interactive)

- `SHIPLOG_SERVICE`, `SHIPLOG_STATUS`, `SHIPLOG_REASON`, `SHIPLOG_TICKET`
- `SHIPLOG_REGION`, `SHIPLOG_CLUSTER`, `SHIPLOG_NAMESPACE`
- `SHIPLOG_IMAGE`, `SHIPLOG_TAG`, `SHIPLOG_RUN_URL`
- `SHIPLOG_LOG` — Path to NDJSON log to attach as a git note
- `SHIPLOG_EXTRA_JSON` — *(internal)* Raw JSON object merged into the structured trailer; set automatically by `git shiplog run`/`git shiplog append`. Do not export this manually—provide custom data with `git shiplog append --json '{...}'` or `git shiplog append --json-file payload.json` (these flags populate the internal value for you).

See: docs/features/write.md for full semantics and examples.

## Setup Wizard (non-interactive)

- `SHIPLOG_SETUP_STRICTNESS` — `open` | `balanced` | `strict`
- `SHIPLOG_SETUP_STRICT_ENVS` — Space-separated envs for per-env strictness (strict only)
- `SHIPLOG_SETUP_AUTHORS` — Space-separated emails for allowlist (balanced)
- `SHIPLOG_SETUP_AUTO_PUSH` — `1` to push policy/trust to origin
- `SHIPLOG_SETUP_DRY_RUN` — `1` to preview without writing/syncing

## Dry Run

- `SHIPLOG_DRY_RUN` — Boolean/string flag (default `0`/`false`). When set to `1`, `true`, `yes`, or `on`, Shiplog enters dry-run mode: write/append/run/setup subcommands log intended actions without updating journals, notes, or pushing refs. Example: `export SHIPLOG_DRY_RUN=1` (bash/zsh) or `set -x SHIPLOG_DRY_RUN 1` (fish). Set `0`, `false`, `no`, or `off` to disable.

## Trust Bootstrap (non-interactive)

- `SHIPLOG_TRUST_COUNT`, `SHIPLOG_TRUST_ID`, `SHIPLOG_TRUST_THRESHOLD`, `SHIPLOG_TRUST_COMMIT_MESSAGE`
- Per-maintainer fields (1..N):
  - `SHIPLOG_TRUST_<i>_NAME`, `SHIPLOG_TRUST_<i>_EMAIL`, `SHIPLOG_TRUST_<i>_ROLE`
  - `SHIPLOG_TRUST_<i>_PGP_FPR` (optional)
  - `SHIPLOG_TRUST_<i>_SSH_KEY_PATH` (path to public key)
  - `SHIPLOG_TRUST_<i>_PRINCIPAL` (SSH principal; defaults to email)
  - `SHIPLOG_TRUST_<i>_REVOKED` (yes/no)

## CI/Tests

- `TEST_TIMEOUT_SECS` — Optional Bats timeout (seconds). Set to a positive integer to enable.
- `BATS_FLAGS` — Extra flags for Bats (e.g., `--print-output-on-failure -T`).
- `SHIPLOG_USE_LOCAL_SANDBOX` — `1` to avoid network clones in tests (default `1`).
