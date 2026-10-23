# shellcheck shell=bash
# shiplog command implementations

has_remote_origin() {
  local remote
  remote=$(shiplog_remote_name)
  git config --get remote."$remote".url >/dev/null 2>&1
}

get_remote_oid() {
  local ref="$1" output remote
  remote=$(shiplog_remote_name)
  if ! output=$(git ls-remote "$remote" "$ref" 2>&1); then
    printf '⚠️ shiplog: unable to query %s for %s (%s)\n' "$remote" "$ref" "$output" >&2
    return 1
  fi
  printf '%s' "$(printf '%s\n' "$output" | awk 'NF{print $1; exit}')"
}

sanitize_remote_error() {
  local raw_input normalized_input first_line="" second_line="" trimmed_line="" current_line total_lines=0 extra_lines=0

  raw_input="${1:-}"

  SANITIZE_REMOTE_EXTRA_LINES=0
  SANITIZE_REMOTE_TOTAL_LINES=0

  if [ -z "$raw_input" ]; then
    printf ''
    return 0
  fi

  normalized_input=$(printf '%s' "$raw_input" | tr -d '\r')

  while IFS= read -r current_line; do
    case "$current_line" in
      *[![:space:]]*)
        total_lines=$((total_lines + 1))
        trimmed_line=$(printf '%s' "$current_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$total_lines" in
          1) first_line="$trimmed_line" ;;
          2) second_line="$trimmed_line" ;;
          *) extra_lines=$((extra_lines + 1)) ;;
        esac
        ;;
    esac
  done <<<"$normalized_input"

  SANITIZE_REMOTE_EXTRA_LINES=$extra_lines
  SANITIZE_REMOTE_TOTAL_LINES=$total_lines

  case $total_lines in
    0) printf '' ;;
    1) printf '%s' "$first_line" ;;
    2) printf '%s; %s' "$first_line" "$second_line" ;;
    *) printf '%s; %s; (+%d more lines)' "$first_line" "$second_line" "$extra_lines" ;;
  esac
}

fast_forward_ref() {
  local ref="$1" context="${2:-fast-forward}" remote
  remote=$(shiplog_remote_name)
  local fetch_output
  if ! fetch_output=$(git fetch "$remote" "$ref:$ref" 2>&1); then
    die "shiplog: failed to ${context} $ref from $remote: $fetch_output"
  fi
}

check_divergence() {
  local local_oid="$1" remote_oid="$2"
  if [ -z "$remote_oid" ]; then
    printf 'remote-missing'
    return 0
  fi
  if [ "$local_oid" = "$remote_oid" ]; then
    printf 'in-sync'
    return 0
  fi
  if git merge-base --is-ancestor "$local_oid" "$remote_oid" >/dev/null 2>&1; then
    printf 'remote-ahead'
    return 0
  fi
  if git merge-base --is-ancestor "$remote_oid" "$local_oid" >/dev/null 2>&1; then
    printf 'local-ahead'
    return 0
  fi
  printf 'diverged'
}

maybe_sync_shiplog_ref() {
  local ref="$1"
  has_remote_origin || return 0

  local remote_oid
  if ! remote_oid=$(get_remote_oid "$ref"); then
    return 0
  fi
  [ -n "$remote_oid" ] || return 0

  local local_oid
  # -q --verify: a missing ref must read as empty (plain rev-parse echoes the name).
  local_oid=$(git rev-parse -q --verify "$ref" 2>/dev/null || true)
  if [ -z "$local_oid" ]; then
    fast_forward_ref "$ref" "fetch"
    return 0
  fi

  local state
  state=$(check_divergence "$local_oid" "$remote_oid")
  case "$state" in
    in-sync|local-ahead|remote-missing)
      return 0
      ;;
    remote-ahead)
      fast_forward_ref "$ref"
      ;;
    diverged)
      local remote
      remote=$(shiplog_remote_name)
      die "shiplog: $ref has diverged between local and $remote; reconcile before writing"
      ;;
  esac
}

policy_install_file() {
  local new_file="$1" dest_file="$2"
  normalize_json_file() {
    local f="$1"
    if command -v jq >/dev/null 2>&1; then
      local tmpn; tmpn=$(mktemp)
      if jq -S . "$f" >"$tmpn" 2>/dev/null; then
        mv "$tmpn" "$f"
      else
        rm -f "$tmpn" 2>/dev/null || true
      fi
    fi
  }
  if [ ! -f "$dest_file" ]; then
    mv "$new_file" "$dest_file"
    normalize_json_file "$dest_file"
    return 0
  fi
  if cmp -s "$new_file" "$dest_file" 2>/dev/null; then
    rm -f "$new_file"
    if shiplog_can_use_bosun; then
      local bosun; bosun=$(shiplog_bosun_bin)
      "$bosun" style --title "Policy" -- "No changes to $dest_file"
    else
      printf 'No changes to %s\n' "$dest_file"
    fi
    return 0
  fi
  # If contents differ but JSON bodies are identical, treat as no-op (avoid backup churn across distros)
  if command -v jq >/dev/null 2>&1; then
    local old_norm new_norm
    old_norm=$(jq -cS . "$dest_file" 2>/dev/null || true)
    new_norm=$(jq -cS . "$new_file" 2>/dev/null || true)
    if [ -n "$old_norm" ] && [ -n "$new_norm" ] && [ "$old_norm" = "$new_norm" ]; then
      rm -f "$new_file"
      if shiplog_can_use_bosun; then
        local bosun; bosun=$(shiplog_bosun_bin)
        "$bosun" style --title "Policy" -- "No semantic changes to $dest_file"
      else
        printf 'No semantic changes to %s\n' "$dest_file"
      fi
      return 0
    fi
  fi
  local ts backup diffout
  ts="$(date +%Y%m%d%H%M%S)"
  backup="${dest_file}.bak.${ts}"
  cp "$dest_file" "$backup"
  if command -v git >/dev/null 2>&1; then
    diffout="$(git --no-pager diff --no-index --color=never -- "$dest_file" "$new_file" 2>/dev/null || true)"
  else
    diffout="$(diff -u "$dest_file" "$new_file" 2>/dev/null || true)"
  fi
  mv "$new_file" "$dest_file"
  normalize_json_file "$dest_file"
  if shiplog_can_use_bosun; then
    local bosun; bosun=$(shiplog_bosun_bin)
    "$bosun" style --title "Policy Backup" -- "Saved previous policy to $backup"
    if [ -n "$diffout" ]; then
      "$bosun" style --title "Policy Diff" -- "$diffout"
    fi
  else
    printf 'Backed up previous policy to %s\n' "$backup"
    [ -n "$diffout" ] && printf '%s\n' "$diffout"
  fi
}

# shiplog_require_flag_value FLAG REMAINING_ARGC
# A flag that takes a value must not be the last argument. Without this check the
# parsers' `shift; x="$1"; shift` pattern fails on the second shift under errexit
# and the command exits 1 with nothing on stderr (#139 A).
shiplog_require_flag_value() {
  [ "$2" -ge 2 ] || die "shiplog: $1 requires a value"
}

# shiplog_validate_env_name NAME
# Journal environments become ref components (<ref root>/journal/NAME), so a typo
# or a stray flag value must never create a new journal (#117). Dies on anything
# Git would not accept as a one-level ref name, on whitespace, `..` or a leading `-`.
shiplog_validate_env_name() {
  local name="$1"
  [ -n "$name" ] || die "shiplog: environment name must not be empty"
  case "$name" in
    -*) die "shiplog: invalid environment name '$name' (must not start with '-')" ;;
    *..*) die "shiplog: invalid environment name '$name' (must not contain '..')" ;;
    *[[:space:]]*) die "shiplog: invalid environment name '$name' (must not contain whitespace)" ;;
  esac
  git check-ref-format --allow-onelevel "$name" >/dev/null 2>&1 \
    || die "shiplog: invalid environment name '$name' (fails git check-ref-format)"
}

cmd_version() {
  printf 'shiplog %s\n' "$(shiplog_version)"
}

# shiplog_config_unset_value KEY VALUE — remove every KEY entry equal to VALUE
# (literal match; works on Git versions without --fixed-value).
shiplog_config_unset_value() {
  local key="$1" value="$2" kept line
  git config --get-all "$key" 2>/dev/null | grep -Fxq -- "$value" || return 0
  kept=$(git config --get-all "$key" 2>/dev/null | grep -Fxv -- "$value" || true)
  git config --unset-all "$key" 2>/dev/null || true
  while IFS= read -r line; do
    [ -n "$line" ] && git config --add "$key" "$line"
  done <<<"$kept"
  return 0
}

cmd_init() {
  ensure_in_repo
  local want_push=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h)
        printf 'Usage: git shiplog init [--push-refspecs]\n\nConfigure a fetch refspec for the Shiplog ref root and enable reflogs.\nShiplog pushes its refs itself (auto-push, git shiplog publish); --push-refspecs\nalso makes a plain `git push` send them (not recommended, see docs/features/init.md).\n'
        return 0 ;;
      --push-refspecs) want_push=1 ;;
      *) die "shiplog: unknown init option: $1" ;;
    esac
    shift
  done
  local remote
  remote=$(shiplog_remote_name)
  local spec="$REF_ROOT/*:$REF_ROOT/*"

  # Fetch: non-forced, so a rewritten remote ledger makes `git fetch` fail instead of
  # silently replacing the local copy (the evidence). Older versions used "+spec".
  shiplog_config_unset_value remote."$remote".fetch "+$spec"
  if ! git config --get-all remote."$remote".fetch 2>/dev/null | grep -Fxq -- "$spec"; then
    git config --add remote."$remote".fetch "$spec"
  fi

  # Push: none by default (#140). Any remote.<r>.push entry replaces push.default
  # for a plain `git push` and routes the ledger through pre-push hooks.
  local existing_push others had_spec=0
  existing_push=$(git config --get-all remote."$remote".push 2>/dev/null || true)
  if printf '%s\n' "$existing_push" | grep -Fxq -- "$spec"; then had_spec=1; fi
  if [ "$want_push" -eq 1 ] || { [ "$had_spec" -eq 1 ] && [ "$(git config --get shiplog.pushRefspecs 2>/dev/null)" = "true" ]; }; then
    if [ "$had_spec" -eq 0 ]; then
      git config --add remote."$remote".push "$spec"
    fi
    if [ -z "$existing_push" ]; then
      git config --add remote."$remote".push HEAD
    fi
    git config shiplog.pushRefspecs true
    if [ "$want_push" -eq 1 ]; then
      printf '⚠️ shiplog: remote.%s.push now lists %s: a plain git push sends the ledger with your code, ignores push.default and runs pre-push hooks on it. Shiplog does not need this; to undo: git config --unset shiplog.pushRefspecs && git shiplog init\n' "$remote" "$spec"
    fi
  elif [ "$had_spec" -eq 1 ]; then
    # Written by an older Shiplog. HEAD goes too only when it was the companion
    # entry Shiplog added to an otherwise empty push config.
    others=$(printf '%s\n' "$existing_push" | grep -Fxv -e "$spec" -e HEAD | sed '/^$/d' || true)
    shiplog_config_unset_value remote."$remote".push "$spec"
    if [ -z "$others" ] && printf '%s\n' "$existing_push" | grep -Fxq HEAD; then
      shiplog_config_unset_value remote."$remote".push HEAD
      printf 'ℹ️ shiplog: Removed push refspecs %s and HEAD from remote.%s (a plain git push behaves normally again; Shiplog publishes its own refs).\n' "$spec" "$remote"
    else
      printf 'ℹ️ shiplog: Removed push refspec %s from remote.%s (Shiplog publishes its own refs).\n' "$spec" "$remote"
    fi
  fi

  if [ "$(git config --get core.logAllRefUpdates 2>/dev/null)" != "true" ]; then
    git config core.logAllRefUpdates true
  fi
  if shiplog_can_use_bosun; then
    local bosun
    bosun=$(shiplog_bosun_bin)
    "$bosun" style --title "Init" -- "Configured the fetch refspec for $REF_ROOT/* and enabled reflogs."
  else
    printf 'Configured the fetch refspec for %s/* and enabled reflogs.\n' "$REF_ROOT"
  fi
}

cmd_write() {
  ensure_in_repo
  local env="$DEFAULT_ENV"
  local positional_env=""

  # Parse positional ENV and optional flags to prefill prompts
  local dry_run=0
  if shiplog_is_dry_run; then
    dry_run=1
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --env|--service|--status|--reason|--ticket|--region|--cluster|--namespace|--image|--tag|--run-url)
        shiplog_require_flag_value "$1" $# ;;
    esac
    case "$1" in
      --help|-h)
        cat <<'EOF'
Usage: git shiplog write [ENV] [OPTIONS]

Options:
  --env ENV               Environment (defaults to SHIPLOG_ENV or prod)
  --service NAME          Service/component name (required in non-interactive)
  --status STATUS         success|failed|in_progress|skipped|override|revert|finalize
  --reason TEXT           Free-form reason/summary
  --ticket ID             Ticket/PR reference
  --region R              Region
  --cluster C             Cluster
  --namespace NS          Namespace (defaults to ENV when blank)
  --image IMG             Artifact image
  --tag TAG               Artifact tag
  --run-url URL           CI/CD run URL
  --dry-run               Preview without writing

Global flags: --boring (plain), --yes (auto-confirm), --no-push/--push
EOF
        return 0 ;;
      --env)
        shift; env="${1:-$env}"; shift; continue ;;
      --env=*)
        env="${1#*=}"; shift; continue ;;
      --service) shift; SHIPLOG_SERVICE="${1:-}"; export SHIPLOG_SERVICE; shift; continue ;;
      --service=*) SHIPLOG_SERVICE="${1#*=}"; export SHIPLOG_SERVICE; shift; continue ;;
      --status) shift; SHIPLOG_STATUS="${1:-}"; export SHIPLOG_STATUS; shift; continue ;;
      --status=*) SHIPLOG_STATUS="${1#*=}"; export SHIPLOG_STATUS; shift; continue ;;
      --reason) shift; SHIPLOG_REASON="${1:-}"; export SHIPLOG_REASON; shift; continue ;;
      --reason=*) SHIPLOG_REASON="${1#*=}"; export SHIPLOG_REASON; shift; continue ;;
      --ticket) shift; SHIPLOG_TICKET="${1:-}"; export SHIPLOG_TICKET; shift; continue ;;
      --ticket=*) SHIPLOG_TICKET="${1#*=}"; export SHIPLOG_TICKET; shift; continue ;;
      --region) shift; SHIPLOG_REGION="${1:-}"; export SHIPLOG_REGION; shift; continue ;;
      --region=*) SHIPLOG_REGION="${1#*=}"; export SHIPLOG_REGION; shift; continue ;;
      --cluster) shift; SHIPLOG_CLUSTER="${1:-}"; export SHIPLOG_CLUSTER; shift; continue ;;
      --cluster=*) SHIPLOG_CLUSTER="${1#*=}"; export SHIPLOG_CLUSTER; shift; continue ;;
      --namespace) shift; SHIPLOG_NAMESPACE="${1:-}"; export SHIPLOG_NAMESPACE; shift; continue ;;
      --namespace=*) SHIPLOG_NAMESPACE="${1#*=}"; export SHIPLOG_NAMESPACE; shift; continue ;;
      --image) shift; SHIPLOG_IMAGE="${1:-}"; export SHIPLOG_IMAGE; shift; continue ;;
      --image=*) SHIPLOG_IMAGE="${1#*=}"; export SHIPLOG_IMAGE; shift; continue ;;
      --tag) shift; SHIPLOG_TAG="${1:-}"; export SHIPLOG_TAG; shift; continue ;;
      --tag=*) SHIPLOG_TAG="${1#*=}"; export SHIPLOG_TAG; shift; continue ;;
      --run-url) shift; SHIPLOG_RUN_URL="${1:-}"; export SHIPLOG_RUN_URL; shift; continue ;;
      --run-url=*) SHIPLOG_RUN_URL="${1#*=}"; export SHIPLOG_RUN_URL; shift; continue ;;
      --dry-run)
        dry_run=1
        SHIPLOG_DRY_RUN=1
        export SHIPLOG_DRY_RUN
        shift
        continue
        ;;
      --dry-run=*)
        local dry_val
        dry_val="${1#*=}"
        dry_run=$(shiplog_parse_bool "${dry_val:-0}") || die "shiplog: --dry-run accepts 1|true|yes|on|0|false|no|off, got '$dry_val'"
        SHIPLOG_DRY_RUN="$dry_run"
        export SHIPLOG_DRY_RUN
        shift
        continue
        ;;
      --)
        shift
        if [ $# -gt 0 ]; then
          [ -z "$positional_env" ] || die "shiplog: write accepts a single ENV argument (got '$positional_env' and '$1')"
          positional_env="$1"; shift
        fi
        [ $# -eq 0 ] || die "shiplog: unexpected argument to write: $1"
        break ;;
      -*)
        # Unknown flags used to be collected and ignored, which promoted the next
        # word to ENV and created a stray journal (#117).
        die "shiplog: unknown write option: $1 (see git shiplog write --help)" ;;
      *)
        [ -z "$positional_env" ] || die "shiplog: write accepts a single ENV argument (got '$positional_env' and '$1')"
        positional_env="$1"; shift; continue ;;
    esac
  done

  # Positional ENV > --env > SHIPLOG_ENV/global --env > default
  if [ -n "$positional_env" ]; then
    env="$positional_env"
  fi
  shiplog_validate_env_name "$env"

  # Policy is resolved for the environment this entry targets (positional ENV >
  # --env > global --env/SHIPLOG_ENV), never for the default env implicitly.
  shiplog_policy_load "$env"
  shiplog_policy_enforce
  require_allowed_author
  require_allowed_signer

  local journal_ref="$(ref_journal "$env")"
  local notes_ref; notes_ref=$(shiplog_notes_ref)
  local trust_ref="${TRUST_REF:-$TRUST_REF_DEFAULT}"
  local remote
  remote=$(shiplog_remote_name)
  local remote_available=0
  if has_remote_origin; then
    remote_available=1
    if [ "${dry_run:-0}" -ne 1 ]; then
      maybe_sync_shiplog_ref "$trust_ref"
      maybe_sync_shiplog_ref "$journal_ref"
      # Bring the local notes ref up to the published one so the note added
      # below is a fast-forward of what other writers already pushed.
      if [ -n "$notes_ref" ]; then
        maybe_sync_shiplog_ref "$notes_ref"
      fi
    fi
  fi

  local trust_oid
  trust_oid=$(git rev-parse -q --verify "$trust_ref" 2>/dev/null || true)
  if [ -z "$trust_oid" ]; then
    die "shiplog: trust ref $trust_ref not found. Fetch it (git fetch $remote '+$trust_ref:$trust_ref') and run ./scripts/shiplog-trust-sync.sh"
  fi

  local service status reason ticket region cluster ns artifact_tag artifact_image run_url
  service="$(shiplog_prompt_input "service (e.g., web)" "SHIPLOG_SERVICE")"
  status="$(shiplog_prompt_choice "Status" "SHIPLOG_STATUS" success failed in_progress skipped override revert finalize)"
  reason="$(shiplog_prompt_input "reason (e.g., hotfix 503s)" "SHIPLOG_REASON")"
  ticket="$(shiplog_prompt_input "ticket/PR (optional, e.g., OPS-7421)" "SHIPLOG_TICKET")"
  region="$(shiplog_prompt_input "region (e.g., us-west-2)" "SHIPLOG_REGION")"
  cluster="$(shiplog_prompt_input "cluster (e.g., prod-1)" "SHIPLOG_CLUSTER")"
  ns="$(shiplog_prompt_input "namespace (e.g., pf3)" "SHIPLOG_NAMESPACE")"
  artifact_image="$(shiplog_prompt_input "artifact image (e.g., ghcr.io/acme/web)" "SHIPLOG_IMAGE")"
  artifact_tag="$(shiplog_prompt_input "artifact tag (e.g., 2025-09-19.3)" "SHIPLOG_TAG")"
  run_url="$(shiplog_prompt_input "pipeline/run URL (optional)" "SHIPLOG_RUN_URL")"

  # Header fields are single-line: newlines become spaces so user text can
  # never add a header line, let alone one that looks like the trailer
  # separator (SLT.BUG.CLI.001). Documented in docs/features/write.md.
  service="$(shiplog_single_line "$service")"
  status="$(shiplog_single_line "$status")"
  reason="$(shiplog_single_line "$reason")"
  ticket="$(shiplog_single_line "$ticket")"
  region="$(shiplog_single_line "$region")"
  cluster="$(shiplog_single_line "$cluster")"
  ns="$(shiplog_single_line "$ns")"
  artifact_image="$(shiplog_single_line "$artifact_image")"
  artifact_tag="$(shiplog_single_line "$artifact_tag")"
  run_url="$(shiplog_single_line "$run_url")"

  if ! shiplog_status_is_valid "$status"; then
    die "shiplog: invalid status '$status' (expected one of: $SHIPLOG_STATUS_VALUES)"
  fi

  if [ -z "$ns" ]; then
    ns="$env"
  fi

  if [ -z "$service" ] && [ "${SHIPLOG_ASSUME_YES:-0}" = "1" ]; then
    service="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo default)")"
  fi
  if [ -z "$service" ]; then
    if is_boring || [ "${SHIPLOG_ASSUME_YES:-0}" = "1" ]; then
      die "shiplog: SHIPLOG_SERVICE environment variable is required in non-interactive mode"
    else
      die "shiplog: service name is required but not provided"
    fi
  fi
  local start_ts end_ts dur_s start_epoch end_epoch
  start_epoch=$(date -u +%s)
  start_ts="$(fmt_ts)"
  if is_boring; then
    sleep 0.01
  else
    if shiplog_can_use_bosun; then
      local bosun
      bosun=$(shiplog_bosun_bin)
      "$bosun" spin --title "Gathering repo state…" -- sleep 0.2
    else
      sleep 0.2
    fi
  fi
  local repo_head; repo_head="$(git rev-parse HEAD)"
  end_epoch=$(date -u +%s)
  end_ts="$(fmt_ts)"
  dur_s=$(( end_epoch - start_epoch ))

  local artifact=""
  if [ -n "$artifact_image" ]; then
    artifact="${artifact_image}${artifact_tag:+:$artifact_tag}"
  else
    artifact="$artifact_tag"
  fi

  local parent seq=0
  parent="$(current_tip "$journal_ref")"
  if [ -n "$parent" ]; then
    local prev_seq
    prev_seq=$(trailer_value "$parent" '.seq') || die "shiplog: unable to read seq from previous journal entry $parent"
    if [ "$prev_seq" = "null" ] || ! printf '%s' "$prev_seq" | grep -Eq '^[0-9]+$'; then
      die "shiplog: previous journal entry $parent missing numeric seq"
    fi
    seq=$((prev_seq + 1))
  fi

  local anchor_ref="$(ref_anchor "$env")"
  local previous_anchor
  previous_anchor="$(current_tip "$anchor_ref")"

  local author_name author_email
  author_name="${GIT_AUTHOR_NAME:-${SHIPLOG_AUTHOR_NAME:-$(git config user.name || echo '')}}"
  author_email="${GIT_AUTHOR_EMAIL:-${SHIPLOG_AUTHOR_EMAIL:-$(git config user.email || echo '')}}"
  [ -n "$author_email" ] || die "shiplog: unable to determine author email"

  local write_ts
  write_ts="$(fmt_ts)"

  local msg; msg="$(compose_message "$env" "$service" "$status" "$reason" "$ticket" "$region" "$cluster" "$ns" "$start_ts" "$end_ts" "$dur_s" "$repo_head" "$artifact" "$run_url" "$seq" "$parent" "$trust_oid" "$previous_anchor" "$write_ts" "$author_name" "$author_email")"
  # Apply plugin filter if available, fallback gracefully if not
  if command -v shiplog_plugins_filter >/dev/null 2>&1; then
    msg=$(shiplog_plugins_filter "pre-commit-message" "$msg")
  fi

  if shiplog_can_use_bosun; then
    local bosun structured_preview
    bosun=$(shiplog_bosun_bin)
    "$bosun" style --title "Preview" -- "$msg"
    structured_preview=$(jq -n --arg preview "$env" --arg status "$status" --arg service "$service" '{preview:$preview,status:$status,service:$service}')
    shiplog_log_structured "$structured_preview"
  else
    printf '%s\n' "$msg"
    if ! is_boring; then
      shiplog_log_structured "$(jq -n --arg preview "$env" --arg status "$status" --arg service "$service" '{preview:$preview,status:$status,service:$service}')"
    fi
  fi

  if [ "$dry_run" -eq 1 ]; then
    shiplog_dry_run_notice "Would sign & append entry to $journal_ref"
    return 0
  fi

  shiplog_confirm "Sign & append this entry to $journal_ref?" || die "Aborted."

  local tree; tree="$(empty_tree)"
  local new
  new="$(printf "%s" "$msg" | sign_commit "$tree" ${parent:+-p "$parent"})" || die "Signing commit failed."

  local note_attached=0
  if [ -n "${SHIPLOG_LOG:-}" ]; then
    attach_note_if_present "$new" "$SHIPLOG_LOG"
    note_attached=1
  fi

  ff_update "$journal_ref" "$new" "$parent" "shiplog: append entry"
  local append_message="✅ Appended $(git rev-parse --short "$new") to $(ref_journal "$env")"
  if shiplog_can_use_bosun; then
    local bosun structured_log
    bosun=$(shiplog_bosun_bin)
    "$bosun" style --title "Write" -- "$append_message"
    structured_log=$(jq -n \
      --arg env "$env" --arg status "$status" --arg service "$service" \
      --arg artifact "$artifact" --arg region "$region" --arg cluster "$cluster" \
      --arg namespace "$ns" --arg ticket "$ticket" --arg reason "$reason" \
      '{env:$env,status:$status,service:$service,artifact:$artifact,region:$region,cluster:$cluster,namespace:$namespace,ticket:$ticket,reason:$reason}')
    shiplog_log_structured "$structured_log"
  else
    printf '%s\n' "$append_message"
    if ! is_boring; then
      shiplog_log_structured "$(
        jq -n \
          --arg env "$env" --arg status "$status" --arg service "$service" \
          --arg artifact "$artifact" --arg region "$region" --arg cluster "$cluster" \
          --arg namespace "$ns" --arg ticket "$ticket" --arg reason "$reason" \
          '{env:$env,status:$status,service:$service,artifact:$artifact,region:$region,cluster:$cluster,namespace:$namespace,ticket:$ticket,reason:$reason}'
      )"
    fi
  fi

  if [ "$remote_available" -eq 1 ]; then
    # Effective auto-push, decided once: --push/--no-push > git config shiplog.autoPush
    # > SHIPLOG_AUTO_PUSH > default on. Every source goes through the shared boolean
    # parser, so "false"/"no"/"off" disable it and an unknown value is an error.
    local autopush_effective
    if [ "${SHIPLOG_AUTO_PUSH_FLAG:-0}" = "1" ]; then
      shiplog_bool_var autopush_effective "--push/--no-push" "${SHIPLOG_AUTO_PUSH:-}" 1
    else
      local cfg
      cfg=$(git config --get shiplog.autoPush 2>/dev/null || true)
      if [ -n "$cfg" ]; then
        shiplog_bool_var autopush_effective "git config shiplog.autoPush" "$cfg" 1
      else
        shiplog_bool_var autopush_effective "SHIPLOG_AUTO_PUSH" "${SHIPLOG_AUTO_PUSH:-}" 1
      fi
    fi
    if [ "$autopush_effective" = "1" ]; then
      local push_output
      if ! push_output=$(git push --no-verify "$remote" "$journal_ref" 2>&1); then
        die "shiplog: failed to push $journal_ref to $remote: $push_output"
      fi
      if [ "$note_attached" -eq 1 ]; then
        if ! push_output=$(git push --no-verify "$remote" "$notes_ref" 2>&1); then
          die "shiplog: failed to push $notes_ref to $remote: $push_output"
        fi
      fi
      if shiplog_can_use_bosun; then
        local bosun
        bosun=$(shiplog_bosun_bin)
        "$bosun" style --title "Push" -- "📤 Pushed $journal_ref to $remote"
      elif ! is_boring; then
        printf '📤 Pushed %s to %s\n' "$journal_ref" "$remote"
      fi
    else
      printf 'ℹ️ shiplog: auto-push disabled; remember to publish %s to %s when ready (git shiplog publish --env %s).\n' "$journal_ref" "$remote" "$env"
    fi
  fi
}

cmd_run() {
  ensure_in_repo

  local env="$DEFAULT_ENV"
  local service="${SHIPLOG_SERVICE:-}"
  local reason="${SHIPLOG_REASON:-}"
  local status_success="success"
  local status_failure="failed"
  local namespace="${SHIPLOG_NAMESPACE:-}"
  local ticket="${SHIPLOG_TICKET:-}"
  local region="${SHIPLOG_REGION:-}"
  local cluster="${SHIPLOG_CLUSTER:-}"

  local dry_run=0
  local skip_execution=0
  if shiplog_is_dry_run; then
    dry_run=1
    skip_execution=1
  fi
  local -a run_argv=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --env|--service|--reason|--status-success|--status-failure|--namespace|--ticket|--region|--cluster)
        shiplog_require_flag_value "$1" $# ;;
    esac
    case "$1" in
      --help|-h)
        cat <<'EOF'
Usage: git shiplog run [OPTIONS] -- COMMAND [ARGS...]

Execute COMMAND, capture its output as a note, and append a journal entry
describing the run. Everything after `--` is the command (it may start with `-`).

Options:
  --env ENV                 Environment (defaults to SHIPLOG_ENV or prod)
  --service NAME            Service/component name (required)
  --reason TEXT             Free-form reason/summary
  --status-success STATUS   Status recorded when COMMAND exits 0 (default: success)
  --status-failure STATUS   Status recorded when COMMAND fails (default: failed)
  --ticket ID               Ticket/PR reference
  --region R                Region
  --cluster C               Cluster
  --namespace NS            Namespace
  --dry-run                 Print the command and entry preview without running

Global flags: --boring (plain), --yes (auto-confirm), --no-push/--push
EOF
        return 0 ;;
      --env)
        shift; env="${1:-$env}"; shift; continue ;;
      --env=*)
        env="${1#*=}"; shift; continue ;;
      --service)
        shift; service="${1:-}"; shift; continue ;;
      --service=*)
        service="${1#*=}"; shift; continue ;;
      --reason)
        shift; reason="${1:-}"; shift; continue ;;
      --reason=*)
        reason="${1#*=}"; shift; continue ;;
      --status-success)
        shift; status_success="${1:-$status_success}"; shift; continue ;;
      --status-success=*)
        status_success="${1#*=}"; shift; continue ;;
      --status-failure)
        shift; status_failure="${1:-$status_failure}"; shift; continue ;;
      --status-failure=*)
        status_failure="${1#*=}"; shift; continue ;;
      --namespace)
        shift; namespace="${1:-}"; shift; continue ;;
      --namespace=*)
        namespace="${1#*=}"; shift; continue ;;
      --ticket)
        shift; ticket="${1:-}"; shift; continue ;;
      --ticket=*)
        ticket="${1#*=}"; shift; continue ;;
      --region)
        shift; region="${1:-}"; shift; continue ;;
      --region=*)
        region="${1#*=}"; shift; continue ;;
      --cluster)
        shift; cluster="${1:-}"; shift; continue ;;
      --cluster=*)
        cluster="${1#*=}"; shift; continue ;;
      --dry-run)
        dry_run=1
        skip_execution=1
        SHIPLOG_DRY_RUN=1
        export SHIPLOG_DRY_RUN
        shift
        continue ;;
      --dry-run=*)
        local run_dry_val="${1#*=}"
        dry_run=$(shiplog_parse_bool "${run_dry_val:-0}") || die "shiplog: --dry-run accepts 1|true|yes|on|0|false|no|off, got '$run_dry_val'"
        skip_execution="$dry_run"
        SHIPLOG_DRY_RUN="$dry_run"
        export SHIPLOG_DRY_RUN
        shift; continue ;;
      --)
        shift
        while [ $# -gt 0 ]; do run_argv+=("$1"); shift; done
        break ;;
      -*)
        die "shiplog: unknown run option: $1" ;;
      *)
        while [ $# -gt 0 ]; do run_argv+=("$1"); shift; done
        break ;;
    esac
  done

  if [ ${#run_argv[@]} -eq 0 ]; then
    die "shiplog: run requires a command to execute (tip: place it after --)"
  fi

  if [ -z "$service" ]; then
    die "shiplog: --service (or SHIPLOG_SERVICE) is required for run"
  fi
  shiplog_validate_env_name "$env"
  # Validate both statuses before the command runs: cmd_write rejects a status
  # outside the documented enum, and discovering that only after a deploy has
  # executed would leave it unrecorded.
  local run_status_flag
  for run_status_flag in "$status_success" "$status_failure"; do
    if ! shiplog_status_is_valid "$run_status_flag"; then
      die "shiplog: invalid status '$run_status_flag' (expected one of: $SHIPLOG_STATUS_VALUES)"
    fi
  done

  local -a quoted_cmd=()
  local arg
  for arg in "${run_argv[@]}"; do
    quoted_cmd+=("$(printf '%q' "$arg")")
  done
  local cmd_display
  cmd_display="${quoted_cmd[*]}"

  if [ "$dry_run" -eq 1 ]; then
    shiplog_dry_run_notice "Would execute: $cmd_display"
  fi

  local started_at finished_at
  local start_epoch end_epoch duration_s
  local log_path; log_path=$(mktemp) || die "shiplog: failed to allocate temp log"
  local tee_output=1
  if is_boring; then
    tee_output=0
  fi

  local cmd_status run_status
  local log_attached_bool="false"

  if [ "$skip_execution" -eq 0 ]; then
    started_at="$(fmt_ts)"
    start_epoch=$(date -u +%s)

    if [ "$tee_output" -eq 1 ]; then
      # Stream to the terminal and the log through two named pipes, one per
      # stream, each drained by a background tee that is awaited before the log
      # is read (SLT.BUG.CLI.011). Process substitutions cannot be waited on and
      # left the log truncated. Trade-off: stdout and stderr travel through
      # separate pipes, so their interleaving in the log may differ slightly
      # from the terminal order (same as before); each stream is complete and
      # in order. A child that keeps the pipes open after the command exits
      # delays the entry until it closes them, as with `cmd | tee`.
      local fifo_dir pid_out pid_err
      fifo_dir=$(mktemp -d) || die "shiplog: failed to allocate run pipes"
      mkfifo "$fifo_dir/out" "$fifo_dir/err" || die "shiplog: failed to create run pipes"
      tee -a "$log_path" <"$fifo_dir/out" &
      pid_out=$!
      tee -a "$log_path" <"$fifo_dir/err" >&2 &
      pid_err=$!
      set +e
      "${run_argv[@]}" >"$fifo_dir/out" 2>"$fifo_dir/err"
      cmd_status=$?
      wait "$pid_out" "$pid_err"
      set -e
      rm -rf "$fifo_dir"
    else
      set +e
      "${run_argv[@]}" >"$log_path" 2>&1
      cmd_status=$?
      set -e
    fi

    finished_at="$(fmt_ts)"
    end_epoch=$(date -u +%s)
    duration_s=$(( end_epoch - start_epoch ))
    if [ "$duration_s" -lt 0 ]; then
      duration_s=0
    fi

    run_status="$status_failure"
    if [ "$cmd_status" -eq 0 ]; then
      run_status="$status_success"
    fi

    if [ -s "$log_path" ]; then
      log_attached_bool="true"
    fi
  else
    cmd_status=0
    run_status="$status_success"
    started_at="$(fmt_ts)"
    finished_at="$started_at"
    duration_s=0
    log_attached_bool="false"
  fi

  local argv_json
  argv_json=$(printf '%s\n' "${run_argv[@]}" | jq -R . | jq -s .)

  # The run block travels through SHIPLOG_RUN_JSON, an internal core-key
  # channel, not SHIPLOG_EXTRA_JSON: `run` is a reserved trailer key and extras
  # are not allowed to set it (SLT.BUG.CLI.010).
  local run_json
  run_json=$(jq -n \
    --argjson argv "$argv_json" \
    --arg cmd "$cmd_display" \
    --arg status "$run_status" \
    --arg started "$started_at" \
    --arg finished "$finished_at" \
    --argjson exit_code "$cmd_status" \
    --argjson duration "$duration_s" \
    --argjson log_attached "$log_attached_bool" \
    '{argv: $argv, cmd: $cmd, exit_code: $exit_code, status: $status, duration_s: $duration, started_at: $started, finished_at: $finished, log_attached: $log_attached}'
  )

  local had_boring=0 prev_boring=""
  if [ "${SHIPLOG_BORING+x}" = x ]; then
    had_boring=1; prev_boring="$SHIPLOG_BORING"
  fi
  SHIPLOG_BORING=1; export SHIPLOG_BORING

  local had_assume=0 prev_assume=""
  if [ "${SHIPLOG_ASSUME_YES+x}" = x ]; then
    had_assume=1; prev_assume="$SHIPLOG_ASSUME_YES"
  fi
  SHIPLOG_ASSUME_YES=1; export SHIPLOG_ASSUME_YES

  local had_log=0 prev_log=""
  if [ "${SHIPLOG_LOG+x}" = x ]; then
    had_log=1; prev_log="$SHIPLOG_LOG"
  fi
  local attach_log=0
  if [ "$log_attached_bool" = "true" ]; then
    SHIPLOG_LOG="$log_path"; export SHIPLOG_LOG
    attach_log=1
  fi

  local had_run_json=0 prev_run_json=""
  if [ "${SHIPLOG_RUN_JSON+x}" = x ]; then
    had_run_json=1; prev_run_json="$SHIPLOG_RUN_JSON"
  fi
  SHIPLOG_RUN_JSON="$run_json"; export SHIPLOG_RUN_JSON

  local had_status=0 prev_status=""
  if [ "${SHIPLOG_STATUS+x}" = x ]; then
    had_status=1; prev_status="$SHIPLOG_STATUS"
  fi
  SHIPLOG_STATUS="$run_status"; export SHIPLOG_STATUS

  local had_reason=0 prev_reason=""
  if [ "${SHIPLOG_REASON+x}" = x ]; then
    had_reason=1; prev_reason="$SHIPLOG_REASON"
  fi
  SHIPLOG_REASON="$reason"; export SHIPLOG_REASON

  local had_service=0 prev_service=""
  if [ "${SHIPLOG_SERVICE+x}" = x ]; then
    had_service=1; prev_service="$SHIPLOG_SERVICE"
  fi
  SHIPLOG_SERVICE="$service"; export SHIPLOG_SERVICE

  local had_namespace=0 prev_namespace=""
  if [ "${SHIPLOG_NAMESPACE+x}" = x ]; then
    had_namespace=1; prev_namespace="$SHIPLOG_NAMESPACE"
  fi
  SHIPLOG_NAMESPACE="$namespace"; export SHIPLOG_NAMESPACE

  local had_ticket=0 prev_ticket=""
  if [ "${SHIPLOG_TICKET+x}" = x ]; then
    had_ticket=1; prev_ticket="$SHIPLOG_TICKET"
  fi
  SHIPLOG_TICKET="$ticket"; export SHIPLOG_TICKET

  local had_region=0 prev_region=""
  if [ "${SHIPLOG_REGION+x}" = x ]; then
    had_region=1; prev_region="$SHIPLOG_REGION"
  fi
  SHIPLOG_REGION="$region"; export SHIPLOG_REGION

  local had_cluster=0 prev_cluster=""
  if [ "${SHIPLOG_CLUSTER+x}" = x ]; then
    had_cluster=1; prev_cluster="$SHIPLOG_CLUSTER"
  fi
  SHIPLOG_CLUSTER="$cluster"; export SHIPLOG_CLUSTER

  # Capture cmd_write's status without letting errexit abort cmd_run before the
  # diagnostics print (SLT.BUG.CLI.002). Not `out=$( (...) ) || st=$?`: bash
  # ignores -e inside a subshell that is part of an || list, which would let a
  # failure inside cmd_write continue silently. Instead errexit is switched off
  # in this shell for the capture and switched back on inside the subshell.
  local write_status=0 write_output=""
  set +e
  write_output=$( (set -e; cmd_write --env "$env") 2>&1 )
  write_status=$?
  set -e
  if [ "$dry_run" -eq 1 ] || [ "$skip_execution" -eq 1 ]; then
    if [ -n "$write_output" ] && [ "$write_status" -eq 0 ]; then
      printf '%s\n' "$write_output"
    fi
  fi

  if [ $had_boring -eq 1 ]; then
    SHIPLOG_BORING="$prev_boring"; export SHIPLOG_BORING
  else
    unset SHIPLOG_BORING
  fi
  if [ $had_assume -eq 1 ]; then
    SHIPLOG_ASSUME_YES="$prev_assume"; export SHIPLOG_ASSUME_YES
  else
    unset SHIPLOG_ASSUME_YES
  fi
  if [ $attach_log -eq 1 ]; then
    if [ $had_log -eq 1 ]; then
      SHIPLOG_LOG="$prev_log"; export SHIPLOG_LOG
    else
      unset SHIPLOG_LOG
    fi
  elif [ $had_log -eq 1 ]; then
    SHIPLOG_LOG="$prev_log"; export SHIPLOG_LOG
  else
    unset SHIPLOG_LOG
  fi
  if [ $had_run_json -eq 1 ]; then
    SHIPLOG_RUN_JSON="$prev_run_json"; export SHIPLOG_RUN_JSON
  else
    unset SHIPLOG_RUN_JSON
  fi
  if [ $had_status -eq 1 ]; then
    SHIPLOG_STATUS="$prev_status"; export SHIPLOG_STATUS
  else
    unset SHIPLOG_STATUS
  fi
  if [ $had_reason -eq 1 ]; then
    SHIPLOG_REASON="$prev_reason"; export SHIPLOG_REASON
  else
    unset SHIPLOG_REASON
  fi
  if [ $had_service -eq 1 ]; then
    SHIPLOG_SERVICE="$prev_service"; export SHIPLOG_SERVICE
  else
    unset SHIPLOG_SERVICE
  fi
  if [ $had_namespace -eq 1 ]; then
    SHIPLOG_NAMESPACE="$prev_namespace"; export SHIPLOG_NAMESPACE
  else
    unset SHIPLOG_NAMESPACE
  fi
  if [ $had_ticket -eq 1 ]; then
    SHIPLOG_TICKET="$prev_ticket"; export SHIPLOG_TICKET
  else
    unset SHIPLOG_TICKET
  fi
  if [ $had_region -eq 1 ]; then
    SHIPLOG_REGION="$prev_region"; export SHIPLOG_REGION
  else
    unset SHIPLOG_REGION
  fi
  if [ $had_cluster -eq 1 ]; then
    SHIPLOG_CLUSTER="$prev_cluster"; export SHIPLOG_CLUSTER
  else
    unset SHIPLOG_CLUSTER
  fi

  if [ $write_status -eq 0 ]; then
    rm -f "$log_path"
    # Emit a compact confirmation to the user
    local msg
    # Minimal confirmation; customizable via SHIPLOG_CONFIRM_TEXT (default: log emoji)
    local confirm_text
    confirm_text="${SHIPLOG_CONFIRM_TEXT:-🪵}"
    msg="$confirm_text"
    if shiplog_can_use_bosun; then
      local bosun
      bosun=$(shiplog_bosun_bin)
      "$bosun" style --title "Shiplog" -- "$msg"
    else
      printf '%s\n' "$msg"
    fi
  else
    # Show why the write failed (cmd_write's own diagnostics), then where the
    # wrapped command's output was kept. The wrapped command's failure code is
    # never masked; a write failure after a successful command exits 1.
    if [ -n "$write_output" ]; then
      printf '%s\n' "$write_output" >&2
    fi
    printf '❌ shiplog: failed to record run entry; log preserved at %s\n' "$log_path" >&2
    if [ "$cmd_status" -ne 0 ]; then
      return "$cmd_status"
    fi
    return 1
  fi

  return "$cmd_status"
}

cmd_append() {
  ensure_in_repo
  need jq

  local env="$DEFAULT_ENV"
  local service="${SHIPLOG_SERVICE:-}"
  local status="${SHIPLOG_STATUS:-}"
  local reason="${SHIPLOG_REASON:-}"
  local ticket="${SHIPLOG_TICKET:-}"
  local region="${SHIPLOG_REGION:-}"
  local cluster="${SHIPLOG_CLUSTER:-}"
  local namespace="${SHIPLOG_NAMESPACE:-}"
  local image="${SHIPLOG_IMAGE:-}"
  local tag="${SHIPLOG_TAG:-}"
  local run_url="${SHIPLOG_RUN_URL:-}"
  local log_path="${SHIPLOG_LOG:-}"
  local extra_json=""
  local json_from_stdin=0
  local dry_run=0
  if shiplog_is_dry_run; then
    dry_run=1
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --env|--service|--status|--reason|--ticket|--region|--cluster|--namespace|--image|--tag|--run-url|--log|--json|--json-file)
        shiplog_require_flag_value "$1" $# ;;
    esac
    case "$1" in
      --env)
        shift; env="${1:-$env}"; shift; continue ;;
      --env=*)
        env="${1#*=}"; shift; continue ;;
      --service)
        shift; service="${1:-}"; shift; continue ;;
      --service=*)
        service="${1#*=}"; shift; continue ;;
      --status)
        shift; status="${1:-}"; shift; continue ;;
      --status=*)
        status="${1#*=}"; shift; continue ;;
      --reason)
        shift; reason="${1:-}"; shift; continue ;;
      --reason=*)
        reason="${1#*=}"; shift; continue ;;
      --ticket)
        shift; ticket="${1:-}"; shift; continue ;;
      --ticket=*)
        ticket="${1#*=}"; shift; continue ;;
      --region)
        shift; region="${1:-}"; shift; continue ;;
      --region=*)
        region="${1#*=}"; shift; continue ;;
      --cluster)
        shift; cluster="${1:-}"; shift; continue ;;
      --cluster=*)
        cluster="${1#*=}"; shift; continue ;;
      --namespace)
        shift; namespace="${1:-}"; shift; continue ;;
      --namespace=*)
        namespace="${1#*=}"; shift; continue ;;
      --image)
        shift; image="${1:-}"; shift; continue ;;
      --image=*)
        image="${1#*=}"; shift; continue ;;
      --tag)
        shift; tag="${1:-}"; shift; continue ;;
      --tag=*)
        tag="${1#*=}"; shift; continue ;;
      --run-url)
        shift; run_url="${1:-}"; shift; continue ;;
      --run-url=*)
        run_url="${1#*=}"; shift; continue ;;
      --log)
        shift; log_path="${1:-}"; shift; continue ;;
      --log=*)
        log_path="${1#*=}"; shift; continue ;;
      --json)
        shift; extra_json="${1:-}"; if [ "$extra_json" = "-" ]; then json_from_stdin=1; extra_json=""; fi; shift; continue ;;
      --json=*)
        extra_json="${1#*=}"; if [ "$extra_json" = "-" ]; then json_from_stdin=1; extra_json=""; fi; shift; continue ;;
      --json-file)
        shift; [ -n "${1:-}" ] || die "shiplog: --json-file requires a path"; extra_json="$(cat "${1}")"; shift; continue ;;
      --json-file=*)
        local json_file; json_file="${1#*=}"; [ -n "$json_file" ] || die "shiplog: --json-file requires a path"; extra_json="$(cat "$json_file")"; shift; continue ;;
      --dry-run)
        dry_run=1; SHIPLOG_DRY_RUN=1; export SHIPLOG_DRY_RUN; shift; continue ;;
      --dry-run=*)
        local append_dry_val; append_dry_val="${1#*=}";
        dry_run=$(shiplog_parse_bool "${append_dry_val:-0}") || die "shiplog: --dry-run accepts 1|true|yes|on|0|false|no|off, got '$append_dry_val'"
        SHIPLOG_DRY_RUN="$dry_run"
        export SHIPLOG_DRY_RUN; shift; continue ;;
      --help|-h)
        cat <<'EOF'
Usage: git shiplog append [--env ENV] --service NAME --json '{...}' [OPTIONS]

Options mirror `git shiplog write` flags (service/status/reason/etc.). JSON payload
is merged into the structured trailer before writing.
EOF
        return 0 ;;
      --)
        shift; break ;;
      *)
        die "shiplog: unknown append option: $1" ;;
    esac
  done

  if [ $json_from_stdin -eq 1 ]; then
    extra_json="$(cat)"
  fi

  [ -n "$extra_json" ] || die "shiplog: --json is required"

  if printf '%s' "$extra_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    extra_json=$(printf '%s' "$extra_json" | jq -c .)
  else
    die "shiplog: --json payload must be a JSON object"
  fi
  # Extras may not forge core fields (seq, status, trust_oid, ...); the check
  # names the offending key (SLT.BUG.CLI.010). compose_message repeats it.
  shiplog_extra_json_check "$extra_json" "--json payload"

  if [ -z "$service" ]; then
    die "shiplog: --service (or SHIPLOG_SERVICE) is required in append"
  fi

  (
    set -e
    SHIPLOG_BORING=1
    SHIPLOG_ASSUME_YES=1
    export SHIPLOG_BORING SHIPLOG_ASSUME_YES
    export SHIPLOG_EXTRA_JSON="$extra_json"
    export SHIPLOG_SERVICE="$service"
    [ -n "$status" ] && export SHIPLOG_STATUS="$status"
    [ -n "$reason" ] && export SHIPLOG_REASON="$reason"
    [ -n "$ticket" ] && export SHIPLOG_TICKET="$ticket"
    [ -n "$region" ] && export SHIPLOG_REGION="$region"
    [ -n "$cluster" ] && export SHIPLOG_CLUSTER="$cluster"
    [ -n "$namespace" ] && export SHIPLOG_NAMESPACE="$namespace"
    [ -n "$image" ] && export SHIPLOG_IMAGE="$image"
    [ -n "$tag" ] && export SHIPLOG_TAG="$tag"
    [ -n "$run_url" ] && export SHIPLOG_RUN_URL="$run_url"
    [ -n "$log_path" ] && export SHIPLOG_LOG="$log_path"
    SHIPLOG_DRY_RUN="$dry_run"
    export SHIPLOG_DRY_RUN
    cmd_write --env "$env"
  )
  return $?
}

cmd_ls() {
  ensure_in_repo
  # `--` after the command name now reaches the subcommand (see the global
  # parser), so it must end option parsing here instead of being an unknown flag.
  local -a pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h)
        printf 'Usage: git shiplog ls [ENV] [LIMIT]\n\nList the most recent LIMIT entries (default 20) of the ENV journal.\n'
        return 0 ;;
      --) shift; pos+=("$@"); break ;;
      -*) die "shiplog: unknown ls option: $1 (see git shiplog ls --help)" ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  local env="${pos[0]:-$DEFAULT_ENV}"
  local limit="${pos[1]:-20}"
  [ "${#pos[@]}" -le 2 ] || die "shiplog: unexpected argument to ls: ${pos[2]} (usage: git shiplog ls [ENV] [LIMIT])"
  # A bad LIMIT used to fail inside rev-list's process substitution and print an
  # empty table with exit 0.
  case "$limit" in
    ''|*[!0-9]*|0*) die "shiplog: ls LIMIT must be a positive integer, got '$limit'" ;;
  esac
  shiplog_validate_env_name "$env"
  local ref; ref="$(ref_journal "$env")"
  [ -n "$(current_tip "$ref")" ] || die "No entries at $ref"
  pretty_ls "$ref" "$limit"
}

cmd_show() {
  ensure_in_repo
  local json_only=0 boring_local=0 compact=0
  local target=""
  # Flags are accepted in any position (`show <sha> --json` works) and unknown
  # flags are errors instead of being silently dropped (#139 B).
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json_only=1; shift; continue ;;
      --json-compact|--jsonl) json_only=1; compact=1; shift; continue ;;
      --boring|-b) boring_local=1; shift; continue ;;
      --help|-h)
        cat <<'EOF'
Usage: git shiplog show [--json|--json-compact|--jsonl] [--boring] [COMMIT|REF]

Show one journal entry (defaults to the latest entry of the current environment).
Flags may appear before or after the target.

Options:
  --json                 Print only the JSON trailer (pretty)
  --json-compact, --jsonl
                         Print only the JSON trailer as one compact line
  --boring, -b           Plain output (no Bosun boxes)
EOF
        return 0 ;;
      --)
        shift
        if [ $# -gt 0 ]; then
          [ -z "$target" ] || die "shiplog: show accepts a single COMMIT|REF (got '$target' and '$1')"
          target="$1"; shift
        fi
        [ $# -eq 0 ] || die "shiplog: unexpected argument to show: $1"
        break ;;
      -*) die "shiplog: unknown show option: $1 (see git shiplog show --help)" ;;
      *)
        [ -z "$target" ] || die "shiplog: show accepts a single COMMIT|REF (got '$target' and '$1')"
        target="$1"; shift; continue ;;
    esac
  done
  # If --boring passed after subcommand, honor it
  if [ "$boring_local" -eq 1 ]; then
    SHIPLOG_BORING=1; export SHIPLOG_BORING
  fi

  # `show -- -x` reaches here with a leading dash; git would parse it as an
  # option (`--output=FILE` writes a file), so it is never a valid target.
  case "$target" in
    -*) die "shiplog: invalid target '$target' (must not start with '-')" ;;
  esac
  if [ -z "$target" ]; then
    target="$(ref_journal "$DEFAULT_ENV")"
  fi

  if [ "$json_only" -eq 1 ]; then
    local body json
    body="$(git show -s --format=%B "$target")"
    json="$(shiplog_extract_trailer <<< "$body")"
    if [ -z "$json" ]; then
      die "No JSON payload found in entry $target"
    fi
    if [ "$compact" -eq 1 ]; then
      if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$json" | jq -c .
      else
        # Best-effort: collapse whitespace
        printf '%s\n' "$json" | tr -d '\n' | tr -s ' '
      fi
    else
      if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$json" | jq .
      else
        printf '%s\n' "$json"
      fi
    fi
    return 0
  fi

  show_entry "$target"
}

cmd_verify() {
  ensure_in_repo
  local env="$DEFAULT_ENV" positional_env="" allow_empty=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --allow-empty) allow_empty=1; shift ;;
      --help|-h)
        cat <<'EOF'
Usage: git shiplog verify [ENV] [--allow-empty]

Verify signatures and author authorization for every entry of the ENV journal.
Fails when the journal does not exist, when any entry has a bad signature or an
unauthorized author, or when no entry verified OK (pass --allow-empty to accept
an empty result).
EOF
        return 0 ;;
      --)
        shift
        if [ $# -gt 0 ]; then
          [ -z "$positional_env" ] || die "shiplog: verify accepts a single ENV argument (got '$positional_env' and '$1')"
          positional_env="$1"; shift
        fi
        [ $# -eq 0 ] || die "shiplog: unexpected argument to verify: $1"
        break ;;
      -*) die "shiplog: unknown verify option: $1 (see git shiplog verify --help)" ;;
      *)
        [ -z "$positional_env" ] || die "shiplog: verify accepts a single ENV argument (got '$positional_env' and '$1')"
        positional_env="$1"; shift ;;
    esac
  done
  if [ -n "$positional_env" ]; then
    env="$positional_env"
  fi
  shiplog_validate_env_name "$env"
  local ref; ref="$(ref_journal "$env")"
  # A missing ref used to make rev-list fail silently inside the process
  # substitution and the command reported "OK=0" with exit 0 (#124).
  git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 \
    || die "shiplog: journal $ref not found (nothing to verify for env '$env')"
  # Evaluate the rules of the journal being verified, not the default env's.
  shiplog_policy_load "$env"
  shiplog_policy_enforce
  local ok=0 bad=0 unauth=0 author c
  while IFS= read -r c; do
    if ensure_signed_on_verify "$c"; then
      author="$(git show -s --format='%ae' "$c")"
      if author_allowed "$author"; then
        ok=$((ok+1))
      else
        unauth=$((unauth+1)); echo "❌ unauthorized author <$author> on $c" >&2
      fi
    else
      bad=$((bad+1)); echo "❌ bad or missing signature on $c" >&2
    fi
  done < <(git rev-list "$ref")
  local verify_summary="Verified: OK=$ok, BadSig=$bad, Unauthorized=$unauth"
  if shiplog_can_use_bosun; then
    local bosun
    bosun=$(shiplog_bosun_bin)
    "$bosun" style --title "Verify" -- "$verify_summary"
  else
    printf '%s\n' "$verify_summary"
  fi
  if [ "$ok" -eq 0 ] && [ "$allow_empty" -ne 1 ]; then
    echo "❌ shiplog: no entry in $ref verified OK (pass --allow-empty to accept an empty result)" >&2
    return 1
  fi
  [ $bad -eq 0 ] && [ $unauth -eq 0 ]
}

cmd_export_json() {
  ensure_in_repo
  command -v jq >/dev/null 2>&1 || die "jq required for --json export"
  local env="$DEFAULT_ENV" positional_env="" lenient=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --lenient) lenient=1; shift ;;
      --help|-h)
        cat <<'EOF'
Usage: git shiplog export-json [ENV] [--lenient]

Emit one JSON line per journal entry (newest first): the entry trailer plus a
"commit" field. An entry whose trailer is missing or malformed is emitted as
  {"commit":"<sha>","error":"invalid trailer","subject":"<first line>"}
and the export continues. Exit status is 3 when any entry was flagged unless
--lenient is passed.
EOF
        return 0 ;;
      --)
        shift
        if [ $# -gt 0 ]; then
          [ -z "$positional_env" ] || die "shiplog: export-json accepts a single ENV argument (got '$positional_env' and '$1')"
          positional_env="$1"; shift
        fi
        [ $# -eq 0 ] || die "shiplog: unexpected argument to export-json: $1"
        break ;;
      -*) die "shiplog: unknown export-json option: $1 (see git shiplog export-json --help)" ;;
      *)
        [ -z "$positional_env" ] || die "shiplog: export-json accepts a single ENV argument (got '$positional_env' and '$1')"
        positional_env="$1"; shift ;;
    esac
  done
  if [ -n "$positional_env" ]; then
    env="$positional_env"
  fi
  shiplog_validate_env_name "$env"
  local ref; ref="$(ref_journal "$env")"
  git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 \
    || die "shiplog: journal $ref not found (nothing to export for env '$env')"
  # Notes live at the resolved notes ref (SHIPLOG_NOTES_REF > policy notes_ref >
  # <ref root>/notes/logs); report whether each entry has a log attached there.
  local notes_ref; notes_ref=$(shiplog_notes_git_ref)
  local notes_present=0 has_note
  if git rev-parse -q --verify "$notes_ref" >/dev/null 2>&1; then
    notes_present=1
  fi
  # One line per commit, always. A missing or invalid trailer used to either
  # vanish from the stream (jq printed nothing) or abort the export mid-way
  # under errexit (#125); it now produces an error record and the loop goes on.
  local c body trailer line subject flagged=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    body="$(git show -s --format=%B "$c" 2>/dev/null || true)"
    trailer="$(shiplog_extract_trailer <<< "$body")"
    line=""
    has_note=false
    if [ "$notes_present" -eq 1 ] && git notes --ref="$notes_ref" list "$c" >/dev/null 2>&1; then
      has_note=true
    fi
    if [ -n "$trailer" ]; then
      line=$(printf '%s\n' "$trailer" | jq -c -s --arg sha "$c" --arg notes_ref "$notes_ref" --argjson has_note "$has_note" 'if length == 1 and (.[0] | type) == "object" then .[0] + {commit:$sha, notes:{ref:$notes_ref, attached:$has_note}} else error("invalid trailer") end' 2>/dev/null) || line=""
    fi
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
    else
      flagged=$((flagged+1))
      subject="$(printf '%s\n' "$body" | head -n1)"
      jq -n -c --arg sha "$c" --arg subject "$subject" '{commit:$sha, error:"invalid trailer", subject:$subject}'
    fi
  done < <(git rev-list "$ref")
  if [ "$flagged" -gt 0 ]; then
    printf '⚠️ shiplog: %s entr%s in %s had an invalid trailer\n' "$flagged" "$([ "$flagged" -eq 1 ] && printf 'y' || printf 'ies')" "$ref" >&2
    if [ "$lenient" -ne 1 ]; then
      return 3
    fi
  fi
  return 0
}

# journal_claims_attached_logs REF
# True when any entry on REF carries a structured trailer with log_attached=true.
journal_claims_attached_logs() {
  local ref="$1"
  git rev-parse -q --verify "$ref" >/dev/null 2>&1 || return 1
  git log --format=%B "$ref" 2>/dev/null | grep -Eq '"log_attached":[[:space:]]*true'
}

cmd_publish() {
  ensure_in_repo
  local env="$DEFAULT_ENV" push_notes=1 push_policy=0 push_trust=0 all_envs=0
  local positional_env=""
  local publish_usage="Usage: git shiplog publish [ENV] [--env ENV] [--no-notes] [--policy] [--trust] [--all]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --env) shiplog_require_flag_value "$1" $#; shift; env="$1"; shift; continue ;;
      --env=*) env="${1#*=}"; shift; continue ;;
      --no-notes) push_notes=0; shift; continue ;;
      --policy) push_policy=1; shift; continue ;;
      --trust) push_trust=1; shift; continue ;;
      --all|--all-envs) all_envs=1; shift; continue ;;
      --help|-h)
        cat <<'EOF'
Usage: git shiplog publish [ENV] [--env ENV] [--no-notes] [--policy] [--trust] [--all]

Push Shiplog refs to the configured remote (defaults to origin) without writing
new entries. By default pushes one environment journal and its notes.
ENV precedence: positional ENV > --env > SHIPLOG_ENV > default (prod).
Use --all to push all journals under the ref root. Optionally include
policy/trust refs.
EOF
        return 0 ;;
      --)
        shift
        if [ $# -gt 0 ]; then
          [ -z "$positional_env" ] || die "shiplog: publish accepts a single ENV argument (got '$positional_env' and '$1'). $publish_usage"
          positional_env="$1"; shift
        fi
        [ $# -eq 0 ] || die "shiplog: unexpected argument to publish: $1. $publish_usage"
        break ;;
      -*) die "shiplog: unknown publish option: $1. $publish_usage" ;;
      *)
        # The documented `publish [ENV]` form; the positional used to be dropped
        # and the default journal pushed instead (#101).
        [ -z "$positional_env" ] || die "shiplog: publish accepts a single ENV argument (got '$positional_env' and '$1'). $publish_usage"
        positional_env="$1"; shift; continue ;;
    esac
  done
  if [ -n "$positional_env" ]; then
    env="$positional_env"
  fi
  shiplog_validate_env_name "$env"

  local remote
  remote=$(shiplog_remote_name)
  has_remote_origin || die "shiplog: remote '$remote' not configured"

  local refs=()
  if [ "$all_envs" -eq 1 ]; then
    # Prefix match (no glob) so nested journal names under the root are included.
    while read -r j; do [ -n "$j" ] && refs+=("$j"); done < <(git for-each-ref --format='%(refname)' "$JOURNALS_REF_PREFIX")
  else
    refs+=("$(ref_journal "$env")")
  fi

  local trust_ref="${TRUST_REF:-$TRUST_REF_DEFAULT}"
  local notes_ref; notes_ref=$(shiplog_notes_ref)
  local push_output

  # Order matters for a server running the pre-receive hook: journals are
  # validated against the trust and policy the server already has.
  if [ "$push_trust" -eq 1 ]; then
    git rev-parse -q --verify "$trust_ref" >/dev/null 2>&1 || die "shiplog: trust ref $trust_ref not found locally; nothing to publish"
    if ! push_output=$(git push --no-verify "$remote" "$trust_ref" 2>&1); then
      die "shiplog: failed to push $trust_ref to $remote: $push_output"
    fi
  fi
  if [ "$push_policy" -eq 1 ]; then
    git rev-parse -q --verify "$POLICY_REF" >/dev/null 2>&1 || die "shiplog: policy ref $POLICY_REF not found locally; nothing to publish"
    if ! push_output=$(git push --no-verify "$remote" "$POLICY_REF" 2>&1); then
      die "shiplog: failed to push $POLICY_REF to $remote: $push_output"
    fi
  fi

  # Decide about notes before pushing anything. When the resolved notes ref does
  # not exist locally but an entry says its log was attached, the notes live
  # somewhere else (ref root or policy notes_ref drift) and would silently never
  # be published (#123): refuse instead of pushing journals without their logs.
  local notes_available=0
  if [ "$push_notes" -eq 1 ]; then
    if git rev-parse -q --verify "$notes_ref" >/dev/null 2>&1; then
      notes_available=1
    else
      for r in "${refs[@]}"; do
        if journal_claims_attached_logs "$r"; then
          die "shiplog: entries in $r claim log_attached=true but notes ref $notes_ref does not exist locally; check policy notes_ref, SHIPLOG_NOTES_REF and the ref root (git shiplog refs root show) before publishing"
        fi
      done
    fi
  fi

  for r in "${refs[@]}"; do
    if ! push_output=$(git push --no-verify "$remote" "$r" 2>&1); then
      die "shiplog: failed to push $r to $remote: $push_output"
    fi
  done
  if [ "$notes_available" -eq 1 ]; then
    if ! push_output=$(git push --no-verify "$remote" "$notes_ref" 2>&1); then
      die "shiplog: failed to push notes ref $notes_ref to $remote: $push_output"
    fi
  fi

  local pushed_list="${refs[*]}"
  if shiplog_can_use_bosun; then
    local bosun; bosun=$(shiplog_bosun_bin)
    "$bosun" style --title "Publish" -- "📤 Pushed Shiplog refs to $remote: $pushed_list"
  else
    printf '📤 Pushed Shiplog refs to %s: %s\n' "$remote" "$pushed_list"
  fi
}


# Runs scripts/shiplog-sync-policy.sh for POLICY_FILE and stops before advancing
# the local policy ref when the helper (and therefore the validator) fails. The
# helper's diagnostics are surfaced instead of swallowed (SLT.BUG.TOOL.006).
shiplog_policy_sync_ref() {
  local policy_file="$1"
  local sync_helper="$SHIPLOG_HOME/scripts/shiplog-sync-policy.sh"
  if [ ! -x "$sync_helper" ]; then
    printf 'Note: sync helper missing; commit and publish policy manually.\n'
    return 0
  fi
  local errf out status=0
  errf=$(mktemp) || die "shiplog: unable to create a temp file for the policy sync log"
  out=$("$sync_helper" "$policy_file" 2>"$errf") || status=$?
  if [ "$status" -ne 0 ]; then
    [ -n "$out" ] && printf '%s\n' "$out" >&2
    [ -s "$errf" ] && cat "$errf" >&2
    rm -f "$errf"
    die "shiplog: policy sync failed (status $status); the local policy ref was not updated"
  fi
  # Hints (for example "publishing unsigned") stay visible.
  [ -s "$errf" ] && cat "$errf" >&2
  rm -f "$errf"
  return 0
}

shiplog_policy_usage() {
  cat <<'EOF'
Usage: git shiplog policy [show|validate|require-signed <true|false>|toggle] [OPTIONS]

  show [--env ENV] [--json|--boring]   Effective policy for ENV (default: global --env / SHIPLOG_ENV)
                                       with the source of every field. Does not require the
                                       allowed signers file to exist (warns instead).
  validate [--ref] [--file PATH]       Validate the working-tree .shiplog/policy.json when present,
                                       else the published policy ref. --ref forces the ref,
                                       --file validates an arbitrary file.
  require-signed <true|false>          Set require_signed in .shiplog/policy.json and sync the
                                       local policy ref (aborts when the result fails validation).
  toggle                               Flip require_signed.
EOF
}

cmd_policy() {
  ensure_in_repo

  local boring=0 as_json=0 action=""
  local policy_env="$DEFAULT_ENV"
  local validate_source="auto" validate_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --boring|-b) boring=1; shift ;;
      --json) as_json=1; shift ;;
      --help|-h) shiplog_policy_usage; return 0 ;;
      --env) shift; policy_env="${1:-}"; [ -n "$policy_env" ] || die "shiplog: --env requires a value"; shift ;;
      --env=*) policy_env="${1#*=}"; [ -n "$policy_env" ] || die "shiplog: --env requires a value"; shift ;;
      show|validate|require-signed|toggle) action="$1"; shift; break ;;
      *) action="$1"; shift; break ;;
    esac
  done
  action="${action:-show}"

  # Flags may also follow the action (e.g. `policy show --json`, `policy validate --ref`).
  local -a rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --boring|-b) boring=1; shift ;;
      --json) as_json=1; shift ;;
      --env) shift; policy_env="${1:-}"; [ -n "$policy_env" ] || die "shiplog: --env requires a value"; shift ;;
      --env=*) policy_env="${1#*=}"; [ -n "$policy_env" ] || die "shiplog: --env requires a value"; shift ;;
      --ref) validate_source="ref"; shift ;;
      --file) shift; validate_file="${1:-}"; [ -n "$validate_file" ] || die "shiplog: policy validate --file requires a path"; validate_source="file"; shift ;;
      --file=*) validate_file="${1#*=}"; [ -n "$validate_file" ] || die "shiplog: policy validate --file requires a path"; validate_source="file"; shift ;;
      --help|-h) shiplog_policy_usage; return 0 ;;
      --) shift; break ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  set -- ${rest[@]+"${rest[@]}"} "$@"

  if [ "$boring" -eq 1 ]; then
    SHIPLOG_BORING=1; export SHIPLOG_BORING
  fi
  if [ "$as_json" -eq 1 ]; then
    command -v jq >/dev/null 2>&1 || die "jq required for --json output"
  fi

  local repo_root
  repo_root=$(shiplog_repo_root) || die "shiplog: unable to determine the repository root"
  local policy_file="$repo_root/.shiplog/policy.json"
  local policy_display=".shiplog/policy.json"
  local policy_ref="${POLICY_REF:-$REF_ROOT/policy/current}"

  # Raw document text (ref first, then working tree) for informational output.
  load_raw_policy() {
    local raw=""
    if git rev-parse -q --verify "$policy_ref" >/dev/null 2>&1; then
      raw=$(git show "$policy_ref:.shiplog/policy.json" 2>/dev/null || true)
    fi
    if [ -z "$raw" ] && [ -f "$policy_file" ]; then
      raw=$(cat "$policy_file" 2>/dev/null || true)
    fi
    printf '%s' "$raw"
  }

  case "$action" in
    show|"")
      if [ "$as_json" -eq 1 ]; then
        SHIPLOG_POLICY_QUIET=1
      fi
      shiplog_policy_load "$policy_env"
      local require_signed_bool="false"
      [ "${SHIPLOG_SIGN_EFFECTIVE:-0}" = 1 ] && require_signed_bool="true"
      local signers_exists="false"
      [ -n "$SIGNERS_FILE_EFFECTIVE" ] && [ -r "$SIGNERS_FILE_EFFECTIVE" ] && signers_exists="true"
      local warnings
      warnings=$(shiplog_policy_warnings)
      if [ "$as_json" -eq 1 ]; then
        local raw_policy env_map warnings_json
        raw_policy=$(load_raw_policy); [ -n "$raw_policy" ] || raw_policy='{}'
        # Per-environment require_signed map (explicit values only; null when inherited).
        env_map=$(printf '%s\n' "$raw_policy" | jq -c '(.deployment_requirements // {}) | with_entries(.value = (if (.value|type) == "object" and (.value|has("require_signed")) then .value.require_signed else null end))' 2>/dev/null || printf '{}')
        warnings_json=$(printf '%s' "$warnings" | jq -R . | jq -s 'map(select(. != ""))')
        jq -n \
          --arg env "$policy_env" \
          --arg source "${POLICY_SOURCE:-default}" \
          --arg authors "${ALLOWED_AUTHORS_EFFECTIVE:-}" \
          --arg signers "${SIGNERS_FILE_EFFECTIVE:-}" \
          --argjson signers_exists "$signers_exists" \
          --arg notes "$NOTES_REF" \
          --argjson req "$require_signed_bool" \
          --arg src_authors "${POLICY_SOURCE_AUTHORS:-default}" \
          --arg src_signers "${POLICY_SOURCE_SIGNERS:-default}" \
          --arg src_req "${POLICY_SOURCE_REQUIRE_SIGNED:-default}" \
          --arg src_notes "${POLICY_SOURCE_NOTES_REF:-default}" \
          --argjson env_map "$env_map" \
          --argjson warnings "$warnings_json" \
          '{env:$env, source:$source, require_signed:$req, allowed_authors:$authors,
            allowed_signers_file:$signers, allowed_signers_file_exists:$signers_exists, notes_ref:$notes,
            sources:{authors:$src_authors, allowed_signers_file:$src_signers, require_signed:$src_req, notes_ref:$src_notes},
            env_require_signed:$env_map, warnings:$warnings}'
      else
        local signed_status; if [ "$require_signed_bool" = "true" ]; then signed_status="enabled"; else signed_status="disabled"; fi
        if ! shiplog_can_use_bosun; then
          printf 'Environment: %s\n' "$policy_env"
          printf 'Source: %s\n' "${POLICY_SOURCE:-default}"
          printf 'Require Signed: %s (from %s)\n' "$signed_status" "${POLICY_SOURCE_REQUIRE_SIGNED:-default}"
          printf 'Allowed Authors: %s (from %s)\n' "${ALLOWED_AUTHORS_EFFECTIVE:-<none>}" "${POLICY_SOURCE_AUTHORS:-default}"
          printf 'Allowed Signers File: %s (from %s)\n' "${SIGNERS_FILE_EFFECTIVE:-<none>}" "${POLICY_SOURCE_SIGNERS:-default}"
          printf 'Notes Ref: %s (from %s)\n' "$NOTES_REF" "${POLICY_SOURCE_NOTES_REF:-default}"
          local raw_policy; raw_policy=$(load_raw_policy)
          if [ -n "$raw_policy" ]; then
            printf '%s\n' "$raw_policy" | jq -r '(.deployment_requirements // {}) | to_entries | map(select((.value|type) == "object" and (.value|has("require_signed")))) | .[] | "Require Signed (\(.key)): \(.value.require_signed)"' 2>/dev/null || true
          fi
          if [ -n "$warnings" ]; then
            printf '%s\n' "$warnings"
          fi
        else
          local rows="" raw_policy
          rows+='Environment'$'\t'"$policy_env"$'\n'
          rows+='Source'$'\t'"${POLICY_SOURCE:-default}"$'\n'
          rows+='Require Signed'$'\t'"$signed_status (from ${POLICY_SOURCE_REQUIRE_SIGNED:-default})"$'\n'
          rows+='Allowed Authors'$'\t'"${ALLOWED_AUTHORS_EFFECTIVE:-<none>} (from ${POLICY_SOURCE_AUTHORS:-default})"$'\n'
          rows+='Allowed Signers File'$'\t'"${SIGNERS_FILE_EFFECTIVE:-<none>} (from ${POLICY_SOURCE_SIGNERS:-default})"$'\n'
          rows+='Notes Ref'$'\t'"$NOTES_REF (from ${POLICY_SOURCE_NOTES_REF:-default})"$'\n'
          raw_policy=$(load_raw_policy)
          if [ -n "$raw_policy" ]; then
            mapfile -t policy_rows < <(
              printf '%s\n' "$raw_policy" |
                jq -r '(.deployment_requirements // {}) | to_entries | map(select((.value|type) == "object" and (.value|has("require_signed")))) | .[] | "\(.key)\t\(.value.require_signed)"' 2>/dev/null
            )
            for row in "${policy_rows[@]}"; do
              IFS=$'\t' read -r env_name env_req <<<"$row"
              [ -z "$env_name" ] && continue
              rows+='Require Signed ('"$env_name"$')'$'\t'"$env_req"$'\n'
            done
          fi
          local bosun; bosun=$(shiplog_bosun_bin)
          printf '%s' "$rows" | "$bosun" table --columns "Field,Value"
          if [ -n "$warnings" ]; then
            "$bosun" style --title "Policy Warning" -- "$warnings"
          fi
        fi
      fi
      ;;
    validate)
      need jq
      # Validate what is about to be published: the working-tree file when present,
      # otherwise the published ref. --ref / --file override (SLT.BUG.LIB.013).
      local raw_policy="" label=""
      local ref_present=0
      git rev-parse -q --verify "$policy_ref" >/dev/null 2>&1 && ref_present=1
      case "$validate_source" in
        file)
          [ -r "$validate_file" ] || die "shiplog: cannot read policy file: $validate_file"
          raw_policy=$(cat "$validate_file")
          label="file:$validate_file"
          ;;
        ref)
          [ "$ref_present" -eq 1 ] || die "shiplog: policy ref $policy_ref not found"
          raw_policy=$(git show "$policy_ref:.shiplog/policy.json" 2>/dev/null) || die "shiplog: policy ref $policy_ref has no .shiplog/policy.json"
          label="policy-ref:$policy_ref"
          ;;
        *)
          if [ -f "$policy_file" ]; then
            raw_policy=$(cat "$policy_file")
            label="policy-file:$policy_display"
            if [ "$ref_present" -eq 1 ]; then
              local ref_raw wt_norm ref_norm
              ref_raw=$(git show "$policy_ref:.shiplog/policy.json" 2>/dev/null || true)
              wt_norm=$(printf '%s\n' "$raw_policy" | jq -cS . 2>/dev/null || printf '%s' "$raw_policy")
              ref_norm=$(printf '%s\n' "$ref_raw" | jq -cS . 2>/dev/null || printf '%s' "$ref_raw")
              if [ "$wt_norm" != "$ref_norm" ]; then
                printf 'ℹ️ shiplog: working tree %s differs from %s; validating the working tree (use --ref for the published policy)\n' "$policy_display" "$policy_ref"
              fi
            fi
          elif [ "$ref_present" -eq 1 ]; then
            raw_policy=$(git show "$policy_ref:.shiplog/policy.json" 2>/dev/null) || die "shiplog: policy ref $policy_ref has no .shiplog/policy.json"
            label="policy-ref:$policy_ref"
          else
            die "shiplog: no policy found (expected at $policy_ref:.shiplog/policy.json or $policy_display)"
          fi
          ;;
      esac
      if [ -z "$raw_policy" ]; then
        die "shiplog: policy document ($label) is empty"
      fi

      # Ensure JSON parses
      if ! printf '%s\n' "$raw_policy" | jq . >/dev/null 2>&1; then
        die "shiplog: policy JSON is not parseable ($label)"
      fi
      local value_count
      value_count=$(printf '%s\n' "$raw_policy" | jq -n '[inputs] | length')
      [ "$value_count" = 1 ] || die "shiplog: policy document ($label) must contain exactly one JSON value (found $value_count)"

      # Structural checks (jq-only; AJV lives in CI). scripts/lib/policy_validate.jq is canonical.
      local errs=""
      local validator_status=0
      local validator_bin=""
      local validator_filter=""
      local search_root="${SHIPLOG_HOME:-$repo_root}"
      local candidate
      for candidate in \
        "${SHIPLOG_POLICY_VALIDATE_BIN:-}" \
        "$search_root/scripts/policy/validate.sh" \
        "$repo_root/scripts/policy/validate.sh"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
          validator_bin="$candidate"
          break
        fi
      done
      if [ -z "$validator_bin" ]; then
        for candidate in \
          "${SHIPLOG_POLICY_VALIDATOR:-}" \
          "$search_root/scripts/lib/policy_validate.jq" \
          "$repo_root/scripts/lib/policy_validate.jq"; do
          if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            validator_filter="$candidate"
            break
          fi
        done
      fi
      # Capture exit codes with `status=0; out=$(...) || status=$?` so errexit cannot
      # abort before the diagnostics are printed (SLT.BUG.TRUST.012).
      if [ -n "$validator_bin" ]; then
        validator_status=0
        errs=$(printf '%s\n' "$raw_policy" | "$validator_bin" --stdin 2>&1) || validator_status=$?
      else
        if [ -z "$validator_filter" ]; then
          die "shiplog: policy validator filter not found (expected scripts/lib/policy_validate.jq)"
        fi
        validator_status=0
        errs=$(printf '%s\n' "$raw_policy" | jq -r -f "$validator_filter" 2>&1) || validator_status=$?
        if [ "$validator_status" -ne 0 ]; then
          if [ -n "$errs" ]; then
            printf '%s\n' "$errs" >&2
          fi
          printf 'shiplog: policy validator jq exited with status %s\n' "$validator_status" >&2
          return "$validator_status"
        fi
      fi

      if [ -n "$validator_bin" ]; then
        if [ "$validator_status" -gt 1 ]; then
          if [ -n "$errs" ]; then
            printf '%s\n' "$errs" >&2
          fi
          printf 'shiplog: policy validator exited with status %s\n' "$validator_status" >&2
          return "$validator_status"
        fi
        if [ "$validator_status" -eq 1 ] && [ -z "$errs" ]; then
          errs="policy.json failed validation"
        fi
      fi

      if [ -n "$errs" ]; then
        if shiplog_can_use_bosun; then
          local bosun; bosun=$(shiplog_bosun_bin)
          "$bosun" style --title "Policy Validation" -- "❌ Invalid policy ($label)"
          printf '%s\n' "$errs" | "$bosun" style --title "Errors" --
        else
          # Print to stdout to make assertions simpler in tests
          printf '❌ shiplog: policy validation failed (%s)\n' "$label"
          printf '%s\n' "$errs"
        fi
        return 1
      fi
      [ "$validator_status" -eq 0 ] || return 1

      if shiplog_can_use_bosun; then
        local bosun; bosun=$(shiplog_bosun_bin)
        "$bosun" style --title "Policy Validation" -- "✅ Policy OK ($label)"
      else
        printf '✅ Policy OK (%s)\n' "$label"
      fi
      ;;
    require-signed)
      # Edits the document directly; no effective-policy load, so a repository can
      # be repaired while signing is on and the roster is missing (SLT.BUG.CLI.015).
      local val="${1:-}" parsed
      parsed=$(shiplog_parse_bool "$val") || die "Usage: git shiplog policy require-signed <true|false>"
      if [ "$parsed" = 1 ]; then val=true; else val=false; fi
      mkdir -p "$repo_root/.shiplog"
      local tmp; tmp=$(mktemp)
      if [ -f "$policy_file" ]; then
        jq --argjson rs "$val" --arg ver "1.0.0" '
          (.version // $ver) as $v
          | .version = (if (($v|type) == "string") and ($v|test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) then $v else $ver end)
          | .require_signed = $rs
        ' "$policy_file" >"$tmp" 2>/dev/null || { rm -f "$tmp"; die "shiplog: failed to update $policy_display (is it valid JSON?)"; }
      else
        printf '{"version":"1.0.0","require_signed":%s}\n' "$val" >"$tmp"
      fi
      policy_install_file "$tmp" "$policy_file"
      local using_bosun=0 bosun=""
      if shiplog_can_use_bosun; then
        using_bosun=1
        bosun=$(shiplog_bosun_bin)
      fi

      if [ "$using_bosun" -eq 1 ]; then
        "$bosun" style --title "Policy" -- "Set require_signed to $val in $policy_display"
      else
        printf 'Set require_signed to %s in %s\n' "$val" "$policy_display"
      fi

      local publish_remote; publish_remote=$(shiplog_remote_name)
      shiplog_policy_sync_ref "$policy_file"
      if [ -x "$SHIPLOG_HOME/scripts/shiplog-sync-policy.sh" ]; then
        if [ "$using_bosun" -eq 1 ]; then
          "$bosun" style --title "Policy" -- "📤 Updated $POLICY_REF (push to publish)"
        else
          printf 'Updated policy ref locally. Run: git push --no-verify %s %s\n' "$publish_remote" "$POLICY_REF"
        fi
      fi
      ;;
    toggle)
      shiplog_policy_load "$policy_env"
      local new="true"
      [ "${SHIPLOG_SIGN_EFFECTIVE:-0}" = 1 ] && new="false"
      cmd_policy --env "$policy_env" require-signed "$new" ;;
    *) die "Unknown policy subcommand: $action" ;;
  esac
}

cmd_trust() {
  ensure_in_repo
  local action="${1:-sync}"
  shift || true
  case "$action" in
    --help|-h)
      printf 'Usage: git shiplog trust <sync [REF] [DEST] | show [REF] [--json]>\n'
      return 0 ;;
    sync)
      case "${1:-}" in
        --help|-h)
          printf 'Usage: git shiplog trust sync [REF] [DEST]\n\nRefresh the allowed signers file (default .shiplog/allowed_signers) from the trust ref.\n'
          return 0 ;;
      esac
      local ref="${1:-${TRUST_REF:-$TRUST_REF_DEFAULT}}"
      local dest="${2:-.shiplog/allowed_signers}"
      [ -x "$SHIPLOG_HOME/scripts/shiplog-trust-sync.sh" ] || die "shiplog: trust sync helper missing at $SHIPLOG_HOME/scripts/shiplog-trust-sync.sh"
      "$SHIPLOG_HOME"/scripts/shiplog-trust-sync.sh "$ref" "$dest"
      ;;
    show)
      need jq
      local ref=""
      local as_json=0
      local boring=0
      if [ $# -gt 0 ]; then
        case "$1" in
          -*) : ;; # option; leave for main loop
          *) ref="$1"; shift ;;
        esac
      fi
      while [ $# -gt 0 ]; do
        case "$1" in
          --json)
            as_json=1; shift ;;
          --boring|-b)
            boring=1; shift ;;
          --help|-h)
            printf 'Usage: git shiplog trust show [REF] [--json]\n'
            return 0 ;;
          --)
            shift; break ;;
          *)
            die "shiplog: unknown trust show option: $1" ;;
        esac
      done
      [ -n "$ref" ] || ref="${TRUST_REF:-$TRUST_REF_DEFAULT}"

      local trust_json
      trust_json=$(git show "$ref:trust.json" 2>/dev/null || true)
      [ -n "$trust_json" ] || die "shiplog: trust metadata not found at $ref:trust.json"

      if [ "$as_json" -eq 1 ]; then
        printf '%s\n' "$trust_json"
        return 0
      fi

      local trust_id threshold maintainer_rows signer_count
      trust_id=$(printf '%s\n' "$trust_json" | jq -r '.id // "(unknown)"')
      threshold=$(printf '%s\n' "$trust_json" | jq -r '.threshold // "(unset)"')
      maintainer_rows=$(printf '%s\n' "$trust_json" | jq -r '.maintainers[]? | [(.name // ""), (.email // ""), (.role // "maintainer"), (if (.revoked // false) then "yes" else "no" end)] | @tsv')
      signer_count=$(git show "$ref:allowed_signers" 2>/dev/null | awk 'NF && $1 !~ /^#/ {count++} END {print count+0}' || true)

      if [ "$signer_count" = "" ]; then
        signer_count=0
      fi

      if [ $boring -eq 1 ]; then
        SHIPLOG_BORING=1; export SHIPLOG_BORING
      fi

      printf 'Trust ID: %s\n' "$trust_id"
      printf 'Threshold: %s\n' "$threshold"
      printf 'Allowed signers: %s\n' "$signer_count"
      local signer_rows
      signer_rows=$(git show "$ref:allowed_signers" 2>/dev/null | awk 'NF && $1 !~ /^#/ {principal=$1; type=$2; if(type=="") type="(unknown)"; print principal"\t"type}' || true)

      if [ -n "$maintainer_rows" ]; then
        if shiplog_can_use_bosun; then
          local bosun; bosun=$(shiplog_bosun_bin)
          printf '%s\n' "$maintainer_rows" | "$bosun" table --columns "Name,Email,Role,Revoked"
          if [ -n "$signer_rows" ]; then
            printf '%s\n' "$signer_rows" | "$bosun" table --columns "Signer,KeyType"
          fi
        else
          printf 'Maintainers:\n'
          printf '%s\n' "$maintainer_rows" | while IFS=$'\t' read -r name email role revoked; do
            local revoked_note=""
            [ "$revoked" = "yes" ] && revoked_note=" (revoked)"
            printf '  - %s <%s> [%s]%s\n' "$name" "$email" "$role" "$revoked_note"
          done
          if [ -n "$signer_rows" ]; then
            printf 'Signers:\n'
            printf '%s\n' "$signer_rows" | while IFS=$'\t' read -r principal keytype; do
              printf '  - %s (%s)\n' "$principal" "$keytype"
            done
          fi
        fi
      else
        printf 'Maintainers: none\n'
        if [ -n "$signer_rows" ]; then
          if shiplog_can_use_bosun; then
            local bosun; bosun=$(shiplog_bosun_bin)
            printf '%s\n' "$signer_rows" | "$bosun" table --columns "Signer,KeyType"
          else
            printf 'Signers:\n'
            printf '%s\n' "$signer_rows" | while IFS=$'\t' read -r principal keytype; do
              printf '  - %s (%s)\n' "$principal" "$keytype"
            done
          fi
        fi
      fi
      ;;
    *)
      die "Unknown trust subcommand: $action"
      ;;
  esac
}

# Refs management
cmd_refs() {
  ensure_in_repo
  local sub="${1:-}"; shift || true
  case "$sub" in
    --help|-h)
      cat <<'EOF'
Usage: git shiplog refs <root show | root set REF | migrate [OPTS]>

  root show        Show the effective Shiplog ref root
  root set REF     Set shiplog.refRoot (e.g. refs/_shiplog or refs/heads/_shiplog)
  migrate [OPTS]   Mirror refs between roots (--to <refs/...> [--from <refs/...>] [--push] [--remove-old] [--dry-run])
EOF
      return 0 ;;
    root)
      local action="${1:-show}"; shift || true
      case "$action" in
        --help|-h)
          printf 'Usage: git shiplog refs root show | git shiplog refs root set <refs/...>\n'
          return 0 ;;
        show)
          # REF_ROOT / REF_ROOT_SOURCE were resolved once at startup
          # (SHIPLOG_REF_ROOT env > git config shiplog.refRoot > default).
          local as_json=0
          while [ $# -gt 0 ]; do
            case "$1" in
              --json) as_json=1; shift ;;
              --boring|-b) shift ;;
              *) die "shiplog: unknown refs root show option: $1" ;;
            esac
          done
          local source_label
          case "$REF_ROOT_SOURCE" in
            env) source_label="env (SHIPLOG_REF_ROOT)" ;;
            config) source_label="config (git config shiplog.refRoot)" ;;
            *) source_label="default" ;;
          esac
          local notes_ref; notes_ref=$(shiplog_notes_ref)
          if [ "$as_json" -eq 1 ]; then
            need jq
            jq -n \
              --arg root "$REF_ROOT" \
              --arg source "$REF_ROOT_SOURCE" \
              --arg journals "$JOURNALS_REF_PREFIX" \
              --arg anchors "$ANCHORS_REF_PREFIX" \
              --arg policy "$POLICY_REF" \
              --arg trust "$TRUST_REF" \
              --arg notes "$notes_ref" \
              '{ref_root:$root, source:$source, journals_prefix:$journals, anchors_prefix:$anchors, policy_ref:$policy, trust_ref:$trust, notes_ref:$notes}'
          else
            printf 'Ref Root: %s\n' "$REF_ROOT"
            printf 'Source: %s\n' "$source_label"
            printf 'Journals: %s/<env>\n' "$JOURNALS_REF_PREFIX"
            printf 'Anchors: %s/<env>\n' "$ANCHORS_REF_PREFIX"
            printf 'Policy Ref: %s\n' "$POLICY_REF"
            printf 'Trust Ref: %s\n' "$TRUST_REF"
            printf 'Notes Ref: %s\n' "$notes_ref"
          fi
          ;;
        set)
          local new_root="${1:-}"
          if [ -z "$new_root" ]; then
            die "Usage: git shiplog refs root set <refs/...>"
          fi
          local normalized_root
          normalized_root=$(shiplog_normalize_ref_root "$new_root") || die "shiplog: invalid ref root '$new_root' (expected refs/<name>, e.g. refs/_shiplog or refs/heads/_shiplog)"
          new_root="$normalized_root"
          git config shiplog.refRoot "$new_root"
          if [ "$REF_ROOT_SOURCE" = "env" ] && [ "$REF_ROOT" != "$new_root" ]; then
            printf '⚠️ shiplog: SHIPLOG_REF_ROOT=%s is set in this environment and takes precedence over git config; unset it to use %s\n' "$REF_ROOT" "$new_root" >&2
          fi
          if shiplog_can_use_bosun; then
            local bosun; bosun=$(shiplog_bosun_bin)
            "$bosun" style --title "Ref Root" -- "Set shiplog.refRoot to $new_root"
          else
            printf 'Set shiplog.refRoot to %s\n' "$new_root"
          fi
          ;;
        *) die "Unknown refs root action: $action" ;;
      esac
      ;;
    migrate)
      if [ ! -x "$SHIPLOG_HOME/scripts/shiplog-migrate-ref-root.sh" ]; then
        die "migration helper missing: $SHIPLOG_HOME/scripts/shiplog-migrate-ref-root.sh"
      fi
      # The global flag parser consumes --dry-run before it reaches us; forward
      # an explicit dry-run so the helper previews instead of migrating.
      local -a migrate_args=("$@")
      if [ "${SHIPLOG_DRY_RUN_EXPLICIT:-0}" = "1" ]; then
        case "${SHIPLOG_DRY_RUN:-0}" in
          0|false|no|off|'') ;;
          *) migrate_args+=(--dry-run) ;;
        esac
      fi
      "$SHIPLOG_HOME/scripts/shiplog-migrate-ref-root.sh" ${migrate_args[@]+"${migrate_args[@]}"}
      ;;
    *) die "Unknown refs subcommand: ${sub:-<none>}" ;;
  esac
}

# Setup wizard (non-interactive wrapper)
cmd_setup() {
  ensure_in_repo

  # Defaults
  local strictness="${SHIPLOG_SETUP_STRICTNESS:-open}"
  local authors_in="${SHIPLOG_SETUP_AUTHORS:-}" # space-separated emails
  local strict_envs_in="${SHIPLOG_SETUP_STRICT_ENVS:-}" # space-separated env names
  local do_auto_push=0
  local auto_push_flag=0 # set when --auto-push/--no-auto-push was given explicitly
  local dry_run=0
  local remote
  remote=$(shiplog_remote_name)
  local remote_missing_policy=0
  local remote_missing_trust=0
  local remote_probe_error=""
  local remote_hint_message=""
  local remote_probe_timeout="${SHIPLOG_REMOTE_PROBE_TIMEOUT:-10}"
  # Trust passthrough args
  local -a trust_args; trust_args=()

  if shiplog_is_dry_run; then
    dry_run=1
    if [ -z "${SHIPLOG_SETUP_DRY_RUN:-}" ]; then
      SHIPLOG_SETUP_DRY_RUN=1
      export SHIPLOG_SETUP_DRY_RUN
    fi
  fi

  # Parse options (no prompts)
  while [ $# -gt 0 ]; do
    case "$1" in
      --strictness)
        shift; strictness="${1:-}"; [ -n "$strictness" ] || die "shiplog: --strictness requires a value"; shift ;;
      --strictness=*)
        strictness="${1#*=}"; shift ;;
      --authors)
        shift; authors_in="${1:-}"; [ -n "$authors_in" ] || die "shiplog: --authors requires a value"; shift ;;
      --authors=*)
        authors_in="${1#*=}"; shift ;;
      --strict-envs)
        shift; strict_envs_in="${1:-}"; [ -n "$strict_envs_in" ] || die "shiplog: --strict-envs requires a value"; shift ;;
      --strict-envs=*)
        strict_envs_in="${1#*=}"; shift ;;
      --auto-push)
        do_auto_push=1; auto_push_flag=1; shift ;;
      --no-auto-push)
        do_auto_push=0; auto_push_flag=1; shift ;;
      --dry-run)
        dry_run=1; export SHIPLOG_SETUP_DRY_RUN=1; shift ;;
      # Trust bootstrap pass-through options (non-interactive)
      --trust-id)
        shift; [ -n "${1:-}" ] || die "shiplog: --trust-id requires a value"; trust_args+=("--trust-id" "$1"); shift ;;
      --trust-id=*)
        trust_args+=("--trust-id=${1#*=}"); shift ;;
      --trust-threshold)
        shift; [ -n "${1:-}" ] || die "shiplog: --trust-threshold requires a value"; trust_args+=("--trust-threshold" "$1"); shift ;;
      --trust-threshold=*)
        trust_args+=("--trust-threshold=${1#*=}"); shift ;;
      --trust-maintainer)
        shift; [ -n "${1:-}" ] || die "shiplog: --trust-maintainer requires a value"; trust_args+=("--trust-maintainer" "$1"); shift ;;
      --trust-maintainer=*)
        trust_args+=("--trust-maintainer=${1#*=}"); shift ;;
      --trust-sig-mode)
        shift; [ -n "${1:-}" ] || die "shiplog: --trust-sig-mode requires a value"; trust_args+=("--trust-sig-mode" "$1"); shift ;;
      --trust-sig-mode=*)
        trust_args+=("--trust-sig-mode=${1#*=}"); shift ;;
      --trust-message)
        shift; [ -n "${1:-}" ] || die "shiplog: --trust-message requires a value"; trust_args+=("--trust-message" "$1"); shift ;;
      --trust-message=*)
        trust_args+=("--trust-message=${1#*=}"); shift ;;
      --help|-h)
        printf 'Usage: git shiplog setup [--strictness open|balanced|strict] [--authors "a@b c@d"] [--strict-envs "prod staging"] [--auto-push] [--dry-run]\n'
        printf '  --authors applies to every strictness level. balanced and strict default the allowlist to git config user.email when --authors is absent; open writes no allowlist unless --authors is given.\n'
        return 0 ;;
      --)
        shift; break ;;
      *)
        # Unknown option; show usage and fail
        die "shiplog: unknown setup option: $1" ;;
    esac
  done

  # Env overrides (shared boolean parser; unknown spellings are errors).
  # An explicit --auto-push/--no-auto-push flag wins over the env (#139 D).
  local env_bool
  shiplog_bool_var env_bool SHIPLOG_SETUP_AUTO_PUSH "${SHIPLOG_SETUP_AUTO_PUSH:-}" 0
  if [ "$auto_push_flag" -eq 0 ] && [ "$env_bool" = 1 ]; then
    do_auto_push=1
  fi
  shiplog_bool_var env_bool SHIPLOG_SETUP_DRY_RUN "${SHIPLOG_SETUP_DRY_RUN:-}" 0
  [ "$env_bool" = 1 ] && dry_run=1

  # Normalize strictness
  case "$(printf '%s' "$strictness" | tr '[:upper:]' '[:lower:]')" in
    open|balanced|strict) strictness="$(printf '%s' "$strictness" | tr '[:upper:]' '[:lower:]')" ;;
    *) die "shiplog: --strictness must be one of: open|balanced|strict" ;;
  esac

  # Build policy JSON (always at the repository root, never relative to $PWD)
  local repo_root policy_path
  repo_root=$(shiplog_repo_root) || die "shiplog: unable to determine the repository root"
  policy_path="$repo_root/.shiplog/policy.json"
  mkdir -p "$repo_root/.shiplog"
  local tmp; tmp=$(mktemp)
  local require_signed_global="false"
  local authors_json='[]'
  local strict_envs_json='[]'

  # Author allowlist per strictness level (SLT.BUG.LIB.014):
  #   open      -> only when --authors is given
  #   balanced  -> --authors plus the current git user.email (as documented)
  #   strict    -> --authors, else the current git user.email
  local user_email
  user_email=$(git config user.email 2>/dev/null || true)
  local authors_list="$authors_in"
  case "$strictness" in
    balanced)
      if [ -n "$user_email" ]; then
        case " $(printf '%s' "$authors_list" | tr ',;' '  ') " in
          *" $user_email "*) ;;
          *) authors_list="${authors_list:+$authors_list }$user_email" ;;
        esac
      fi
      ;;
    strict)
      if [ -z "$authors_list" ] && [ -n "$user_email" ]; then
        authors_list="$user_email"
      fi
      ;;
  esac

  # Convert space-separated lists to JSON arrays
  if [ -n "$authors_list" ]; then
    # squeeze spaces and split
    authors_json=$(printf '%s\n' "$authors_list" | tr ',;' '  ' | tr -s ' ' | awk '{for(i=1;i<=NF;i++) print $i}' | jq -R . | jq -s .)
  fi
  if [ -n "$strict_envs_in" ]; then
    strict_envs_json=$(printf '%s\n' "$strict_envs_in" | tr ',;' '  ' | tr -s ' ' | awk '{for(i=1;i<=NF;i++) print $i}' | jq -R . | jq -s .)
  fi

  # Determine policy shape
  case "$strictness" in
    open)
      require_signed_global="false"
      ;;
    balanced)
      require_signed_global="false"
      ;;
    strict)
      if [ -n "$strict_envs_in" ]; then
        require_signed_global="false"
      else
        require_signed_global="true"
      fi
      ;;
  esac

  # Start base policy
  printf '{"version":"1.0.0","require_signed":%s}\n' "$require_signed_global" >"$tmp"

  # Add the author allowlist whenever one was resolved (any strictness level)
  if [ -n "$authors_list" ]; then
    jq --argjson list "$authors_json" '.authors = {default_allowlist: $list, env_overrides: {default: []}}' "$tmp" >"${tmp}.2" && mv "${tmp}.2" "$tmp"
  fi

  # Add per-env deployment requirements for strict with envs
  if [ "$strictness" = "strict" ] && [ -n "$strict_envs_in" ]; then
    jq --argjson envs "$strict_envs_json" '
      .deployment_requirements |= (
        . // {} |
        reduce ($envs[]) as $e (. ; .[$e] = {require_signed:true})
      )
    ' "$tmp" >"${tmp}.2" && mv "${tmp}.2" "$tmp"
  fi

  if [ "$dry_run" -eq 1 ]; then
    # Preview only; do not write or sync
    if shiplog_can_use_bosun; then
      local bosun; bosun=$(shiplog_bosun_bin)
      "$bosun" style --title "Setup (dry-run)" -- "Previewing .shiplog/policy.json (no changes written)"
      "$bosun" style --title "Proposed Policy" -- "$(cat "$tmp")"
    else
      printf 'Setup (dry-run): would write .shiplog/policy.json with contents below:\n'
      cat "$tmp"
      printf '\n'
    fi
    rm -f "$tmp"
  else
    # Install policy file with backup/diff semantics
    policy_install_file "$tmp" "$policy_path"

    # Sync policy ref locally (no push here); the helper validates first and its
    # diagnostics are surfaced. Signing follows SHIPLOG_POLICY_SIGN, defaulting to
    # signed when user.signingkey is configured.
    shiplog_policy_sync_ref "$policy_path"

  # Bootstrap trust only when explicitly requested via trust_args OR strict globally with envs provided
  if [ -x "$SHIPLOG_HOME/scripts/shiplog-bootstrap-trust.sh" ]; then
    if [ ${#trust_args[@]} -gt 0 ]; then
      "$SHIPLOG_HOME/scripts/shiplog-bootstrap-trust.sh" --no-push "${trust_args[@]}" >/dev/null || die "shiplog: trust bootstrap failed"
    elif [ "$strictness" = "strict" ] && [ -z "$strict_envs_in" ]; then
      "$SHIPLOG_HOME/scripts/shiplog-bootstrap-trust.sh" --no-push >/dev/null || die "shiplog: trust bootstrap failed (provide SHIPLOG_TRUST_* env for non-interactive)"
    fi
  fi

    if [ "$do_auto_push" -eq 0 ] && has_remote_origin; then
      local probe_output=""
      local probe_status=0
      local -a probe_cmd=(git ls-remote "$remote" "$POLICY_REF" "$TRUST_REF")
      if command -v timeout >/dev/null 2>&1; then
        probe_cmd=(timeout "$remote_probe_timeout" "${probe_cmd[@]}")
      fi
      set +e
      probe_output=$("${probe_cmd[@]}" 2>&1)
      probe_status=$?
      set -e
      if [ "$probe_status" -eq 0 ]; then
        if ! printf '%s\n' "$probe_output" | awk -F'\t' 'NF>1 {print $2}' | grep -Fx "$POLICY_REF" >/dev/null 2>&1; then
          remote_missing_policy=1
        fi
        if ! printf '%s\n' "$probe_output" | awk -F'\t' 'NF>1 {print $2}' | grep -Fx "$TRUST_REF" >/dev/null 2>&1; then
          remote_missing_trust=1
        fi
      else
        if [ "$probe_status" -eq 124 ]; then
          remote_probe_error="timeout after ${remote_probe_timeout}"
        else
          local sanitized
          sanitized="$(sanitize_remote_error "$probe_output")"
          remote_probe_error="$sanitized"
          if [ -z "$remote_probe_error" ]; then
            remote_probe_error="command failed with exit code $probe_status"
          else
            if [ "${SANITIZE_REMOTE_EXTRA_LINES:-0}" -gt 0 ]; then
              local probe_cmd_display
              probe_cmd_display=$(printf '%q ' "${probe_cmd[@]}")
              probe_cmd_display=${probe_cmd_display% }
              remote_probe_error+=" (trimmed; run '${probe_cmd_display}' for full output)"
            fi
          fi
          unset SANITIZE_REMOTE_EXTRA_LINES SANITIZE_REMOTE_TOTAL_LINES
        fi
      fi
      if [ -z "$remote_probe_error" ] && { [ "$remote_missing_policy" -eq 1 ] || [ "$remote_missing_trust" -eq 1 ]; }; then
        if [ "$remote_missing_policy" -eq 1 ] && [ "$remote_missing_trust" -eq 1 ]; then
          remote_hint_message="Remote $remote does not yet have $POLICY_REF or $TRUST_REF. "
          remote_hint_message+="If your server runs the Shiplog pre-receive hook, temporarily set "
          remote_hint_message+="SHIPLOG_ALLOW_MISSING_POLICY=1 and SHIPLOG_ALLOW_MISSING_TRUST=1 "
          remote_hint_message+="while you bootstrap, then remove them after pushing."
        elif [ "$remote_missing_policy" -eq 1 ]; then
          remote_hint_message="Remote $remote does not yet have $POLICY_REF. "
          remote_hint_message+="If your server runs the Shiplog pre-receive hook, temporarily set "
          remote_hint_message+="SHIPLOG_ALLOW_MISSING_POLICY=1 while you bootstrap, then remove it after pushing."
        else
          remote_hint_message="Remote $remote does not yet have $TRUST_REF. "
          remote_hint_message+="If your server runs the Shiplog pre-receive hook, temporarily set "
          remote_hint_message+="SHIPLOG_ALLOW_MISSING_TRUST=1 while you bootstrap, then remove it after pushing."
        fi
      elif [ -n "$remote_probe_error" ] && [ -z "$remote_hint_message" ]; then
        remote_hint_message="Warning: unable to query remote $remote for bootstrap hints ($remote_probe_error)"
      fi
    fi

    # Handle optional auto-push to configured remote
    if [ "$do_auto_push" -eq 1 ] && has_remote_origin; then
      # Push policy ref if it exists
      if git rev-parse --verify "$POLICY_REF" >/dev/null 2>&1; then
        git push --no-verify "$remote" "$POLICY_REF" >/dev/null
      fi
      # Push trust ref if it exists
      if git rev-parse --verify "$TRUST_REF" >/dev/null 2>&1; then
        git push --no-verify "$remote" "$TRUST_REF" >/dev/null
      fi
    fi
  fi

  if shiplog_can_use_bosun; then
    local bosun; bosun=$(shiplog_bosun_bin)
    if [ "$dry_run" -eq 0 ]; then
      "$bosun" style --title "Setup" -- "Wrote .shiplog/policy.json (strictness: $strictness)"
      "$bosun" style --title "Setup" -- "Updated $POLICY_REF locally (run git push --no-verify $remote $POLICY_REF to publish)"
    else
      "$bosun" style --title "Setup" -- "Dry-run: no files or refs changed"
    fi
    if [ "$do_auto_push" -eq 1 ]; then
      "$bosun" style --title "Setup" -- "Auto-pushed configured refs to $remote"
    fi
    if [ -n "$remote_hint_message" ]; then
      "$bosun" style --title "Server Hint" -- "$remote_hint_message"
    fi
    # Always print next-step commands (advice only)
    "$bosun" style --title "Next Steps" -- $'Configure local signing (optional):\n  git config --local user.name "Your Name"\n  git config --local user.email "you@example.com"\n  git config --local gpg.format ssh\n  git config --local user.signingkey ~/.ssh/your_signing_key.pub\n  git config --local commit.gpgSign true'
    if [ "$do_auto_push" -eq 0 ]; then
      local publish_msg
      printf -v publish_msg 'Publish refs when ready:\n  git push --no-verify %s %s\n  [if created] git push --no-verify %s %s' "$remote" "$POLICY_REF" "$remote" "$TRUST_REF"
      "$bosun" style --title "Next Steps" -- "$publish_msg"
    fi
    "$bosun" style --title "Next Steps" -- $'Inspect effective policy:\n  git shiplog policy show --json'
  else
    if [ "$dry_run" -eq 0 ]; then
      printf 'Wrote .shiplog/policy.json (strictness: %s)\n' "$strictness"
      printf 'Updated %s locally. Run: git push --no-verify %s %s\n' "$POLICY_REF" "$remote" "$POLICY_REF"
      [ "$do_auto_push" -eq 1 ] && printf 'Auto-pushed configured refs to %s.\n' "$remote"
    else
      printf 'Dry-run: no files or refs changed.\n'
    fi
    printf '%s\n' "Next steps (copy/paste as needed):"
    printf '  %s\n' "git config --local user.name \"Your Name\""
    printf '  %s\n' "git config --local user.email \"you@example.com\""
    printf '  %s\n' "git config --local gpg.format ssh"
    printf '  %s\n' "git config --local user.signingkey ~/.ssh/your_signing_key.pub"
    printf '  %s\n' "git config --local commit.gpgSign true"
    if [ "$do_auto_push" -eq 0 ]; then
    printf '  %s\n' "git push --no-verify $remote $POLICY_REF"
    printf '  %s\n' "[if created] git push --no-verify $remote $TRUST_REF"
    fi
    printf '  %s\n' "git shiplog policy show --json"
    if [ -n "$remote_hint_message" ]; then
      printf '%s\n' "$remote_hint_message"
    fi
  fi
}

# Interactive configuration wizard (questionnaire)
cmd_config() {
  ensure_in_repo

  local interactive=0 apply=0 answers_file="" dry_run=0 dry_run_explicit=0 env_dry_run=0
  local emit_gh_ruleset=0 emit_gh_workflow=0
  if shiplog_is_dry_run; then dry_run=1; env_dry_run=1; fi
  # Track if caller explicitly passed a global --dry-run flag
  case "${SHIPLOG_DRY_RUN_EXPLICIT:-0}" in 1|true|yes|on) dry_run_explicit=1 ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --interactive|--wizard) interactive=1; shift; continue ;;
      --answers-file) shiplog_require_flag_value "$1" $#; shift; answers_file="$1"; shift; continue ;;
      --answers-file=*) answers_file="${1#*=}"; shift; continue ;;
      --emit-github-ruleset) emit_gh_ruleset=1; shift; continue ;;
      --emit-github-workflow) emit_gh_workflow=1; shift; continue ;;
      --apply)
        apply=1
        # Unless user explicitly asked for --dry-run or environment forced it, ensure apply clears dry-run
        if [ "$dry_run_explicit" -eq 0 ] && [ "$env_dry_run" -eq 0 ]; then
          dry_run=0
        fi
        shift; continue ;;
      --dry-run)
        dry_run=1
        dry_run_explicit=1
        shift; continue ;;
      --help|-h)
        printf 'Usage: git shiplog config --interactive|--wizard [--apply] [--answers-file file] [--dry-run]\n'
        return 0 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  # Invalid combo: only when the user explicitly requested both
  if [ "$apply" -eq 1 ] && [ "$dry_run_explicit" -eq 1 ]; then
    die "shiplog: --apply and --dry-run are mutually exclusive"
  fi

  if [ "$interactive" -ne 1 ] && [ -n "$answers_file" ]; then :; elif [ "$interactive" -ne 1 ] && [ $emit_gh_ruleset -eq 0 ] && [ $emit_gh_workflow -eq 0 ]; then
    die "shiplog: config requires --interactive (or --wizard) or --answers-file"
  fi

  # Detect host from origin URL
  local origin host_kind
  origin=$(git config --get remote.origin.url 2>/dev/null || true)
  host_kind="self-hosted"
  case "$origin" in
    *github.com*) host_kind="github.com" ;;
    *gitlab.com*) host_kind="gitlab.com" ;;
    *bitbucket.org*) host_kind="bitbucket.org" ;;
  esac

  # Answers with defaults
  local q_host q_ref_root q_threshold q_sig_mode q_per_env_signed q_autopush
  q_host="$host_kind"
  q_ref_root=""; q_threshold=1; q_sig_mode="chain"; q_per_env_signed="prod-only"; q_autopush="disable"

  if [ -n "$answers_file" ]; then
    if command -v jq >/dev/null 2>&1; then
      [ -r "$answers_file" ] || die "shiplog: answers file not readable: $answers_file"
      if ! jq -e . "$answers_file" >/dev/null 2>&1; then
        die "shiplog: answers file must contain valid JSON"
      fi
      q_host=$(jq -r '.host // empty' "$answers_file")
      q_ref_root=$(jq -r '.ref_root // empty' "$answers_file")
      q_threshold=$(jq -r '.threshold // empty' "$answers_file")
      q_sig_mode=$(jq -r '.sig_mode // empty' "$answers_file")
      q_per_env_signed=$(jq -r '.require_signed // empty' "$answers_file")
      q_autopush=$(jq -r '.autoPush // empty' "$answers_file")
    else
      die "shiplog: jq required for --answers-file parsing"
    fi
  fi

  if [ "$interactive" -eq 1 ]; then
    q_host=$(shiplog_prompt_choice "Git host" "SHIPLOG_CONFIG_HOST" github.com gitlab.com bitbucket.org self-hosted)
    local default_root="refs/_shiplog"
    case "$q_host" in github.com|gitlab.com|bitbucket.org) default_root="refs/heads/_shiplog";; esac
    local root_ans; root_ans="$(shiplog_prompt_choice "Ref namespace" "SHIPLOG_CONFIG_REFROOT" "$default_root" refs/heads/_shiplog refs/_shiplog)"
    q_ref_root="$root_ans"
    local team_hint; team_hint=$(shiplog_prompt_choice "Team size" "SHIPLOG_CONFIG_TEAM" solo solo 2-5 6-plus)
    case "$team_hint" in solo) q_threshold=1 ;; 2-5) q_threshold=2 ;; 6-plus) q_threshold=3 ;; esac
    # D1: attestation is the only N-of-M mode; chain supports threshold 1 only.
    if [ "$q_threshold" -gt 1 ]; then q_sig_mode="attestation"; else q_sig_mode="chain"; fi
    q_sig_mode=$(shiplog_prompt_choice "Signing mode" "SHIPLOG_CONFIG_SIGMODE" "$q_sig_mode" chain attestation)
    q_per_env_signed=$(shiplog_prompt_choice "Require signatures" "SHIPLOG_CONFIG_REQSIG" prod-only prod-only global none)
    q_autopush=$(shiplog_prompt_choice "Auto-push during deploys" "SHIPLOG_CONFIG_AUTOPUSH" disable disable enable)
  fi

  # Normalize/coerce answers and compute plan inputs
  # host
  q_host="$(printf '%s' "${q_host:-$host_kind}" | tr '[:upper:]' '[:lower:]')"
  case "$q_host" in github.com|gitlab.com|bitbucket.org) : ;; self-hosted|'') q_host="self-hosted" ;; *) q_host="self-hosted" ;; esac
  # threshold (integer, >=1)
  if ! printf '%s' "${q_threshold:-}" | grep -Eq '^[0-9]+$'; then q_threshold=1; fi
  if [ "${q_threshold}" -lt 1 ]; then q_threshold=1; fi
  # sig_mode
  q_sig_mode="${q_sig_mode:-}"
  if [ -z "$q_sig_mode" ]; then
    if [ "$q_threshold" -gt 1 ]; then q_sig_mode="attestation"; else q_sig_mode="chain"; fi
  fi
  q_sig_mode="$(printf '%s' "$q_sig_mode" | tr '[:upper:]' '[:lower:]')"
  case "$q_sig_mode" in chain|attestation) : ;; *) q_sig_mode="chain" ;; esac
  if [ "$q_sig_mode" = "chain" ] && [ "$q_threshold" -gt 1 ]; then
    die "shiplog: sig_mode chain supports threshold 1 only (a commit carries one signature); use sig_mode attestation for threshold $q_threshold (docs/TRUST.md)"
  fi
  # require_signed scope
  q_per_env_signed="$(printf '%s' "${q_per_env_signed:-prod-only}" | tr '[:upper:]' '[:lower:]')"
  local require_signed_global=0 require_signed_prod=0
  case "$q_per_env_signed" in global|all|true|yes) require_signed_global=1 ;; prod-only) require_signed_prod=1 ;; none|false|no|off|'') ;; *) require_signed_prod=1 ;; esac
  # autopush
  q_autopush="$(printf '%s' "${q_autopush:-disable}" | tr '[:upper:]' '[:lower:]')"
  local autopush_cfg=1
  case "$q_autopush" in disable|0|no|off|false) autopush_cfg=0 ;; *) autopush_cfg=1 ;; esac
  # ref root
  local ref_root="$q_ref_root"
  if [ -z "$ref_root" ]; then
    case "$q_host" in github.com|gitlab.com|bitbucket.org) ref_root="refs/heads/_shiplog" ;; *) ref_root="refs/_shiplog" ;; esac
  fi
  # Normalize ref root: enforce refs/* prefix and strip trailing slashes
  ref_root="${ref_root%/}"
  case "$ref_root" in
    refs/*) : ;;
    *)
      # If user provided e.g. "heads/_shiplog" or "_shiplog", prepend "refs/"
      ref_root="refs/${ref_root}"
      ;;
  esac

  # Final plan JSON (use jq when available)
  local plan_json
  if command -v jq >/dev/null 2>&1; then
    local req_scope
    if [ $require_signed_global -eq 1 ]; then req_scope="global"; elif [ $require_signed_prod -eq 1 ]; then req_scope="prod-only"; else req_scope="none"; fi
    plan_json=$(jq -n \
      --arg host "$q_host" \
      --arg ref_root "$ref_root" \
      --arg sig_mode "$q_sig_mode" \
      --arg req "$req_scope" \
      --argjson threshold "$q_threshold" \
      --argjson autoPush "$autopush_cfg" \
      '{host:$host,ref_root:$ref_root,sig_mode:$sig_mode,threshold:$threshold,require_signed:$req,autoPush:$autoPush}')
  else
    plan_json=$(printf '{"host":"%s","ref_root":"%s","sig_mode":"%s","threshold":%s,"require_signed":"%s","autoPush":%s}\n' \
      "$q_host" "$ref_root" "$q_sig_mode" "$q_threshold" \
      "$([ $require_signed_global -eq 1 ] && echo global || { [ $require_signed_prod -eq 1 ] && echo prod-only || echo none; })" \
      "$autopush_cfg")
  fi

  if shiplog_can_use_bosun; then
    local bosun; bosun=$(shiplog_bosun_bin)
    "$bosun" style --title "Shiplog Config Plan" -- "$plan_json"
  else
    printf '%s\n' "$plan_json"
  fi

  # Optional emitters for GitHub (docs/examples only; does not change repo state)
  if [ $emit_gh_ruleset -eq 1 ]; then
    local ruleset1="$SHIPLOG_HOME/docs/examples/github/ruleset-branch-shiplog-protect.json"
    local ruleset2="$SHIPLOG_HOME/docs/examples/github/ruleset-branch-shiplog-restricted.json"
    if [ -f "$ruleset1" ]; then
      if shiplog_can_use_bosun; then
        local bosun; bosun=$(shiplog_bosun_bin)
        "$bosun" style --title "GitHub Ruleset (protect)" -- "$(cat "$ruleset1")"
      else
        printf '\n# GitHub Ruleset (protect)\n'
        cat "$ruleset1"
        printf '\n'
      fi
    fi
    if [ -f "$ruleset2" ]; then
      if shiplog_can_use_bosun; then
        local bosun; bosun=$(shiplog_bosun_bin)
        "$bosun" style --title "GitHub Ruleset (restricted)" -- "$(cat "$ruleset2")"
      else
        printf '\n# GitHub Ruleset (restricted)\n'
        cat "$ruleset2"
        printf '\n'
      fi
    fi
  fi

  if [ $emit_gh_workflow -eq 1 ]; then
    local wf="$SHIPLOG_HOME/docs/examples/github/workflow-shiplog-verify.yml"
    if [ -f "$wf" ]; then
      if shiplog_can_use_bosun; then
        local bosun; bosun=$(shiplog_bosun_bin)
        # Literal tab via printf: BSD sed reads `\t` as the letter t and would strip
        # every "t" from the YAML (#139 E).
        "$bosun" style --title "GitHub Workflow (verify)" -- "$(sed "s/$(printf '\t')/  /g" "$wf")"
      else
        printf '\n# GitHub Workflow (verify)\n'
        cat "$wf"
        printf '\n'
      fi
    fi
  fi

  # Apply actions (local-only) when requested and not in dry-run
  if [ "$apply" -eq 1 ] && [ "$dry_run" -eq 0 ]; then
    git config shiplog.refRoot "$ref_root"
    if [ "$autopush_cfg" -eq 1 ]; then
      git config shiplog.autoPush true
    else
      git config shiplog.autoPush false
    fi
    local cfg_root
    cfg_root=$(shiplog_repo_root) || die "shiplog: unable to determine the repository root"
    mkdir -p "$cfg_root/.shiplog"
    local tmp; tmp=$(mktemp)
    if [ $require_signed_global -eq 1 ]; then
      printf '{"version":"1.0.0","require_signed":true}\n' >"$tmp"
    elif [ $require_signed_prod -eq 1 ]; then
      printf '{"version":"1.0.0","require_signed":false,"deployment_requirements":{"prod":{"require_signed":true}}}\n' >"$tmp"
    else
      printf '{"version":"1.0.0","require_signed":false}\n' >"$tmp"
    fi
    policy_install_file "$tmp" "$cfg_root/.shiplog/policy.json"
    if shiplog_can_use_bosun; then
      local bosun2; bosun2=$(shiplog_bosun_bin)
      "$bosun2" style --title "Next Steps" -- "Bootstrap trust (threshold=$q_threshold, sig_mode=$q_sig_mode) and add CI checks/rulesets per host. See docs/hosting/matrix.md and docs/TRUST.md."
    else
      printf 'Next steps: bootstrap trust (threshold=%s, sig_mode=%s). See docs/hosting/matrix.md and docs/TRUST.md\n' "$q_threshold" "$q_sig_mode"
    fi
  fi
}

usage() {
  local cmd="$(basename "$0")"
  if [ "$cmd" = "git-shiplog" ]; then
    cmd="git shiplog"
  fi
  cat <<EOF
SHIPLOG-Lite
A structured deployment logging tool for Git repositories.

Usage:
  $cmd [GLOBAL_OPTIONS] <command> [COMMAND_OPTIONS]
  $cmd <command> --help      Show the options of one command

  Commands:
  version             Print Shiplog version
  init                 Initialize shiplog configuration in current repo
  write [ENV]          Create a new deployment log entry
  append [OPTS]        Append using non-interactive JSON payload
  run [OPTS] -- CMD    Execute a command, capture output, and log the run
  ls [ENV] [LIMIT]     List recent deployment entries (default: last 20)
  show [COMMIT]        Show detailed deployment entry
  validate-trailer [COMMIT]
                       Validate the JSON trailer for the given entry (defaults to latest)
  verify [ENV]         Verify signatures and authorization of entries
  export-json [ENV]    Export entries as JSON lines
  publish [ENV]        Push/publish journal (and notes) for ENV (default: current env)
  trust sync [REF]     Refresh signer roster from the trust ref (default: $TRUST_REF_DEFAULT)
  trust show [REF]     Display trust roster and metadata (use --json for raw output)
  policy [show] [--env ENV] [--json]
                       Show the effective policy for ENV and the source of every field
  policy validate [--ref] [--file PATH]
                       Validate .shiplog/policy.json (working tree first; --ref for the published ref)
  policy require-signed <true|false>
                       Set signing requirement in .shiplog/policy.json and sync policy ref
  policy toggle        Toggle signing requirement (unsigned ↔ signed) and sync policy ref
  refs root show       Show the effective Shiplog ref root, its source (env/config/default) and derived refs (--json)
  refs root set REF    Set Shiplog ref root (e.g., refs/_shiplog or refs/heads/_shiplog)
  refs migrate [OPTS]  Mirror refs between roots (wrapper). Options: --to <refs/...> [--from <refs/...>] [--push] [--remove-old] [--dry-run]
  config               Interactive configuration wizard (questionnaire)
                       Options:
                         --interactive | --wizard    Start TTY questionnaire
                         --answers-file <path>       Non-interactive answers (JSON)
                         --apply                     Apply recommendations (policy/config)
                         --dry-run                   Print plan only (default)
  setup                Non-interactive setup wrapper to write .shiplog/policy.json and sync policy ref
                       Options:
                         --strictness open|balanced|strict
                         --authors "a@b c@d" (any strictness; balanced/strict default to user.email)
                         --strict-envs "prod staging" (strict per-env)
                        --auto-push (push policy/trust refs to the configured remote)

Global Options:
  --env ENV            Target environment (default: $DEFAULT_ENV)
  --boring             Non-interactive mode (requires SHIPLOG_* env vars)
  --yes                Auto-confirm all prompts
  --no-push            Skip automatic git push of shiplog refs
  --dry-run            Preview actions without appending to logs or updating notes

Environment Variables:
  SHIPLOG_SERVICE      Service name (required in --boring mode)
  SHIPLOG_STATUS       Deployment status (success|failed|in_progress|...)
  SHIPLOG_REASON       Deployment reason/description
  SHIPLOG_TICKET       Associated ticket or PR number
  SHIPLOG_REGION       Target region
  SHIPLOG_CLUSTER      Target cluster
  SHIPLOG_NAMESPACE    Target namespace
  SHIPLOG_IMAGE        Container image name
  SHIPLOG_TAG          Container image tag
  SHIPLOG_RUN_URL      CI/CD pipeline URL
  SHIPLOG_LOG          Path to log file to attach as notes
  SHIPLOG_AUTO_PUSH    Auto-push to the configured remote (default: 1; precedence: flags > git config shiplog.autoPush > env)
  SHIPLOG_REMOTE       Remote name used for Shiplog fetch/publish/push (default: origin or git config shiplog.remote)
  SHIPLOG_ASSUME_YES   Auto-confirm prompts (default: 0)
  SHIPLOG_BORING       Enable non-interactive mode (default: 0)
  SHIPLOG_DRY_RUN      Enable dry-run mode (1/true/yes/on; 0/false/no/off disables)
  Booleans accept 1|true|yes|on and 0|false|no|off (case-insensitive); any other value is an error.
EOF
}
run_command() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    version)       cmd_version "$@";;
    init)          cmd_init "$@";;
    write)         cmd_write "$@";;
    append)        cmd_append "$@";;
    run)           cmd_run "$@";;
    ls)            cmd_ls "$@";;
    show)          cmd_show "$@";;
    validate-trailer) cmd_validate_trailer "$@";;
    verify)        cmd_verify "$@";;
    export-json)   cmd_export_json "$@";;
    publish)       cmd_publish "$@";;
    trust)         cmd_trust "$@";;
    policy)        cmd_policy "$@";;
    refs)          cmd_refs "$@";;
    config)        cmd_config "$@";;
    setup)         cmd_setup "$@";;
    *)             usage; exit 1;;
  esac
}

cmd_validate_trailer() {
  ensure_in_repo
  need jq
  local target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h)
        printf 'Usage: git shiplog validate-trailer [COMMIT|REF]\n\nValidate the JSON trailer of one entry (defaults to the latest entry of the current environment).\n'
        return 0 ;;
      --)
        shift
        if [ $# -gt 0 ]; then
          [ -z "$target" ] || die "shiplog: validate-trailer accepts a single COMMIT|REF (got '$target' and '$1')"
          target="$1"; shift
        fi
        [ $# -eq 0 ] || die "shiplog: unexpected argument to validate-trailer: $1"
        break ;;
      -*) die "shiplog: unknown validate-trailer option: $1 (see git shiplog validate-trailer --help)" ;;
      *)
        [ -z "$target" ] || die "shiplog: validate-trailer accepts a single COMMIT|REF (got '$target' and '$1')"
        target="$1"; shift ;;
    esac
  done
  # A target after `--` may start with '-'; git would parse it as an option.
  case "$target" in
    -*) die "shiplog: invalid target '$target' (must not start with '-')" ;;
  esac
  if [ -z "$target" ]; then
    target="$(ref_journal "$DEFAULT_ENV")"
  fi
  # Extract commit body and JSON trailer
  local body json
  body="$(git show -s --format=%B "$target" 2>/dev/null || true)"
  if [ -z "$body" ]; then
    die "Cannot read commit body for $target"
  fi
  json="$(shiplog_extract_trailer <<< "$body")"
  if [ -z "$json" ]; then
    die "No JSON trailer found in entry $target"
  fi
  # Validate parseable JSON first
  if ! printf '%s\n' "$json" | jq . >/dev/null 2>&1; then
    printf '❌ Invalid JSON trailer (parse error) in %s\n' "$target" >&2
    return 1
  fi
  # Structural validation: required fields and basic types
  local err jq_output jq_status=0
  jq_output=$(printf '%s\n' "$json" | jq -r '
    def _validate($msg; $value; $expected; $minlen):
      (try $value catch null) as $v
      | if $expected == "string" then
          if ($v | type) == "string" and ($v | length) >= $minlen then empty else $msg end
        elif $expected == "number" then
          if ($v | type) == "number" then empty else $msg end
        else
          empty
        end;
    def req_str($key):
      _validate("missing_or_invalid:" + $key; .[$key]?; "string"; 1);
    def req_enum_str($key; $allowed):
      (try .[$key] catch null) as $v
      | if (($v | type) == "string")
        and ($v | length) >= 1
        and (($allowed | index($v)) != null)
        then empty else "missing_or_invalid:" + $key end;
    def req_nested_str($msg; $path):
      _validate($msg; (try getpath($path) catch null); "string"; 1);
    def req_nested_int_ge($msg; $path; $min):
      (try getpath($path) catch null) as $v
      | if (($v | type) == "number")
        and ((($v | floor) == $v))
        and ($v >= $min)
        then empty else $msg end;
    [
      req_str("env"),
      req_str("ts"),
      req_enum_str("status"; ["success","failed","in_progress","skipped","override","revert","finalize"]),
      req_nested_str("missing_or_invalid:what.service"; ["what", "service"]),
      req_nested_int_ge("missing_or_invalid:when.dur_s"; ["when", "dur_s"]; 0)
    ]
    | map(select(length > 0))
    | .[]' 2>&1) || jq_status=$?
  if [ "$jq_status" -ne 0 ]; then
    [ -n "$jq_output" ] && printf '%s\n' "$jq_output" >&2
    die "shiplog: trailer validation failed (jq status $jq_status)"
  fi
  err="$jq_output"
  if [ -n "$err" ]; then
    if shiplog_can_use_bosun; then
      local bosun; bosun=$(shiplog_bosun_bin)
      "$bosun" style --title "Trailer Validation" -- "❌ Invalid trailer for $target"
      printf '%s\n' "$err" | "$bosun" style --title "Errors" --
    else
      printf '❌ Invalid trailer for %s\n' "$target" >&2
      printf '%s\n' "$err" >&2
    fi
    return 1
  fi
  if shiplog_can_use_bosun; then
    local bosun; bosun=$(shiplog_bosun_bin)
    "$bosun" style --title "Trailer Validation" -- "✅ Trailer OK for $target"
  else
    printf '✅ Trailer OK for %s\n' "$target"
  fi
}
