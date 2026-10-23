# Shiplog Tasks & Milestones

> [!WARNING]
> **FROZEN (2026-10-22).** This ledger is historical. GitHub issues are the source of truth
> and [`ROADMAP.md`](../../ROADMAP.md) holds the plan; live status is on
> [tracking issue #155](https://github.com/git-stunts/shiplog/issues/155).
> Do not add task files here.

Each task lives as a Markdown file containing JSON in one of:

- backlog/: not started
- active/: being worked on
- complete/: finished

Progress bars here are the canonical ones. Keep the root `README` progress bar in sync after updates.

## Milestones

- **MVP**: Core features usable end‑to‑end on this repo (init/write/ls/show/export/verify basics; policy/trust; installer; tests; portability).
- **Alpha**: GitHub tooling and docs mature; validation commands; CI polish; ready for limited trials.
- **Beta**: Feature‑complete; deeper docs/runbooks; operational guardrails; ready for heavy testing IRL.
- **v1.0.0**: Solid, tested, trusted; plugin architecture docs; production guidance.

## Progress Formula

Weights by estimate: big = 3, med = 2, small = 1.

- Milestone progress = `(sum of weights of completed tasks in the milestone) / (sum of weights of all tasks in the milestone)`.
- Overall progress (simple weighted blend by milestone):
  - Let `pMVP`, `pAlpha`, `pBeta`, `pV1` be milestone ratios `(0..1)`.
  - Use weights $w = {MVP: 0.4, Alpha: 0.3, Beta: 0.2, v1.0: 0.1}$.
  - Overall = $0.4*pMVP + 0.3*pAlpha + 0.2*pBeta + 0.1*pV1$.

### Update steps

1) Add/update task JSON files in the stage folders with fields: `id`, `labels`, `milestone`, `name`, `description`, `priority`, `impact`, `steps[]`, `blocked_by[]`, `notes[]`, `created`, `updated`, `estimate`, `expected_complexity`.
2) Recompute per-milestone progress by counting tasks (or with a small script).
3) Update the progress bars below and copy the overall bar to the root `README`.

## Progress

### Example Progress Bar

The following is the canonical progress bar. *Note that it is 50 characters wide, with a scale displayed beneath it.*  Use this as a template when adding progress bars or updating existing ones. *NOTE: progress bars should be placed between HTML comments, like the example:*

<!-- progress bar: example -->
### {Title}

```text
██████████████████████████████████████████████░░░░ {current%} ({completed}/{total})
|••••|••••|••••|••••|••••|••••|••••|••••|••••|••••|
0   10   20   30   40   50   60   70   80   90  100%
```
<!-- /progress bar: example -->

---

## Roadmap

**Currently Active:** Alpha

### HOTFIX (unscored)

- Backlog:
  - [SLT.HOTFIX.001 — Enforce trust threshold in pre-receive hook](docs/tasks/backlog/SLT.HOTFIX.001_enforce_trust_threshold_in_pre_receive.md)

<!-- progress bar: Overall -->
#### Overall

```text
█████████████████████████████████░░░░░░░░░░░░░░░░░ 67% (weighted blend)
|••••|••••|••••|••••|••••|••••|••••|••••|••••|••••|
0   10   20   30   40   50   60   70   80   90  100%
```
<!-- /progress bar: Overall -->

## MVP
<!-- progress bar: MVP -->
#### MVP Progress

```text
██████████████████████████████████████████████████ 100% (3/3 weighted points)
# Tasks: 1/1
|••••|••••|••••|••••|••••|••••|••••|••••|••••|••••|
0   10   20   30   40   50   60   70   80   90  100%
```
<!-- /progress bar: MVP -->

- Complete:
  - [SLT.MVP.001 — Core CLI and basic flows](docs/tasks/complete/SLT.MVP.001_core_cli_basic_flows.md)

## Alpha

<!-- progress bar: Alpha -->
#### Alpha Progress

```text
████████████████████████████████████████████░░░░░░ 88% (103/117 weighted points)
# Tasks: 68/76
|••••|••••|••••|••••|••••|••••|••••|••••|••••|••••|
0   10   20   30   40   50   60   70   80   90  100%
```
<!-- /progress bar: Alpha -->

- Backlog:
  - [SLT.ALPHA.003 — Verify command JSON output](docs/tasks/backlog/SLT.ALPHA.003_verify_json_output.md)
  - [SLT.ALPHA.004 — Validate-trailer tests](docs/tasks/backlog/SLT.ALPHA.004_validate_trailer_tests.md)
  - [SLT.ALPHA.007 — Harden docs/plugins.md usage guidance](docs/tasks/backlog/SLT.ALPHA.007_docs_plugins_usage_guidance.md)
  - [SLT.ALPHA.008 — Expand plugin safety guidance](docs/tasks/backlog/SLT.ALPHA.008_plugin_safety_guidance.md)
  - [SLT.ALPHA.009 — Clarify plugin script contract](docs/tasks/backlog/SLT.ALPHA.009_plugin_script_contract.md)
  - [SLT.ALPHA.010 — Deduplicate CI matrix package installs](docs/tasks/backlog/SLT.ALPHA.010_deduplicate_ci_matrix_packages.md)
  - [SLT.ALPHA.011 — Clarify Ubuntu build args in matrix compose](docs/tasks/backlog/SLT.ALPHA.011_ubuntu_build_args_comment.md)
  - [SLT.ALPHA.016 — Setup wizard refinements (Phase 3)](docs/tasks/backlog/SLT.ALPHA.016_setup_wizard_phase_3.md)

- Active:
  - [SLT.ALPHA.012 — Align shellcheck coverage and suppressions](docs/tasks/active/SLT.ALPHA.012_align_shellcheck_coverage_and_suppressions.md)
- Complete:
  - [SLT.ALPHA.002 — Document tooling versions in README](docs/tasks/complete/SLT.ALPHA.002_tooling_versions_in_readme.md)
  - [SLT.ALPHA.001 — Show command docs page](docs/tasks/complete/SLT.ALPHA.001_show_docs_page.md)
  - [SLT.ALPHA.005 — Policy validate command](docs/tasks/complete/SLT.ALPHA.005_policy_validate_command.md)
  - [SLT.ALPHA.020 — macOS time helpers portability](docs/tasks/complete/SLT.ALPHA.020_macos_time_helpers_portability.md)
  - [SLT.ALPHA.030 — Align policy schema, writers, and CI validation](docs/tasks/complete/SLT.ALPHA.030_policy_schema_alignment_and_validation.md)
  - [SLT.ALPHA.022 — Add CONTRIBUTING, Code of Conduct, and Security docs](docs/tasks/complete/SLT.ALPHA.022_repo_hygiene_policies.md)
  - [SLT.ALPHA.006 — Shellcheck workflow](docs/tasks/complete/SLT.ALPHA.006_shellcheck_workflow.md)
  - [SLT.ALPHA.017 — Tests for setup wizard and per-env policy](docs/tasks/complete/SLT.ALPHA.017_setup_wizard_tests.md)
  - [SLT.ALPHA.024 — Add E2E tests for trust-signed gate](docs/tasks/complete/SLT.ALPHA.024_trust_signed_gate_tests.md)
  - [SLT.ALPHA.025 — Publish/auto-push precedence tests](docs/tasks/complete/SLT.ALPHA.025_publish_precedence_tests.md)
  - [SLT.ALPHA.C001 — Add GitHub Actions bash matrix workflow](docs/tasks/complete/SLT.ALPHA.C001_github_actions_bash_matrix_workflow.md)
  - [SLT.ALPHA.C002 — Add cross-distro Docker matrix for CI](docs/tasks/complete/SLT.ALPHA.C002_cross_distro_docker_matrix_for_ci.md)
  - [SLT.ALPHA.C003 — Migrate CLI interactions to Bosun](docs/tasks/complete/SLT.ALPHA.C003_migrate_cli_interactions_to_bosun.md)
  - [SLT.ALPHA.C004 — Harden scripts/bosun runtime safety](docs/tasks/complete/SLT.ALPHA.C004_harden_bosun_runtime_safety.md)
  - [SLT.ALPHA.C005 — Enforce trust workflow in hooks and tests](docs/tasks/complete/SLT.ALPHA.C005_enforce_trust_workflow_hooks_tests.md)
  - [SLT.ALPHA.C006 — Document signing workflow and add failure-path coverage](docs/tasks/complete/SLT.ALPHA.C006_document_signing_workflow_and_failures.md)
  - [SLT.ALPHA.C007 — Align CI artifact paths](docs/tasks/complete/SLT.ALPHA.C007_align_ci_artifact_paths.md)
  - [SLT.ALPHA.C008 — Setup wizard (Phase 2)](docs/tasks/complete/SLT.ALPHA.C008_setup_wizard_phase_2.md)
  - [SLT.ALPHA.C009 — Per-env signing enforcement](docs/tasks/complete/SLT.ALPHA.C009_per_env_signing_enforcement.md)
  - [SLT.ALPHA.C010 — Non-interactive trust bootstrap](docs/tasks/complete/SLT.ALPHA.C010_non_interactive_trust_bootstrap.md)
  - [SLT.ALPHA.C011 — Test hardening: local sandbox + helpers](docs/tasks/complete/SLT.ALPHA.C011_test_hardening_local_sandbox_and_helpers.md)
  - [SLT.ALPHA.C012 — Extract devcontainer postCreate script](docs/tasks/complete/SLT.ALPHA.C012_extract_devcontainer_post_create.md)
  - [SLT.ALPHA.C013 — Harden install script](docs/tasks/complete/SLT.ALPHA.C013_harden_install_script.md)
  - [SLT.ALPHA.C014 — Harden uninstall script](docs/tasks/complete/SLT.ALPHA.C014_harden_uninstall_script.md)
  - [SLT.ALPHA.C015 — Refactor lib/common.sh JSON and logging](docs/tasks/complete/SLT.ALPHA.C015_refactor_lib_common_json_logging.md)
  - [SLT.ALPHA.C016 — Replace maybe_sync_shiplog_ref with robust helpers](docs/tasks/complete/SLT.ALPHA.C016_replace_maybe_sync_shiplog_ref.md)
  - [SLT.ALPHA.C017 — Remove legacy is_boring and standardize env vars](docs/tasks/complete/SLT.ALPHA.C017_remove_legacy_is_boring_and_standardize_env.md)
  - [SLT.ALPHA.C018 — Split policy author extraction and improve docs](docs/tasks/complete/SLT.ALPHA.C018_split_policy_author_extraction_and_docs.md)
  - [SLT.ALPHA.C019 — Improve Bosun ANSI stripping, JSON escaping, table parsing](docs/tasks/complete/SLT.ALPHA.C019_improve_bosun_ansi_json_table.md)
  - [SLT.ALPHA.C020 — Update README installer instructions](docs/tasks/complete/SLT.ALPHA.C020_update_readme_installer_instructions.md)
  - [SLT.ALPHA.C021 — Document uninstaller and auto-push behavior](docs/tasks/complete/SLT.ALPHA.C021_document_uninstaller_and_auto_push.md)
  - [SLT.ALPHA.C022 — Create .devcontainer/post-create.sh and make executable](docs/tasks/complete/SLT.ALPHA.C022_create_devcontainer_post_create_script.md)
  - [SLT.ALPHA.C023 — Update CONTRIBUTING docs paths](docs/tasks/complete/SLT.ALPHA.C023_update_contrib_readme_paths.md)
  - [SLT.ALPHA.C024 — Add warning about remote refs being preserved](docs/tasks/complete/SLT.ALPHA.C024_add_warning_about_remote_refs.md)
  - [SLT.ALPHA.C025 — Update test suite (misc refactors)](docs/tasks/complete/SLT.ALPHA.C025_update_test_suite_misc_refactors.md)
  - [SLT.ALPHA.C026 — Adjust README feature table and policy example](docs/tasks/complete/SLT.ALPHA.C026_adjust_readme_feature_table.md)
  - [SLT.ALPHA.C027 — Support canonical --yes/SHIPLOG_ASSUME_YES and remove redundant pre-scan](docs/tasks/complete/SLT.ALPHA.C027_support_yes_flag_and_env.md)
  - [SLT.ALPHA.C028 — Add JSON schema and link in docs/CI](docs/tasks/complete/SLT.ALPHA.C028_add_json_schema_and_link.md)
  - [SLT.ALPHA.C029 — Investigate and fix failing Dockerized test suite](docs/tasks/complete/SLT.ALPHA.C029_fix_dockerized_tests.md)
  - [SLT.ALPHA.C030 — Restore signing test in CI](docs/tasks/complete/SLT.ALPHA.C030_restore_signing_test.md)
  - [SLT.ALPHA.C031 — Update Docker test harness to use repo snapshot](docs/tasks/complete/SLT.ALPHA.C031_update_docker_test_harness_snapshot.md)
  - [SLT.ALPHA.C032 — docs/bosun/choose.md interactive example](docs/tasks/complete/SLT.ALPHA.C032_docs_bosun_choose_example.md)
  - [SLT.ALPHA.C033 — docs/bosun/confirm.md examples](docs/tasks/complete/SLT.ALPHA.C033_docs_bosun_confirm_examples.md)
  - [SLT.ALPHA.C034 — docs/bosun/input.md edge-case examples](docs/tasks/complete/SLT.ALPHA.C034_docs_bosun_input_edge_cases.md)
  - [SLT.ALPHA.C035 — docs/bosun/overview.md expanded](docs/tasks/complete/SLT.ALPHA.C035_docs_bosun_overview_expanded.md)
  - [SLT.ALPHA.C036 — docs/features/init.md: clarify core.logAllRefUpdates](docs/tasks/complete/SLT.ALPHA.C036_docs_features_init_core_log_ref_updates.md)
  - [SLT.ALPHA.C037 — docs/features/ls.md: ENV parameter + examples](docs/tasks/complete/SLT.ALPHA.C037_docs_features_ls_examples.md)
  - [SLT.ALPHA.C038 — docs/features/policy.md: precedence + examples + schema](docs/tasks/complete/SLT.ALPHA.C038_docs_features_policy_examples_schema.md)
  - [SLT.ALPHA.C039 — docs/features/write.md: enumerate SHIPLOG_* env vars](docs/tasks/complete/SLT.ALPHA.C039_docs_features_write_env_vars.md)
  - [SLT.ALPHA.C040 — docs/policy.md: validation guidance and authors JSON](docs/tasks/complete/SLT.ALPHA.C040_docs_policy_validation_authors_example.md)
  - [SLT.ALPHA.C041 — examples/policy.json: deterministic signers path resolution](docs/tasks/complete/SLT.ALPHA.C041_examples_policy_json_signers_resolution.md)
  - [SLT.ALPHA.C042 — examples/policy.schema.json: tighten Git ref regex](docs/tasks/complete/SLT.ALPHA.C042_examples_policy_schema_regex_tighten.md)
  - [SLT.ALPHA.C043 — lib/commands.sh: refactor helpers and simplify artifacts](docs/tasks/complete/SLT.ALPHA.C043_lib_commands_refactor_and_artifacts.md)
  - [SLT.ALPHA.C044 — lib/common.sh: JSON escape, env validation, logging](docs/tasks/complete/SLT.ALPHA.C044_lib_common_json_escape_env_validation_logging.md)
  - [SLT.ALPHA.C045 — lib/git.sh: strict mode and Bosun fallback messaging](docs/tasks/complete/SLT.ALPHA.C045_lib_git_strict_mode_and_bosun_fallback.md)
  - [SLT.ALPHA.C046 — .devcontainer/scripts/verified-download.sh: capture resolver output](docs/tasks/complete/SLT.ALPHA.C046_devcontainer_verified_download_logging.md)
  - [SLT.ALPHA.C047 — contrib/README.md: format install script block](docs/tasks/complete/SLT.ALPHA.C047_contrib_readme_format_installer_block.md)

## Beta

<!-- progress bar: Beta -->
#### Beta Progress

```text
███░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ 7% (3/39 weighted points)
# Tasks: 2/21
|••••|••••|••••|••••|••••|••••|••••|••••|••••|••••|
0   10   20   30   40   50   60   70   80   90  100%
```
<!-- /progress bar: Beta -->

- Backlog:
  - [SLT.BETA.001 — Self-hosted hooks guide](docs/tasks/backlog/SLT.BETA.001_self_hosted_hooks_guide.md)
  - [SLT.BETA.002 — Refs list subcommand](docs/tasks/backlog/SLT.BETA.002_refs_list_subcommand.md)
  - [SLT.BETA.003 — Trust show subcommand](docs/tasks/backlog/SLT.BETA.003_trust_show_subcommand.md)
  - [SLT.BETA.004 — README badges for workflows](docs/tasks/backlog/SLT.BETA.004_readme_badges.md)
  - [SLT.BETA.005 — SHIPLOG_HOME guard](docs/tasks/backlog/SLT.BETA.005_shiplog_home_guard.md)
  - [SLT.BETA.006 — Doctor command](docs/tasks/backlog/SLT.BETA.006_doctor_command.md)
  - [SLT.BETA.007 — Bosun Markdown renderer and pager](docs/tasks/backlog/SLT.BETA.007_bosun_markdown_pager.md)
  - [SLT.BETA.008 — Per-path author allowlists](docs/tasks/backlog/SLT.BETA.008_per_path_author_allowlists.md)
  - [SLT.BETA.009 — Command wrapper with log capture](docs/tasks/backlog/SLT.BETA.009_command_wrapper_log_capture.md)
  - [SLT.BETA.010 — Align lib/plugins.sh with shell policy](docs/tasks/backlog/SLT.BETA.010_align_lib_plugins_sh_shell_policy.md)
  - [SLT.BETA.011 — Optimize Bosun table parsing](docs/tasks/backlog/SLT.BETA.011_optimize_bosun_table_parsing.md)
  - [SLT.BETA.012 — Require perl for ANSI stripping](docs/tasks/backlog/SLT.BETA.012_require_perl_for_ansi_stripping.md)
  - [SLT.BETA.013 — Improve split helper implementation](docs/tasks/backlog/SLT.BETA.013_improve_bosun_split_helper.md)
  - [SLT.BETA.017 — Enforce policy fields: require_ticket/require_where/ff_only](docs/tasks/backlog/SLT.BETA.017_enforce_policy_fields_require_ticket_where_ff_only.md)
  - [SLT.BETA.018 — Anchors lifecycle: commands and flow](docs/tasks/backlog/SLT.BETA.018_anchor_commands_and_flow.md)
  - [SLT.BETA.019 — Git hosting enforcement matrix and guidance](docs/tasks/backlog/SLT.BETA.019_git_hosting_enforcement_matrix.md)
  - [SLT.BETA.020 — Setup Questionnaire (guided configuration)](docs/tasks/backlog/SLT.BETA.020_setup_questionnaire.md)

<!-- progress bar: v1.0.0 -->
#### v1.0.0 Progress

```text
░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ 0% (0/5 weighted points)
# Tasks: 0/2
|••••|••••|••••|••••|••••|••••|••••|••••|••••|••••|
0   10   20   30   40   50   60   70   80   90  100%
```
<!-- /progress bar: v1.0.0 -->
## v1.0.0

- Backlog:
  - [SLT.V1.001 — Design extension/plugin system](docs/tasks/backlog/SLT.V1.001_plugin_system.md)
  - [SLT.V1.002 — Integrate secrets scrubber](docs/tasks/backlog/SLT.V1.002_secrets_scrubber.md)

### Alpha (additional backlog)

- Backlog (new):
  - [SLT.ALPHA.019 — Align unsigned mode with trust requirement](docs/tasks/backlog/SLT.ALPHA.019_unsigned_mode_trust_requirement_alignment.md)
  - [SLT.ALPHA.021 — Fix docs test reference and ls status semantics](docs/tasks/backlog/SLT.ALPHA.021_docs_fix_test_ref_and_ls_status.md)

<!-- tasks-moc:end -->
