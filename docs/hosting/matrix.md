# Git Hosting Enforcement Matrix

This page summarizes what you can (and cannot) enforce on common Git hosts for Shiplog’s custom refs, and gives prescriptive configurations. Use it together with [docs/hosting/github.md](./github.md).

## TL;DR

- Custom refs (refs/_shiplog/**) are not first-class on most SaaS UIs. Prefer branch namespace (refs/heads/_shiplog/**) on SaaS to get branch protections and Required Checks.
- Self-hosted (GitHub Enterprise Server, GitLab self-managed, Gitea, Bitbucket Data Center) support server-side hooks: install `contrib/hooks/pre-receive.shiplog`.
- SaaS: enforce with Required Status Checks in CI (use the included trust-verify workflow); use Rulesets/Protected Branches to block deletes and non-FF.

## GitHub.com (SaaS)

- Server hooks: not supported.
- Recommended:
  - Namespace: `refs/heads/_shiplog/**`
  - Ruleset/Protected Branch:
    - Block deletions and non-FF
    - Require linear history
    - Require PRs; restrict who can push
    - Optional: Required Signatures (GitHub account signatures) — not Shiplog trust
  - Required Status Checks:
    - Trust Verify ([../examples/github/workflow-shiplog-trust-verify.yml](../examples/github/workflow-shiplog-trust-verify.yml))
    - Journal Verify (policy compliance and signatures; [../examples/github/workflow-shiplog-verify.yml](../examples/github/workflow-shiplog-verify.yml))
  - Ruleset JSON examples (branch namespace):
    - [../examples/github/ruleset-branch-shiplog-protect.json](../examples/github/ruleset-branch-shiplog-protect.json)
    - [../examples/github/ruleset-branch-shiplog-restricted.json](../examples/github/ruleset-branch-shiplog-restricted.json)
- Custom refs option: keep `refs/_shiplog/**` and run periodic audit workflows; cannot block pushes in real-time from the UI.

## GitHub Enterprise Server (self-hosted)

- Server hooks: supported.
- Recommended:
  - Install [`contrib/hooks/pre-receive.shiplog`](../../contrib/hooks/pre-receive.shiplog) on the bare repo.
  - Use branch or custom refs — both are enforceable with hooks.
  - Optional: mirror to a WORM remote for recovery.

## GitLab

- SaaS: no custom hooks; use Protected Branches + Required pipelines (status checks) + branch namespace `_shiplog/**`.
- Self-managed: supports server hooks — install the pre-receive hook.

## Bitbucket

- Bitbucket Cloud (SaaS): no custom hooks; use branch permissions and Required builds (pipelines), namespace `_shiplog/**`.
- Bitbucket Data Center (self-hosted): supports hooks — install the pre-receive hook.

## Gitea

- Hooks: supported (self-hosted).
- Recommendation: install pre-receive; use either custom or branch namespace.

## What to Enforce

Whether in hooks or CI checks, enforce:

- Fast-forward only (Shiplog journals and trust/policy updates)
- Trust:
  - sig_mode=chain: at least `threshold` distinct maintainer-signed commits over the same trust tree
  - sig_mode=attestation: at least `threshold` valid signatures over canonical payload (tree OID + context)
- Journals:
  - Trailer present and parseable; monotonic seq; correct env and parent
  - Policy: signatures/allowlist/ticket/required fields per policy

## Reference

- Hook: [`contrib/hooks/pre-receive.shiplog`](../../contrib/hooks/pre-receive.shiplog)
- Verifier: [`scripts/shiplog-verify-trust.sh`](../../scripts/shiplog-verify-trust.sh)
- GitHub workflow: [`docs/examples/github/workflow-shiplog-trust-verify.yml`](../examples/github/workflow-shiplog-trust-verify.yml)
- Setup: [`git shiplog setup --trust-sig-mode {chain|attestation}`](../features/setup.md)
