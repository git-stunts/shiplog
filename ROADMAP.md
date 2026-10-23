# Roadmap

Shiplog's storage layer is sound. Its enforcement layer is not. This roadmap takes the project from "the hook enforces it" as a belief to "the adversarial suite proves it" as a fact, then ships 0.5.0 with claims the tests back.

**Live status lives on tracking issue [#155](https://github.com/git-stunts/shiplog/issues/155).** `scripts/roadmap-check.sh` evaluates every definition-of-done check below and ticks or un-ticks the goal and issue boxes on #155. CI runs it on every push to `main` and daily (`.github/workflows/roadmap.yml`). Humans do not tick boxes; the checker does.

Run it yourself:

```bash
scripts/roadmap-check.sh            # table of goals and checks
scripts/roadmap-check.sh --goal G3  # one goal
scripts/roadmap-check.sh --update   # also update #155 (needs gh auth)
```

## Decisions

- **D1 — Attestation is the only N-of-M quorum mode.** A Git commit carries one signature. Chain mode is reduced to a single signed trust commit (threshold 1). Recorded 2026-10-22; see #96 and #111.
- **D2 — GitHub issues are the source of truth.** `docs/tasks/` is frozen as history. The 67 audit issues carry label `audit-2026-10`.
- **D3 — #155 is the live checklist.** This file holds goals, scope and definitions of done. The checker owns the checkboxes.
- **D4 — Tests run only in Docker (`make test`).** The checker never runs the suite; test-based checks read the latest CI result on `main`.

## Goals

- [ ] G1: Self-steering harness — checker, CI job, frozen task ledger
- [ ] G2: Adversarial trust suite — red before any fix
- [ ] G3: Trust verification rewrite — one module, prior-state roster, key-based quorum
- [ ] G4: Installer and uninstaller safety — guards and real smoke tests
- [ ] G5: Policy resolution rewrite — fail closed, one precedence table
- [ ] G6: One ref root — every ref, client and server
- [ ] G7: Ledger and CLI correctness — the long tail
- [ ] G8: CI, tests and docs tell the truth
- [ ] G9: Shiplog ships Shiplog — this repo records its own CI runs and releases
- [ ] G10: Release 0.5.0 — README claims restored and proven

Sequence: G1 → G2 → G3 → G4. Then G5 and G6 in parallel. Then G7 and G8 in parallel. G9 after G3 and G6. G10 last. A later goal must not start its PR review before the earlier goal is green on #155, except where noted.

---

## G1: Self-steering harness

The roadmap must check itself. This goal adds the checker script, the CI job that runs it, and freezes the old task ledger so there is one place to look.

### Scope

In: `scripts/roadmap-check.sh`, `.github/workflows/roadmap.yml`, the `## Goals` section on #155, a FROZEN banner on `docs/tasks/README.md`, retirement of the task-progress CI job.
Out: any product code.

### Definition of done (checks)

- `file:scripts/roadmap-check.sh`
- `exec:scripts/roadmap-check.sh --self-test`
- `file:.github/workflows/roadmap.yml`
- `issue-body:155:## Goals`
- `grep:docs/tasks/README.md:FROZEN`
- `no-file:.github/workflows/task-progress.yml`

### Tasks

- [ ] Land this file, the checker and the workflow (PR from `roadmap/2026-10-audit`).
- [ ] Add the `## Goals` section to #155 with the nine goal lines above.

---

## G2: Adversarial trust suite

Write the attacks before the fixes. One Bats file holds every hostile scenario from the P0/P1 trust findings. It runs in CI as a separate job that is **allowed to fail** until G3 flips it to blocking. The file is the specification for G3.

### Scope

In: `test/27_trust_adversarial.bats`, a `adversarial` job in `ci.yml` with `continue-on-error: true`, any test helpers needed to craft hostile trust commits and attestations.
Out: fixes. A G2 PR must not touch `lib/`, `scripts/`, or `contrib/`.

### Definition of done (checks)

- `file:test/27_trust_adversarial.bats`
- `count-ge:test/27_trust_adversarial.bats:^@test:10`
- `grep:.github/workflows/ci.yml:adversarial`
- `grep:test/27_trust_adversarial.bats:self-certify` — rotation signed only by a key the prior roster does not contain is rejected (#94)
- `grep:test/27_trust_adversarial.bats:ref-delete` — `push :refs/_shiplog/*` is rejected (#95)
- `grep:test/27_trust_adversarial.bats:one-key-quorum` — one key, N attestations, threshold N is rejected (#96)
- `grep:test/27_trust_adversarial.bats:wildcard-principal` — `* <key>` roster cannot inflate the count (#96)
- `grep:test/27_trust_adversarial.bats:roster-swap` — a signed journal entry is rejected after the roster drops the key (#109)
- `grep:test/27_trust_adversarial.bats:signed-journal-accepted` — a signed entry by a roster key is accepted with no `gpg.ssh.allowedSignersFile` on the server (#109)
- `grep:test/27_trust_adversarial.bats:unsigned-policy` — an unsigned policy update is rejected when a trust ref exists (#114)
- `grep:test/27_trust_adversarial.bats:either-waives` — `MODE=either` with one commit signature and zero attestations is rejected at threshold 2 (#113)
- `grep:test/27_trust_adversarial.bats:genesis-threshold-1` — a threshold-1 genesis push is accepted (#111)
- `grep:test/27_trust_adversarial.bats:shared-verifier-path` — the hook runs the shared verifier when `SHIPLOG_HOME` is set (#110)

### Tasks

- [ ] #94 #95 #96 #109 #110 #111 #113 #114 provide the scenarios; this goal writes only the tests.
- [ ] Each test name carries its tag (for example `@test "self-certify: ..."`).

---

## G3: Trust verification rewrite

Replace the duplicated, divergent verification code in the hook and the verifier script with one shared module. Verify every trust update against the **prior** roster. Count distinct unrevoked maintainer keys. Use the Git option that exists. Refuse deletes. Authenticate the policy ref. Make G2 green and blocking.

### Scope

In: new `lib/trust-verify.sh` sourced by `contrib/hooks/pre-receive.shiplog` and `scripts/shiplog-verify-trust.sh`; `scripts/shiplog-trust-sign.sh` payload fix; `scripts/shiplog-bootstrap-trust.sh` attestation genesis; `docs/TRUST.md`; flip the `adversarial` CI job to blocking.
Out: ref-root handling in the hook (G6), policy resolution on the client (G5).

### Definition of done (checks)

- `issues-closed:94,95,96,109,110,111,112,113,114,116,136,137,138,153,154`
- `file:lib/trust-verify.sh`
- `grep:contrib/hooks/pre-receive.shiplog:trust-verify.sh`
- `grep:scripts/shiplog-verify-trust.sh:trust-verify.sh`
- `grep-zero:bin lib scripts contrib:GIT_SSH_ALLOWED_SIGNERS`
- `grep-zero:scripts/shiplog-verify-trust.sh lib/trust-verify.sh:format='%ae'`
- `grep-zero:.github/workflows/ci.yml:continue-on-error`
- `ci-main-green:ci.yml`

### Tasks

- [ ] #94 Prior-state roster for non-genesis updates
- [ ] #95 Refuse ref deletion; `SHIPLOG_ALLOW_REF_DELETE=1` escape hatch with warning
- [ ] #96 Key-based quorum via `ssh-keygen -Y find-principals`; honor `revoked`; per D1 attestation-only
- [ ] #109 `-c gpg.ssh.allowedSignersFile=` everywhere (also `lib/git.sh`)
- [ ] #110 Verifier discovery via `SHIPLOG_HOME` + `path_is_safe`; absolute `GIT_DIR`
- [ ] #111 Genesis threshold-1 accepted
- [ ] #112 Sign helper and verifier share one payload builder; bootstrap writes the genesis attestation
- [ ] #113 Remove the `either` shortcut
- [ ] #114 Policy ref updates signed by a current maintainer; empty tree rejected
- [ ] #116 Validator exit codes captured under errexit (hook and CLI)
- [ ] #136 Per-env `require_signed:false` overrides global `true` (hook side; G5 does the client)
- [ ] #137 Bootstrap lowercases `sig_mode`
- [ ] #138 `trust-sync` stores an absolute path
- [ ] #153 Bootstrap signs the genesis commit by default when a key exists
- [ ] #154 Temp files, dead escape hatch, SAFE_PREFIXES width, dead `gpg.format`

---

## G4: Installer and uninstaller safety

Nothing Shiplog ships may delete or reset a directory it did not create.

### Scope

In: `scripts/install-shiplog.sh`, `scripts/uninstall-shiplog.sh`, `test/12_installer_smoke.bats` rewritten to run in-container, executable bits and a CI check for them.
Out: `install-shiplog-deps.sh` behavior beyond the `--silent` fix.

### Definition of done (checks)

- `issues-closed:93,105,106,107,134,144`
- `grep-zero:test/12_installer_smoke.bats:skip`
- `grep:scripts/uninstall-shiplog.sh:shiplog_guard_install_dir`
- `grep:scripts/install-shiplog.sh:shiplog_guard_install_dir`
- `exec-bits:scripts bin contrib/hooks`
- `ci-main-green:ci.yml`

### Tasks

- [ ] #93 Uninstaller: shared guard (`shiplog_guard_install_dir`), checkout verification, base ≠ target
- [ ] #107 Installer: same guard before `reset --hard` and `rm -rf`
- [ ] #106 Uninstaller: no GNU `timeout` dependency
- [ ] #105 Executable bits on helper scripts; CI check
- [ ] #134 `test/12` runs without Docker-in-Docker and exercises the installer
- [ ] #144 `--silent` flag and `--dry-run` profile touch

---

## G5: Policy resolution rewrite

One ordered precedence table per field. Fail closed on parse errors. Thread the target environment through. Parse booleans once. Make the jq validator agree with the JSON schema.

### Scope

In: `lib/policy.sh`, `lib/common.sh` (`shiplog_parse_bool`), `scripts/lib/policy_validate.jq`, `examples/policy.schema.json`, `test/fixtures/policy/{valid,invalid}/`, a table-driven `test/09_policy_resolution.bats`, `scripts/shiplog-sync-policy.sh`, `cmd_policy` split into load vs enforce.
Out: ref layout fields (G6), hook-side per-env logic (G3).

### Definition of done (checks)

- `issues-closed:99,102,103,104,118,120,126,127,128,129,130,141,142,156,159,160`
- `grep:lib/common.sh:shiplog_parse_bool`
- `grep:test/09_policy_resolution.bats:precedence`
- `count-ge:test/fixtures/policy/valid:*.json:3`
- `count-ge:test/fixtures/policy/invalid:*.json:3`
- `ci-main-green:ci.yml`

### Tasks

- [ ] #156 Malformed policy stops the command
- [ ] #102 Policy/env signers path beats `gpg.ssh.allowedSignersFile`
- [ ] #103 Env beats git config beats policy; dead code removed; docs consistent
- [ ] #104 Non-boolean `require_signed` rejected by validator and runtime
- [ ] #127 `deployment_requirements.default` inheritance
- [ ] #128 Validator parity with schema; no jq crashes
- [ ] #129 `.shiplog/*` resolved from repo root
- [ ] #99 Positional ENV drives policy resolution
- [ ] #118 `--dry-run=True`
- [ ] #120 Auto-push precedence and boolean parsing
- [ ] #126 `cmd_policy` does not require a signers file
- [ ] #159 `policy validate` checks the working-tree file
- [ ] #130 `sync-policy` runs the real validator; signing default documented
- [ ] #141 `journals_ref_prefix` / `anchors_ref_prefix`: implement or mark reserved
- [ ] #142 `examples/policy.json` is literal
- [ ] #160 `setup --authors` for every strictness

---

## G6: One ref root

`SHIPLOG_REF_ROOT` and `shiplog.refRoot` govern every Shiplog ref on the client and the server.

### Scope

In: `bin/git-shiplog` ref derivation, every `refs/_shiplog/` literal in `lib/commands.sh`, hook ref matching by root, notes ref resolution in `show`/`publish`, a branch-namespace end-to-end test.
Out: the migrate script's logic (exec bit is G4).

### Definition of done (checks)

- `issues-closed:100,115,123`
- `grep-zero:lib/commands.sh:refs/_shiplog/`
- `grep:contrib/hooks/pre-receive.shiplog:SHIPLOG_REF_ROOT`
- `file:test/31_ref_root_namespace.bats`
- `ci-main-green:ci.yml`

### Tasks

- [ ] #100 Resolve root (env > config > default); derive policy/trust/notes/journal/anchors
- [ ] #115 Hook matches journals and anchors under the configured root
- [ ] #123 `show`/`publish`/`ls`/`export-json` use the resolved notes ref

---

## G7: Ledger and CLI correctness

The long tail. Each item has its own issue with a test. Items are independent and may be worked in parallel by separate agents; one PR per issue or per tight cluster.

### Scope

In: the issues below.
Out: anything already owned by G3–G6.

### Definition of done (checks)

- `issues-closed:97,98,101,108,117,119,121,122,124,125,131,139,140,143,145,157,158`
- `ci-main-green:ci.yml`

### Tasks

- [ ] #97 `---` in header text cannot corrupt the trailer; status enum enforced
- [ ] #98 `run` write failure prints the reason and the log path
- [ ] #101 `publish ENV`
- [ ] #108 Bosun TTY detection when captured
- [ ] #117 `write` rejects unknown flags; env name validation
- [ ] #119 Per-command `--help`
- [ ] #121 `--json` cannot overwrite reserved trailer keys
- [ ] #122 `run` waits for its log writers
- [ ] #124 `verify` fails on a missing journal
- [ ] #125 `export-json` emits one line per entry
- [ ] #131 `bosun table` accepts empty cells
- [ ] #139 Parser hygiene (five items)
- [ ] #140 Decision: `init` push refspecs
- [ ] #143 Plugin contract and trailer guard
- [ ] #145 Bosun docs match code
- [ ] #157 `shiplog_confirm` honors "no"
- [ ] #158 `SHIPLOG_AUTHOR_*` sets author and committer

---

## G8: CI, tests and docs tell the truth

A green check must check something. A skipped test must have a reason that is still true. A sentence in the docs must describe the code.

### Scope

In: `lint.yml` (AJV inputs, bosun shellcheck, root Markdown), `ci.yml` signing leg, unskipping `test/06` and `test/14`, test-suite hygiene, Makefile timeout forwarding, `scripts/dev/check-md-fences.sh`, `scripts/dev/check-md-links.sh`, task-ledger generators, docs accuracy sweep, AGENTS.md diet.
Out: README rewrite (own PR) and release notes (G9).

### Definition of done (checks)

- `issues-closed:132,133,135,146,147,148,149,150,152`
- `file:scripts/dev/check-md-fences.sh`
- `file:scripts/dev/check-md-links.sh`
- `exec:scripts/dev/check-md-fences.sh`
- `exec:scripts/dev/check-md-links.sh`
- `size-lt:AGENTS.md:8192`
- `grep-zero:AGENTS.md:^{"date"`
- `grep-zero:test/06_verify_signatures_signed_build.bats:skip`
- `grep:Makefile:TEST_TIMEOUT_SECS`
- `ci-main-green:ci.yml`

### Tasks

- [ ] #133 AJV job validates real files and a negative fixture
- [ ] #135 Signing verification tests run; GPG matrix leg decided
- [ ] #132 `TEST_TIMEOUT_SECS` reaches the container; one default
- [ ] #146 Bosun shellchecked; root Markdown linted on push
- [ ] #147 ci-matrix header, compose key, dead script
- [ ] #148 Test-suite hygiene (numbers, traps, dead assertion, shebang)
- [ ] #149 Task ledger generators and links (then frozen per D2)
- [ ] #150 Docs accuracy sweep with fence and link checks
- [ ] #152 AGENTS.md under 8 KB; logs archived

---

## G9: Shiplog ships Shiplog

A deployment ledger that does not log its own deployments is a demo, not a tool. This repository records its own CI runs and releases with Shiplog, on GitHub.com, under the branch namespace — which also exercises the SaaS enforcement path (rulesets + `verify` as a required check) for real. Tracked in #163.

### Scope

In: `.shiplog/policy.json` for this repo; policy and trust published under `refs/heads/_shiplog/**`; `ci.yml` records each `main` run to `refs/heads/_shiplog/journal/ci` and runs `git shiplog verify ci` as a required PR check; the release workflow records signed `release` entries; README links the live ledger; ruleset import documented.
Out: product code. Requires G3 and G6.

### Definition of done (checks)

- `issues-closed:163`
- `grep:.github/workflows/ci.yml:git shiplog run`
- `grep:.github/workflows/ci.yml:git shiplog verify`
- `grep:.github/workflows/ci.yml:pull_request`
- `exec:gh api repos/git-stunts/shiplog/rules/branches/main --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | any(test("verify"))' | grep -qx true`
- `file:.shiplog/policy.json`
- `exec:git ls-remote --exit-code origin refs/heads/_shiplog/journal/ci`
- `grep:README.md:journal/ci`
- `ci-main-green:ci.yml`

### Tasks

- [ ] #163 Record CI runs and releases; verify as required check; README link; ruleset docs

---

## G10: Release 0.5.0

Ship it. The README may claim "cryptographically signed, append-only, N-of-M approved" only because `test/27_trust_adversarial.bats` is blocking and green.

### Scope

In: version decision (#151), CHANGELOG, release notes, tag `v0.5.0`, README status section flipped from "in dry dock" to "seaworthy", all `audit-2026-10` issues closed.
Out: new features.

### Definition of done (checks)

- `issues-closed:151`
- `label-all-closed:audit-2026-10`
- `tag:v0.5.0`
- `grep:CHANGELOG.md:0.5.0`
- `grep:README.md:27_trust_adversarial`
- `ci-main-green:ci.yml`

### Tasks

- [ ] #151 Reconcile tags, CHANGELOG, RELEASE_NOTES, docs/releases
- [ ] Flip the README status section; link the adversarial suite as the proof
- [ ] Tag `v0.5.0` (owner action)
