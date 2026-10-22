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
  local_oid=$(git rev-parse "$ref" 2>/dev/null || true)
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

cmd_version() {
  printf 'shiplog %s\n' "$(shiplog_version)"
}

cmd_init() {
  ensure_in_repo
  local remote
  remote=$(shiplog_remote_name)
  local fetch_value="+$REF_ROOT/*:$REF_ROOT/*"
  if ! git config --get-all remote."$remote".fetch 2>/dev/null | grep -Fxq "$fetch_value"; then
    git config --add remote."$remote".fetch "$fetch_value"
  fi

  local existing_push
  existing_push=$(git config --get-all remote."$remote".push 2>/dev/null || true)
  if ! printf '%s\n' "$existing_push" | grep -Fxq "$REF_ROOT/*:$REF_ROOT/*"; then
    git config --add remote."$remote".push "$REF_ROOT/*:$REF_ROOT/*"
  fi
  if [ -z "$existing_push" ] && ! git config --get-all remote."$remote".push 2>/dev/null | grep -Fxq "HEAD"; then
    git config --add remote."$remote".push HEAD
  fi

  if [ "$(git config --get core.logAllRefUpdates 2>/dev/null)" != "true" ]; then
    git config core.logAllRefUpdates true
  fi
  if shiplog_can_use_bosun; then
    local bosun
    bosun=$(shiplog_bosun_bin)
    "$bosun" style --title "Init" -- "Configured refspecs for $REF_ROOT/* and enabled reflogs."
  else
    printf 'Configured refspecs for %s/* and enabled reflogs.\n' "$REF_ROOT"
  fi
}

cmd_write() {
  ensure_in_repo
  local env="$DEFAULT_ENV"
  local args=()
  local opt

  # Parse positional ENV and optional flags to prefill prompts
  local json_from_stdin=0
  local dry_run=0
  if shiplog_is_dry_run; then
    dry_run=1
  fi

  while [ $# -gt 0 ]; do
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
        case "$(printf '%s' "$dry_val" | tr '[:upper:]' '[:lower:]')" in
          0|false|no|off|'')
            dry_run=0
            SHIPLOG_DRY_RUN=0
            ;;
          *)
            dry_run=1
            SHIPLOG_DRY_RUN="$dry_val"
            ;;
        esac
        export SHIPLOG_DRY_RUN
        shift
        continue
        ;;
      --) shift; break ;;
      -*) args+=("$1"); shift; continue ;;
      *)
        # First non-flag positional argument is ENV if not set by --env
        if [ "$env" = "$DEFAULT_ENV" ]; then env="$1"; shift; continue; else args+=("$1"); shift; continue; fi
        ;;
    esac
  done

  require_allowed_author
  require_allowed_signer

  local journal_ref="$(ref_journal "$env")"
  local notes_ref="$NOTES_REF"
  local trust_ref="${TRUST_REF:-$TRUST_REF_DEFAULT}"
  local remote
  remote=$(shiplog_remote_name)
  local remote_available=0
  if has_remote_origin; then
    remote_available=1
    if [ "${dry_run:-0}" -ne 1 ]; then
      maybe_sync_shiplog_ref "$trust_ref"
      maybe_sync_shiplog_ref "$journal_ref"
      if [ -n "$notes_ref" ]; then
        git fetch "$remote" "$notes_ref" >/dev/null 2>&1 || true
      fi
    fi
  fi

  local trust_oid
  trust_oid=$(git rev-parse -q --verify "$trust_ref" 2>/dev/null || true)
  if [ -z "$trust_oid" ]; then
    die "shiplog: trust ref $trust_ref not found. Fetch it (git fetch $remote '+refs/_shiplog/trust/*:refs/_shiplog/trust/*') and run ./scripts/shiplog-trust-sync.sh"
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

  if [ "$remote_available" -eq 1 ] && [ "${SHIPLOG_AUTO_PUSH:-1}" != "0" ]; then
    # Determine effective auto-push: flags > git config > env/default
    local autopush_effective
    if [ "${SHIPLOG_AUTO_PUSH_FLAG:-0}" = "1" ]; then
      autopush_effective="${SHIPLOG_AUTO_PUSH:-1}"
    else
      local cfg
      cfg=$(git config --bool shiplog.autoPush 2>/dev/null || true)
      if [ -n "$cfg" ]; then
        case "$cfg" in true|1|yes|on) autopush_effective=1 ;; *) autopush_effective=0 ;; esac
      else
        autopush_effective="${SHIPLOG_AUTO_PUSH:-1}"
      fi
    fi
    if [ "$autopush_effective" != "0" ]; then
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
    elif [ "$remote_available" -eq 1 ] && [ "$autopush_effective" = "0" ] && ! is_boring; then
      printf 'ℹ️ shiplog: auto-push disabled; remember to publish %s to %s when ready.\n' "$journal_ref" "$remote"
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
        case "$(printf '%s' "$run_dry_val" | tr '[:upper:]' '[:lower:]')" in
          0|false|no|off|'' )
            dry_run=0
            skip_execution=0
            SHIPLOG_DRY_RUN=0
            ;;
          *)
            dry_run=1
            skip_execution=1
            SHIPLOG_DRY_RUN="$run_dry_val"
            ;;
        esac
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
        case "$(printf '%s' "$append_dry_val" | tr '[:upper:]' '[:lower:]')" in
          0|false|no|off|'')
            dry_run=0; SHIPLOG_DRY_RUN=0 ;;
          *)
            dry_run=1; SHIPLOG_DRY_RUN="$append_dry_val" ;;
        esac
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
  local env="${1:-$DEFAULT_ENV}"
  local limit="${2:-20}"
  local ref; ref="$(ref_journal "$env")"
  [ -n "$(current_tip "$ref")" ] || die "No entries at $ref"
  pretty_ls "$ref" "$limit"
}

cmd_show() {
  ensure_in_repo
  local json_only=0 boring_local=0 compact=0
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json_only=1; shift; continue ;;
      --json-compact|--jsonl) json_only=1; compact=1; shift; continue ;;
      --boring|-b) boring_local=1; shift; continue ;;
      --) shift; break ;;
      -*) args+=("$1"); shift; continue ;;
      *) break ;;
    esac
  done
  # If --boring passed after subcommand, honor it
  if [ "$boring_local" -eq 1 ]; then
    SHIPLOG_BORING=1; export SHIPLOG_BORING
  fi

  local target="${1:-}"
  if [ -z "$target" ]; then
    target="$(ref_journal "$DEFAULT_ENV")"
  fi

  if [ "$json_only" -eq 1 ]; then
    local body json
    body="$(git show -s --format=%B "$target")"
    json="$(awk '/^---/{flag=1;next}flag' <<< "$body")"
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
  local env="${1:-$DEFAULT_ENV}"
  local ref; ref="$(ref_journal "$env")"
  local ok=0 bad=0 unauth=0
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
  done < <(git rev-list "$(ref_journal "$env")")
  local verify_summary="Verified: OK=$ok, BadSig=$bad, Unauthorized=$unauth"
  if shiplog_can_use_bosun; then
    local bosun
    bosun=$(shiplog_bosun_bin)
    "$bosun" style --title "Verify" -- "$verify_summary"
  else
    printf '%s\n' "$verify_summary"
  fi
  [ $bad -eq 0 ] && [ $unauth -eq 0 ]
}

cmd_export_json() {
  ensure_in_repo
  local env="${1:-$DEFAULT_ENV}"
  command -v jq >/dev/null 2>&1 || die "jq required for --json export"
  local ref; ref="$(ref_journal "$env")"
  git rev-list "$ref" | while read -r c; do
    git show -s --format=%B "$c" | awk '/^---/{flag=1;next}flag' | jq -c --arg sha "$c" '. + {commit:$sha}'
  done
}

cmd_publish() {
  ensure_in_repo
  local env="$DEFAULT_ENV" push_notes=1 push_policy=0 push_trust=0 all_envs=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --env) shift; env="${1:-$env}"; shift; continue ;;
      --env=*) env="${1#*=}"; shift; continue ;;
      --no-notes) push_notes=0; shift; continue ;;
      --policy) push_policy=1; shift; continue ;;
      --trust) push_trust=1; shift; continue ;;
      --all|--all-envs) all_envs=1; shift; continue ;;
      --help|-h)
        cat <<'EOF'
Usage: git shiplog publish [--env ENV] [--no-notes] [--policy] [--trust] [--all]

Push Shiplog refs to the configured remote (defaults to origin) without writing
new entries. By default pushes the current environment journal and its notes.
Use --env to pick a journal; --all to push all journals under the ref root.
Optionally include policy/trust refs.
EOF
        return 0 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  local remote
  remote=$(shiplog_remote_name)
  has_remote_origin || die "shiplog: remote '$remote' not configured"

  local refs=()
  if [ "$all_envs" -eq 1 ]; then
    while read -r j; do [ -n "$j" ] && refs+=("$j"); done < <(git for-each-ref "${REF_ROOT}/journal/*" --format='%(refname)')
  else
    refs+=("$(ref_journal "$env")")
  fi

  for r in "${refs[@]}"; do
    git push --no-verify "$remote" "$r" || die "shiplog: failed to push $r"
    if [ "$push_notes" -eq 1 ]; then
      git push --no-verify "$remote" "$NOTES_REF" >/dev/null 2>&1 || true
    fi
  done

  [ "$push_policy" -eq 1 ] && git push --no-verify "$remote" "$POLICY_REF" >/dev/null 2>&1 || true
  [ "$push_trust" -eq 1 ] && git push --no-verify "$remote" "${TRUST_REF:-$TRUST_REF_DEFAULT}" >/dev/null 2>&1 || true

  if shiplog_can_use_bosun; then
    local bosun; bosun=$(shiplog_bosun_bin)
    "$bosun" style --title "Publish" -- "📤 Pushed Shiplog refs to $remote"
  fi
}


cmd_policy() {
  ensure_in_repo
  resolve_policy

  local boring=0 as_json=0 action=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --boring|-b) boring=1; shift ;;
      --json) as_json=1; shift ;;
      show|validate|require-signed|toggle) action="$1"; shift; break ;;
      *) action="$1"; shift; break ;;
    esac
  done
  action="${action:-show}"

  # Parse any trailing flags after the action (e.g., `policy show --json`)
  while [ $# -gt 0 ]; do
    case "$1" in
      --boring|-b) boring=1; shift ;;
      --json) as_json=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  if [ "$as_json" -eq 1 ]; then
    command -v jq >/dev/null 2>&1 || die "jq required for --json output"
  fi

  load_raw_policy() {
    local raw=""
    if git rev-parse --verify "$POLICY_REF" >/dev/null 2>&1; then
      raw=$(git show "$POLICY_REF:.shiplog/policy.json" 2>/dev/null || true)
    fi
    if [ -z "$raw" ] && [ -f ".shiplog/policy.json" ]; then
      raw=$(cat .shiplog/policy.json 2>/dev/null || true)
    fi
    printf '%s' "$raw"
  }

  case "$action" in
    show|"")
      local require_signed_bool="false"
      [ "${SHIPLOG_SIGN_EFFECTIVE:-0}" != "0" ] && require_signed_bool="true"
      if [ "$as_json" -eq 1 ]; then
        local raw_policy env_map
        raw_policy=$(load_raw_policy); [ -n "$raw_policy" ] || raw_policy='{}'
        # Derive env_require_signed map safely even if policy is minimal
        env_map=$(printf '%s\n' "$raw_policy" | jq -c '(.deployment_requirements // {}) | with_entries(.value = (.value.require_signed // null))' 2>/dev/null || printf '{}')
        jq -n \
          --arg source "${POLICY_SOURCE:-default}" \
          --arg authors "${ALLOWED_AUTHORS_EFFECTIVE:-}" \
          --arg signers "${SIGNERS_FILE_EFFECTIVE:-}" \
          --arg notes "${NOTES_REF:-refs/_shiplog/notes/logs}" \
          --argjson req "$require_signed_bool" \
          --argjson env "$env_map" \
          '{source:$source, require_signed:$req, allowed_authors:$authors, allowed_signers_file:$signers, notes_ref:$notes, env_require_signed:$env}' \
          || printf '{"source":"%s","require_signed":%s,"allowed_authors":"%s","allowed_signers_file":"%s","notes_ref":"%s","env_require_signed":{}}\n' \
               "${POLICY_SOURCE:-default}" "$require_signed_bool" "${ALLOWED_AUTHORS_EFFECTIVE:-}" "${SIGNERS_FILE_EFFECTIVE:-}" "${NOTES_REF:-refs/_shiplog/notes/logs}"
      else
        local signed_status; if [ "$require_signed_bool" = "true" ]; then signed_status="enabled"; else signed_status="disabled"; fi
        if [ "$boring" -eq 1 ] || ! shiplog_can_use_bosun; then
          printf 'Source: %s
' "${POLICY_SOURCE:-default}"
          printf 'Require Signed: %s
' "$signed_status"
          printf 'Allowed Authors: %s
' "${ALLOWED_AUTHORS_EFFECTIVE:-<none>}"
          printf 'Allowed Signers File: %s
' "${SIGNERS_FILE_EFFECTIVE:-<none>}"
          printf 'Notes Ref: %s
' "${NOTES_REF:-refs/_shiplog/notes/logs}"
          local raw_policy; raw_policy=$(load_raw_policy)
          if [ -n "$raw_policy" ]; then
            printf '%s
' "$raw_policy" | jq -r '(.deployment_requirements // {}) | to_entries | map(select(.value.require_signed != null)) | .[] | "Require Signed (\(.key)): \(.value.require_signed)"' 2>/dev/null || true
          fi
        else
          local rows="" raw_policy
          rows+='Source'$'\t'"${POLICY_SOURCE:-default}"$'
'
          rows+='Require Signed'$'\t'"$signed_status"$'
'
          rows+='Allowed Authors'$'\t'"${ALLOWED_AUTHORS_EFFECTIVE:-<none>}"$'
'
          rows+='Allowed Signers File'$'\t'"${SIGNERS_FILE_EFFECTIVE:-<none>}"$'
'
          rows+='Notes Ref'$'\t'"${NOTES_REF:-refs/_shiplog/notes/logs}"$'
'
          raw_policy=$(load_raw_policy)
          if [ -n "$raw_policy" ]; then
            mapfile -t policy_rows < <(
              printf '%s\n' "$raw_policy" |
                jq -r '(.deployment_requirements // {}) | to_entries | map(select(.value.require_signed != null)) | .[] | "\(.key)\t\(.value.require_signed)"' 2>/dev/null
            )
            for row in "${policy_rows[@]}"; do
              IFS=$'\t' read -r env_name env_req <<<"$row"
              [ -z "$env_name" ] && continue
              rows+='Require Signed ('"$env_name"$')'$'\t'"$env_req"$'\n'
            done
          fi
          local bosun; bosun=$(shiplog_bosun_bin)
          printf '%s' "$rows" | "$bosun" table --columns "Field,Value"
        fi
      fi
      ;;
    validate)
      need jq
      # Load raw policy JSON: prefer policy ref, fallback to working tree file
      local raw_policy
      raw_policy=$(load_raw_policy)
      if [ -z "$raw_policy" ]; then
        die "shiplog: no policy found (expected at $POLICY_REF:.shiplog/policy.json or ./.shiplog/policy.json)"
      fi

      # Ensure JSON parses
      if ! printf '%s\n' "$raw_policy" | jq . >/dev/null 2>&1; then
        die "shiplog: policy JSON is not parseable"
      fi


      # Structural checks (jq-only; AJV lives in CI). scripts/lib/policy_validate.jq is canonical.
      local errs=""
      local validator_status=0
      local validator_bin=""
      local validator_filter=""
      local search_root="${SHIPLOG_HOME:-$PWD}"
      local candidate
      for candidate in \
        "${SHIPLOG_POLICY_VALIDATE_BIN:-}" \
        "$search_root/scripts/policy/validate.sh" \
        "$PWD/scripts/policy/validate.sh"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
          validator_bin="$candidate"
          break
        fi
      done
      if [ -z "$validator_bin" ]; then
        for candidate in \
          "${SHIPLOG_POLICY_VALIDATOR:-}" \
          "$search_root/scripts/lib/policy_validate.jq" \
          "$PWD/scripts/lib/policy_validate.jq"; do
          if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            validator_filter="$candidate"
            break
          fi
        done
      fi
      if [ -n "$validator_bin" ]; then
        errs=$(printf '%s\n' "$raw_policy" | "$validator_bin" --stdin 2>&1)
        validator_status=$?
      else
        if [ -z "$validator_filter" ]; then
          die "shiplog: policy validator filter not found (expected scripts/lib/policy_validate.jq)"
        fi
        errs=$(printf '%s\n' "$raw_policy" | jq -r -f "$validator_filter" 2>&1)
        validator_status=$?
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
          "$bosun" style --title "Policy Validation" -- "❌ Invalid policy (${POLICY_SOURCE:-default})"
          printf '%s\n' "$errs" | "$bosun" style --title "Errors" --
        else
          # Print to stdout to make assertions simpler in tests
          printf '❌ shiplog: policy validation failed (%s)\n' "${POLICY_SOURCE:-default}"
          printf '%s\n' "$errs"
        fi
        return 1
      fi
      [ "$validator_status" -eq 0 ] || return 1

      if shiplog_can_use_bosun; then
        local bosun; bosun=$(shiplog_bosun_bin)
        "$bosun" style --title "Policy Validation" -- "✅ Policy OK (${POLICY_SOURCE:-default})"
      else
        printf '✅ Policy OK (%s)\n' "${POLICY_SOURCE:-default}"
      fi
      ;;
    require-signed)
      local val="${1:-}"; case "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) val=true ;; 0|false|no|off) val=false ;; *) die "Usage: git shiplog policy require-signed <true|false>" ;; esac
      mkdir -p .shiplog; local policy_file=".shiplog/policy.json" tmp; tmp=$(mktemp)
      if [ -f "$policy_file" ]; then jq --arg rs "$val" --arg ver "1.0.0" '
          (.version // $ver) as $v
          | .version = (if (($v|type) == "string") and ($v|test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) then $v else $ver end)
          | .require_signed = ($rs|test("^(1|true|yes|on)$";"i"))
        ' "$policy_file" >"$tmp" 2>/dev/null || { rm -f "$tmp"; die "shiplog: failed to update $policy_file"; }
      else printf '{"version":"1.0.0","require_signed":%s}
' "$val" >"$tmp"; fi
      policy_install_file "$tmp" "$policy_file"
      local using_bosun=0 bosun=""
      if shiplog_can_use_bosun; then
        using_bosun=1
        bosun=$(shiplog_bosun_bin)
      fi

      if [ "$using_bosun" -eq 1 ]; then
        "$bosun" style --title "Policy" -- "Set require_signed to $val in $policy_file"
      else
        printf 'Set require_signed to %s in %s\n' "$val" "$policy_file"
      fi

      local sync_helper="$SHIPLOG_HOME/scripts/shiplog-sync-policy.sh"
      local publish_remote; publish_remote=$(shiplog_remote_name)
      if [ -x "$sync_helper" ]; then
        SHIPLOG_POLICY_SIGN=${SHIPLOG_POLICY_SIGN:-0} "$sync_helper" "$policy_file" >/dev/null
        if [ "$using_bosun" -eq 1 ]; then
          "$bosun" style --title "Policy" -- "📤 Updated refs/_shiplog/policy/current (push to publish)"
        else
          printf 'Updated policy ref locally. Run: git push --no-verify %s %s\n' "$publish_remote" "refs/_shiplog/policy/current"
        fi
      else
        printf 'Note: sync helper missing; commit and publish policy manually.\n'
      fi
      ;;
    toggle)
      local current="${SHIPLOG_SIGN_EFFECTIVE:-0}"; local new="false"; [ "$current" = "0" ] && new=true || new=false; cmd_policy require-signed "$new" ;;
    *) die "Unknown policy subcommand: $action" ;;
  esac
}

cmd_trust() {
  ensure_in_repo
  local action="${1:-sync}"
  shift || true
  case "$action" in
    sync)
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
    root)
      local action="${1:-show}"; shift || true
      case "$action" in
        show)
          # Order of precedence: env, git config, default
          local current_root
          current_root="${SHIPLOG_REF_ROOT:-}"
          if [ -z "$current_root" ]; then
            current_root=$(git config --get shiplog.refRoot 2>/dev/null || true)
          fi
          current_root="${current_root:-$REF_ROOT}"
          printf '%s\n' "$current_root"
          ;;
        set)
          local new_root="${1:-}"
          if [ -z "$new_root" ]; then
            die "Usage: git shiplog refs root set <refs/...>"
          fi
          case "$new_root" in refs/*) : ;; *) die "Ref root must start with 'refs/'" ;; esac
          git config shiplog.refRoot "$new_root"
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
      "$SHIPLOG_HOME/scripts/shiplog-migrate-ref-root.sh" "$@"
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
        do_auto_push=1; shift ;;
      --no-auto-push)
        do_auto_push=0; shift ;;
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
        printf 'Usage: git shiplog setup [--strictness open|balanced|strict] [--authors "a@b c@d"] [--strict-envs "prod staging"] [--auto-push]\n' ; return 0 ;;
      --)
        shift; break ;;
      *)
        # Unknown option; show usage and fail
        die "shiplog: unknown setup option: $1" ;;
    esac
  done

  # Env override for auto-push
  case "${SHIPLOG_SETUP_AUTO_PUSH:-}" in
    1|true|yes|on) do_auto_push=1 ;;
    0|false|no|off|'') : ;;
  esac

  # Env override for dry-run
  case "${SHIPLOG_SETUP_DRY_RUN:-}" in
    1|true|yes|on) dry_run=1 ;;
  esac

  # Normalize strictness
  case "$(printf '%s' "$strictness" | tr '[:upper:]' '[:lower:]')" in
    open|balanced|strict) strictness="$(printf '%s' "$strictness" | tr '[:upper:]' '[:lower:]')" ;;
    *) die "shiplog: --strictness must be one of: open|balanced|strict" ;;
  esac

  # Build policy JSON
  mkdir -p .shiplog
  local tmp; tmp=$(mktemp)
  local require_signed_global="false"
  local authors_json='[]'
  local strict_envs_json='[]'

  # Convert space-separated lists to JSON arrays
  if [ -n "$authors_in" ]; then
    # squeeze spaces and split
    authors_json=$(printf '%s\n' "$authors_in" | tr ',;' '  ' | tr -s ' ' | awk '{for(i=1;i<=NF;i++) print $i}' | jq -R . | jq -s .)
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

  # Add authors for balanced
  if [ "$strictness" = "balanced" ] && [ -n "$authors_in" ]; then
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
    policy_install_file "$tmp" ".shiplog/policy.json"

    # Sync policy ref locally (no push here)
    if [ -x "$SHIPLOG_HOME/scripts/shiplog-sync-policy.sh" ]; then
      SHIPLOG_POLICY_SIGN=${SHIPLOG_POLICY_SIGN:-0} "$SHIPLOG_HOME/scripts/shiplog-sync-policy.sh" .shiplog/policy.json >/dev/null
    else
      printf 'Note: sync helper missing; commit and publish policy manually.\n'
    fi

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
      --answers-file) shift; answers_file="${1:-}"; shift; continue ;;
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
    if [ "$q_threshold" -gt 1 ] && [ "$q_host" != "self-hosted" ]; then q_sig_mode="attestation"; else q_sig_mode="chain"; fi
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
    if [ "$q_threshold" -gt 1 ] && [ "$q_host" != "self-hosted" ]; then q_sig_mode="attestation"; else q_sig_mode="chain"; fi
  fi
  case "$(printf '%s' "$q_sig_mode" | tr '[:upper:]' '[:lower:]')" in chain|attestation) : ;; *) q_sig_mode="chain" ;; esac
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
        "$bosun" style --title "GitHub Workflow (verify)" -- "$(sed 's/\t/  /g' "$wf")"
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
    mkdir -p .shiplog
    local tmp; tmp=$(mktemp)
    if [ $require_signed_global -eq 1 ]; then
      printf '{"version":"1.0.0","require_signed":true}\n' >"$tmp"
    elif [ $require_signed_prod -eq 1 ]; then
      printf '{"version":"1.0.0","require_signed":false,"deployment_requirements":{"prod":{"require_signed":true}}}\n' >"$tmp"
    else
      printf '{"version":"1.0.0","require_signed":false}\n' >"$tmp"
    fi
    policy_install_file "$tmp" ".shiplog/policy.json"
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
  trust sync [REF]     Refresh signer roster from the trust ref (default: refs/_shiplog/trust/root)
  trust show [REF]     Display trust roster and metadata (use --json for raw output)
  policy [show]        Show current policy configuration
  policy require-signed <true|false>
                       Set signing requirement in .shiplog/policy.json and sync policy ref
  policy toggle        Toggle signing requirement (unsigned ↔ signed) and sync policy ref
  refs root show       Show current Shiplog ref root
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
                         --authors "a@b c@d" (balanced)
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
  SHIPLOG_AUTO_PUSH    Auto-push to the configured remote (default: 1)
  SHIPLOG_REMOTE       Remote name used for Shiplog fetch/publish/push (default: origin or git config shiplog.remote)
  SHIPLOG_ASSUME_YES   Auto-confirm prompts (default: 0)
  SHIPLOG_BORING       Enable non-interactive mode (default: 0)
  SHIPLOG_DRY_RUN      Enable dry-run mode (1/true/yes/on; 0/false/no/off disables)
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
  local target="${1:-}"
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
  local err jq_output jq_status
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
    | .[]' 2>&1)
  jq_status=$?
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
