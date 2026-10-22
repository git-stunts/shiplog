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
| `version` | string (`major.minor.patch`) | Policy format version (e.g., `1.0.0`). |
| `format_compat` | string | Semantic version range indicating compatible policy parsers (e.g., ">=1.0.0 <2.0.0"). |
| `require_signed` | boolean | Require signatures for journal entries. |
| `allow_ssh_signers_file` | string | Path to SSH allowed signers file (relative paths resolve from repo root). |
| `authors` | object | Optional but recommended; defines which email addresses may author Shiplog entries (with optional per-environment overrides). |
| `deployment_requirements` | object | Per-environment guardrails for Shiplog entries. |
| `ff_only` | boolean | Enforce fast-forward updates to Shiplog refs. |
| `notes_ref` | string | Git notes ref storing log attachments. |
| `journals_ref_prefix` | string | Prefix for journal refs (usually `refs/_shiplog/journal/`). |
| `anchors_ref_prefix` | string | Prefix for anchor refs (usually `refs/_shiplog/anchors/`). |
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
| `require_ticket` | boolean | Require a ticket identifier in Shiplog entries. |
| `require_service` | boolean | Require the service field to be present. |
| `require_where` | array | Require specific `where` attributes (allowed values: `region`, `cluster`, `namespace`, `service`, `environment`). |

Missing fields inherit from the `default` entry when present.

## Validation Tips

- Run `ajv validate -s examples/policy.schema.json -d .shiplog/policy.json` in CI to block invalid policies.
- If `require_signed` is `true`, ensure `allow_ssh_signers_file` exists and is readable by automation.
- Keep semantic versioning consistent to signal breaking policy format changes.
- Before committing or publishing `.shiplog/policy.json`, run `scripts/policy/validate.sh` or `git shiplog policy validate`.
- Once a trust ref exists on the server, the pre-receive hook accepts a policy update only when the commit is signed by a current maintainer of the trust roster, contains `.shiplog/policy.json`, and passes the validator (`SHIPLOG_REQUIRE_SIGNED_POLICY`; see `docs/TRUST.md`). Publish with `SHIPLOG_POLICY_SIGN=1 scripts/shiplog-sync-policy.sh`.
- The validator enforces canonical semver versions and optional-field rules defined in `scripts/lib/policy_validate.jq`, so failing locally prevents broken pushes.
