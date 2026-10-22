# Shiplog Contrib

Supporting assets that help you wire Shiplog into a larger deployment workflow.

## Hooks

- `hooks/pre-receive.shiplog` – server-side guard (requires: git ≥ 2.35, jq ≥ 1.6, bash, OpenSSH 8.2+
  `ssh-keygen`). It enforces:
  - fast-forward pushes to `refs/_shiplog/journal/*`, `refs/_shiplog/anchors/*`, the policy ref and the trust ref;
  - **no deletions** of any Shiplog ref (`SHIPLOG_ALLOW_REF_DELETE=1` is the emergency override and logs a warning);
  - trust updates verified against the **prior** roster: attestation quorum counted in distinct, unrevoked
    maintainer keys; chain mode = one signed trust commit, threshold 1 only (decision D1);
  - an optional trust-commit signature gate (`SHIPLOG_REQUIRE_SIGNED_TRUST=1`, recommended in production);
  - policy updates signed by a current maintainer, containing a valid `.shiplog/policy.json`
    (`SHIPLOG_REQUIRE_SIGNED_POLICY`, default on once a trust ref exists);
  - journal commit signatures verified against the roster from the trust ref
    (`git -c gpg.ssh.allowedSignersFile=<roster> verify-commit`; the server needs no static signers file);
  - author allowlists and per-environment `require_signed` pulled from the active policy.

The hook is one file but it is not standalone: it sources `lib/trust-verify.sh` (the one trust
verification module, shared with `scripts/shiplog-verify-trust.sh`) and runs the shared verifier and the
policy validator from a Shiplog checkout. Install a checkout the git user owns and that nobody else can
write to, then tell the hook where it is:

```bash
#!/usr/bin/env bash
set -euo pipefail

SHIPLOG_SRC=/srv/shiplog          # checkout owned by the git user, chmod -R go-w
BARE=/srv/git/your.git

[ -f "$SHIPLOG_SRC/contrib/hooks/pre-receive.shiplog" ] || { echo "checkout not found" >&2; exit 1; }
cp "$SHIPLOG_SRC/contrib/hooks/pre-receive.shiplog" "$BARE/hooks/pre-receive"
chmod 0755 "$BARE/hooks/pre-receive"

# Defense in depth: the hook refuses deletes and non-fast-forwards itself, Git should too.
git --git-dir="$BARE" config receive.denyDeletes true
git --git-dir="$BARE" config receive.denyNonFastForwards true

echo "Hook installed. Export SHIPLOG_HOME=$SHIPLOG_SRC and SHIPLOG_REQUIRE_SIGNED_TRUST=1 in the hook environment."
```

How the environment reaches hooks depends on your server (sshd `SetEnv`, a wrapper script that exports
variables and `exec`s the real hook, Gitea/Gitolite hook environments). The adversarial test suite uses
a wrapper; see `test/helpers/trust_adversarial.bash`.

### Discovery and safety (fail closed)

| What | Where the hook looks | Override |
| --- | --- | --- |
| Trust module | `$SHIPLOG_HOME/lib/trust-verify.sh`, then `<hooks dir>/../lib/trust-verify.sh` | `SHIPLOG_TRUST_VERIFY_LIB` |
| Shared verifier | `$SHIPLOG_HOME/scripts/shiplog-verify-trust.sh` (else the sourced module is used) | `SHIPLOG_VERIFY_TRUST_BIN` |
| Policy validator | `$SHIPLOG_HOME/scripts/policy/validate.sh`, `scripts/lib/policy_validate.jq` | `SHIPLOG_POLICY_VALIDATE_BIN`, `SHIPLOG_POLICY_VALIDATOR` |

Only files beneath `SHIPLOG_HOME`, the hooks directory or the repository directory are sourced or run,
and never files that are group/world writable. The parent of the repository directory (shared by every
repository on the host) is **not** trusted, and `"$GIT_DIR/.."` is never consulted. An override that
points at an unsafe file makes the hook refuse the push with a message naming the path. The hook
exports an absolute `GIT_DIR` before running the verifier.

### Hook environment variables

- `SHIPLOG_HOME` — Shiplog checkout on the server (required unless `lib/` is copied next to `hooks/`).
- `SHIPLOG_REQUIRE_SIGNED_TRUST=1` — the trust commit itself must be signed by a current maintainer. Default `0`.
  `SHIPLOG_REQUIRE_SIGNED_TRUST_MODE` is ignored (a warning is printed); the quorum always applies.
- `SHIPLOG_REQUIRE_SIGNED_POLICY` — default `1` when a trust ref exists, `0` otherwise.
- `SHIPLOG_ALLOW_REF_DELETE=1` — permit deleting a Shiplog ref (emergency recovery; warning logged).
- `SHIPLOG_ALLOW_TRUST_THRESHOLD_UNENFORCED=1` — skip the trust quorum (loud warning; staged migrations only).
- `SHIPLOG_REQUIRE_SEPARATE_SIGNERS` — keep `1` unless you intentionally allow trust commits without `allowed_signers`.
- `SHIPLOG_ALLOW_MISSING_POLICY=1` / `SHIPLOG_ALLOW_MISSING_TRUST=1` — relaxed bootstrap mode (below).
- `SHIPLOG_DEBUG_SSH_VERIFY=1` — verbose diagnostics (module/verifier paths, roster commit, per-signature decisions).

## CI Helpers

- `scripts/shiplog-verify-trust.sh --old <oid|0> --new <oid> [--ref <ref>]` – the same verification the hook
  runs, for SaaS required checks. Exit 0 = accept.
- `scripts/shiplog-trust-sign.sh [--principal you@example.com] [--message-only] <commit>` – create an attestation
  (`.shiplog/trust_sigs/<principal>.sig`) over the canonical payload, or print that payload.
- `scripts/shiplog-sync-policy.sh` – publishes `.shiplog/policy.json` to the policy ref as a fast-forward commit
  (does not push). Set `SHIPLOG_POLICY_SIGN=1` so the commit is signed by a maintainer, which the hook requires
  once a trust ref exists:

```bash
SHIPLOG_POLICY_SIGN=1 ./scripts/shiplog-sync-policy.sh
git push origin refs/_shiplog/policy/current
```

## Policy Templates

- `examples/policy.json` – starter policy you can copy into `.shiplog/policy.json` before publishing with the sync
  script (for example: `cp examples/policy.json .shiplog/policy.json`).

## Suggested Workflow

1. Bootstrap trust (`scripts/shiplog-bootstrap-trust.sh`) and push `refs/_shiplog/trust/root` first.
2. Update `.shiplog/policy.json` in a branch; after merge run `SHIPLOG_POLICY_SIGN=1 scripts/shiplog-sync-policy.sh`
   and push `refs/_shiplog/policy/current`.
3. The pre-receive hook validates writes to the Shiplog refs using that policy and roster.

### Optional: Relaxed Mode (no trust/policy during bootstrap)

By default, the hook requires both trust and policy refs for journal pushes. To allow journal pushes before
those are set up:

- `SHIPLOG_ALLOW_MISSING_POLICY=1` – allow a missing policy ref; defaults to an open policy (`require_signed=false`,
  empty author allowlist).
- `SHIPLOG_ALLOW_MISSING_TRUST=1` – allow a missing trust ref; skips `trust_oid` equality checks when policy does not
  require signatures.

Note: if your policy sets `require_signed=true`, the hook still needs the trust roster to verify signatures; the
relaxations only apply when signatures are not required.

Feel free to adapt these assets to match your infrastructure (GitHub, GitLab, Gitea, etc.).
