# Policy Resolution

## Summary
Shiplog layers policy data from several sources to produce the effective author allowlist, signing requirement, allowed signers file and notes ref used by `write`, `run`, `append` and `verify`. Every field is resolved independently through **one ordered precedence table**, for the environment the command targets. `git shiplog policy show` prints the merged result together with the source that supplied each value, so operators can audit exactly what will be enforced.

Resolution fails closed: a policy document that exists but cannot be parsed or fails validation stops the command. It never degrades to the permissive defaults.

## Usage
```bash
git shiplog policy [show] [--env ENV] [--boring|--json]
git shiplog policy validate [--ref] [--file PATH]
git shiplog policy require-signed <true|false>
git shiplog policy toggle
```

## Precedence
For each field the first source that provides a value wins. The table is the implementation (`lib/policy.sh`, `shiplog_policy_load`):

| Field | 1. CLI / environment | 2. Git config | 3. Policy document | 4. Default |
|-------|----------------------|---------------|--------------------|------------|
| Allowed authors | `SHIPLOG_AUTHORS` | `shiplog.policy.allowedAuthors` | `authors.default_allowlist` ∪ `authors.env_overrides.default` ∪ `authors.env_overrides[ENV]` | unrestricted |
| Allowed signers file | `SHIPLOG_ALLOWED_SIGNERS` | `shiplog.policy.allowedSignersFile` | `allow_ssh_signers_file` | `gpg.ssh.allowedSignersFile` (fallback only), else `<repo>/.shiplog/allowed_signers` |
| Require signed | `SHIPLOG_SIGN` | `shiplog.policy.requireSigned` | `deployment_requirements[ENV].require_signed` → `deployment_requirements.default.require_signed` → `require_signed` | `false` |
| Notes ref | `SHIPLOG_NOTES_REF` | — | `notes_ref` | `refs/_shiplog/notes/logs` |

Notes:
- **Policy document** means the policy ref (`refs/_shiplog/policy/current`, or `SHIPLOG_POLICY_REF`) when it exists, otherwise `.shiplog/policy.json` at the **repository root**. The ref always wins over the working-tree file; `policy show` reports which one was used (`Source:`), and `policy validate` checks the working-tree file first because that is what you are about to publish.
- **Environment.** `write ENV`, `verify ENV`, `--env ENV` on the subcommand, the global `--env`, and `SHIPLOG_ENV` select the environment, in that order. Per-environment fields use explicit presence checks, so `deployment_requirements.staging.require_signed: false` overrides a top-level `require_signed: true`; a missing per-env field inherits from `deployment_requirements.default`, then from the top level.
- **Authors** from the policy document are a union of the three lists (duplicates removed). The environment and Git-config layers supply a complete replacement list, never a merge.
- **Signers file.** Relative paths (and `~`) resolve against the repository root, not the current directory. The per-user `gpg.ssh.allowedSignersFile` that `git shiplog trust sync` writes is consulted only when neither policy, Git config nor environment names a file. When signing is required, `write`/`run`/`append`/`verify` refuse to continue if the file is missing; `policy show` prints a warning instead so you can repair the policy.
- **Booleans** (`SHIPLOG_SIGN`, `shiplog.policy.requireSigned`, `require_signed`, and likewise `SHIPLOG_BORING`, `SHIPLOG_DRY_RUN`, `SHIPLOG_AUTO_PUSH`, `shiplog.autoPush`, `--dry-run=VALUE`) accept `1|true|yes|on` and `0|false|no|off`, case-insensitively. Any other value is an error, never "off".

### Example Effective Policy
With `ENV=prod`, no overrides, and a populated policy ref:
```
Environment: prod
Source: policy-ref:refs/_shiplog/policy/current
Require Signed: enabled (from policy-ref:refs/_shiplog/policy/current)
Allowed Authors: deploy-bot@ci ops@example.com (from policy-ref:refs/_shiplog/policy/current)
Allowed Signers File: /repo/.shiplog/allowed_signers (from git-config:gpg.ssh.allowedSignersFile)
Notes Ref: refs/_shiplog/notes/logs (from env:SHIPLOG_NOTES_REF)
```

Run `git shiplog policy show --boring` for plain-text output or `--json` to integrate with tooling.

**Output Formats:**
- **Plain text (human)**: effective values with `(from <source>)`, per-environment rows like `Require Signed (prod): true`, and a `Warning:` line when signing is on but the signers file is missing.
- **JSON**: `env`, `source` (document), `require_signed`, `allowed_authors`, `allowed_signers_file`, `allowed_signers_file_exists`, `notes_ref`, `sources` (per-field provenance: `env:<VAR>`, `git-config:<key>`, `policy-ref:<ref>`, `policy-file:.shiplog/policy.json`, or `default`), `env_require_signed` (explicit per-environment values) and `warnings`.

## Policy File Examples

Required field:
- `version` (canonical semver string, e.g., "1.0.0"; no leading zeros).

Optional (recommended as you harden policy):
- `require_signed` (boolean, top-level) — default behavior when not set per-env.
- `allow_ssh_signers_file` (string) — allowed signers file; relative to the repository root.
- `authors.default_allowlist` (array of strings) — add to restrict commit authors; omit while bootstrapping to allow everyone.
- `authors.env_overrides.<env>` (array of strings) — added to the default list for that environment (`default` applies to every environment).
- `deployment_requirements` (object) — per-environment knobs. Each env (and the special `default` entry) may specify:
  - `require_signed` (boolean) — enforced by the CLI and the pre-receive hook.
  - `require_ticket` (boolean) — *Roadmap: validated, not yet enforced (see #79).*
  - `require_service` (boolean) — *Roadmap: validated, not yet enforced (see #79).*
  - `require_where` (array: region, cluster, namespace, service, environment) — *Roadmap: validated, not yet enforced (see #79).*
- `ff_only` (boolean) — *Roadmap: validated, not yet enforced (see #79).* Fast-forward-only updates are enforced by the pre-receive hook regardless of this field.
- `notes_ref` — Git notes ref for attached logs.
- `journals_ref_prefix`, `anchors_ref_prefix` — **reserved; not yet honored.** Journal and anchor refs derive from the ref root (`SHIPLOG_REF_ROOT` / `git config shiplog.refRoot`). The validator accepts these fields for forward compatibility only.

Unknown keys are rejected at every level (top level, `authors`, each `deployment_requirements.<env>`), so a misspelled `requre_signed` is a validation error instead of a silently open ledger.

### Minimal policy.json (permissive)
```json
{
  "version": "1.0.0",
  "require_signed": false
}
```

This permissive baseline allows any Git author and disables signing. Layer in `authors` and per-environment requirements as soon as you know who should write Shiplog entries.

### Fuller policy with environment overrides
```json
{
  "version": "1.0.0",
  "schema": "../examples/policy.schema.json",
  "allow_ssh_signers_file": ".shiplog/allowed_signers",
  "authors": {
    "default_allowlist": ["deploy-bot@ci", "releases@example.com"],
    "env_overrides": {
      "prod": ["lead@example.com", "sre@example.com"],
      "staging": ["qa@example.com"]
    }
  },
  "deployment_requirements": {
    "default": {
      "require_signed": true,
      "require_ticket": false
    },
    "prod": {
      "require_ticket": true,
      "require_service": true,
      "require_where": ["region", "cluster", "namespace"]
    },
    "staging": {
      "require_signed": false,
      "require_ticket": false
    }
  },
  "notes_ref": "refs/_shiplog/notes/logs"
}
```

Here `prod` inherits `require_signed: true` from the `default` entry while `staging` explicitly opts out. The JSON Schema that validates these files lives at `examples/policy.schema.json`; `examples/policy.json` is a complete, literal starter you can copy as-is.

### Environment-driven policies
The committed policy is literal JSON; nothing in Shiplog expands `${VAR}` placeholders. If you generate policies from CI variables, render them in a separate step before publishing, for example:

```bash
envsubst < policy.template.json > .shiplog/policy.json
git shiplog policy validate
SHIPLOG_POLICY_SIGN=1 scripts/shiplog-sync-policy.sh
```

### Validating policies
```bash
# CLI validation (jq-based structural checks); validates the working-tree file
# when present, otherwise the published ref, and says which one it checked.
git shiplog policy validate
git shiplog policy validate --ref            # the published policy ref
git shiplog policy validate --file p.json    # any file

# Scriptable validation helper (used by the CLI, the sync script and the hook)
scripts/policy/validate.sh .shiplog/policy.json
scripts/policy/validate.sh --stdin < .shiplog/policy.json

# Schema validation with ajv (advisory; CI runs this too)
npm install -g ajv-cli
ajv validate --spec=draft2020 --schema examples/policy.schema.json --data .shiplog/policy.json
```

The jq validator (`scripts/lib/policy_validate.jq`) mirrors the schema field for field: unknown keys, every typed field, the semver pattern and the ref patterns. Malformed shapes produce `<path>: object required` (exit 1) rather than a jq crash. Fixtures under `test/fixtures/policy/{valid,invalid}/` pin the behaviour of both validators.

`scripts/shiplog-sync-policy.sh` runs the validator before publishing and refuses to move the policy ref when it fails; `git shiplog policy require-signed`, `toggle` and `setup` surface that failure instead of advancing the ref.

CI automation:
- `.github/workflows/lint.yml` runs `ajv validate` automatically whenever the policy schema or tracked policy JSON changes in a PR (and on `main` pushes).

## Override Mapping
| Setting | CLI / Env | Git Config | Policy Field |
|---------|-----------|------------|--------------|
| Allowed authors | `SHIPLOG_AUTHORS` | `shiplog.policy.allowedAuthors` | `authors.*` |
| Allowed signers file | `SHIPLOG_ALLOWED_SIGNERS` | `shiplog.policy.allowedSignersFile` | `allow_ssh_signers_file` |
| Require signed commits | `SHIPLOG_SIGN` | `shiplog.policy.requireSigned` | `require_signed` / `deployment_requirements.<env>.require_signed` |
| Notes ref | `SHIPLOG_NOTES_REF` | — | `notes_ref` |

## Related Code
- `lib/policy.sh` (`shiplog_policy_load`, `shiplog_policy_enforce`)
- `lib/common.sh` (`shiplog_parse_bool`)
- `lib/commands.sh` (`cmd_policy`)
- `scripts/lib/policy_validate.jq`

## Tests
- `test/09_policy_resolution.bats` (precedence table, per-environment resolution)
- `test/29_policy_fail_closed.bats`
- `test/30_policy_fixtures.bats`
- `test/21_policy_validate.bats`
