# Shiplog Policy Reference

This document summarizes the fields accepted by `.shiplog/policy.json`. A formal JSON Schema is published at [`examples/policy.schema.json`](../examples/policy.schema.json). Validate changes locally with:

```bash
# Syntax check
jq '.' .shiplog/policy.json >/dev/null

# Schema validation
npm install -g ajv-cli
ajv validate --spec=draft2020 --schema examples/policy.schema.json --data .shiplog/policy.json
```

## Top-level Fields

| Field | Type | Description |
|-------|------|-------------|
| `schema` | string | Optional URI reference to the JSON Schema used for validation (e.g., "https://example.com/policy.schema.json"). |
| `version` | string (`major.minor.patch`) | Policy format version (e.g., `1.0.0`). Canonical semver: no leading zeros. |
| `format_compat` | string | Semantic version range indicating compatible policy parsers (e.g., ">=1.0.0 <2.0.0"). |
| `require_signed` | boolean | Require signatures for journal entries. Must be a JSON boolean; strings such as `"yes"` are rejected by the validator and by the CLI. |
| `allow_ssh_signers_file` | string | Path to SSH allowed signers file (relative paths resolve from the repository root). Takes precedence over the per-user `gpg.ssh.allowedSignersFile`, which is only a fallback. |
| `authors` | object | Optional but recommended; defines which email addresses may author Shiplog entries (with optional per-environment overrides). Only `default_allowlist` and `env_overrides` are accepted. |
| `deployment_requirements` | object | Per-environment guardrails for Shiplog entries. |
| `ff_only` | boolean | *Roadmap: validated but not yet enforced (see #79).* Fast-forward-only updates are always enforced by the pre-receive hook. |
| `notes_ref` | string | Git notes ref storing log attachments. |
| `journals_ref_prefix` | string | **Reserved; not yet honored.** Journal refs derive from the ref root (`SHIPLOG_REF_ROOT` / `shiplog.refRoot`). Accepted for forward compatibility only. |
| `anchors_ref_prefix` | string | **Reserved; not yet honored.** Anchor refs derive from the ref root. Accepted for forward compatibility only. |

Unknown keys are rejected at the top level, inside `authors`, and inside every `deployment_requirements.<env>` entry.
## Authors

```json
"authors": {
  "default_allowlist": [
    "deploy-bot@ci",
    "releases@example.com"
  ],
  "env_overrides": {
    "prod": ["lead@example.com", "sre@example.com"],
    "staging": ["qa@example.com"],
    "default": ["dev@example.com"]
  }
}
```

- `default_allowlist`: baseline set of permitted author emails.
- `env_overrides`: per-environment author lists that are ADDED to (not replacing) the default_allowlist. Final allowlist = default_allowlist + env_overrides[environment], deduplicated.

## Deployment Requirements

Each key under `deployment_requirements` corresponds to an environment name (e.g., `prod`, `staging`, `default`). The object supports:

| Field | Type | Description |
|-------|------|-------------|
| `require_signed` | boolean | Require signatures for this environment. Enforced by the CLI and the pre-receive hook. |
| `require_ticket` | boolean | Require a ticket identifier in Shiplog entries. *Roadmap: not yet enforced (see #79).* |
| `require_service` | boolean | Require the service field to be present. *Roadmap: not yet enforced (see #79).* |
| `require_where` | array | Require specific `where` attributes (allowed values: `region`, `cluster`, `namespace`, `service`, `environment`). *Roadmap: not yet enforced (see #79).* |

Lookup order for each per-environment field: `deployment_requirements.<env>.<field>` when present (an explicit `false` counts), then `deployment_requirements.default.<field>`, then the top-level field, then the built-in default. The CLI resolves the environment named on the command (`write prod`, `verify staging`, `--env`), not the default environment.

## Validation Tips

- Run `ajv validate -s examples/policy.schema.json -d .shiplog/policy.json` in CI to block invalid policies.
- If `require_signed` is `true`, ensure `allow_ssh_signers_file` exists and is readable by automation.
- Keep semantic versioning consistent to signal breaking policy format changes.
- Before committing or publishing `.shiplog/policy.json`, run `scripts/policy/validate.sh` or `git shiplog policy validate`. The CLI validates the working-tree file when it exists (and notes when it differs from the published ref); use `--ref` to check the published policy or `--file PATH` for any file.
- `scripts/shiplog-sync-policy.sh` runs the same validator and refuses to publish an invalid document. It signs the policy commit when `git config user.signingkey` is set (override with `SHIPLOG_POLICY_SIGN=1|0`).
- A policy document that fails validation stops `write`, `run`, `append`, `verify` and `policy show`; Shiplog never falls back to the permissive defaults while a broken document exists.
- The validator enforces canonical semver versions and optional-field rules defined in `scripts/lib/policy_validate.jq`, so failing locally prevents broken pushes.
