# shellcheck shell=bash
set -euo pipefail

LIB_DIR="${SHIPLOG_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
if [ -f "$LIB_DIR/common.sh" ]; then
  # shellcheck source=lib/common.sh
  source "$LIB_DIR/common.sh"
else
  echo "❌ shiplog: unable to locate common helpers at $LIB_DIR/common.sh" >&2
  exit 1
fi

ref_journal() { echo "$REF_ROOT/journal/$1"; }
ref_anchor()  { echo "$REF_ROOT/anchors/$1"; }

empty_tree()  { git hash-object -t tree /dev/null; }

current_tip() { git rev-parse --verify "$1" 2>/dev/null || true; }

ff_update() {
  local ref="$1" new="$2" old="$3" msg="${4:-append shiplog entry}"
  if shiplog_is_dry_run; then
    shiplog_dry_run_notice "Would update $ref"
    return 0
  fi
  git update-ref -m "$msg" "$ref" "$new" "${old:-0000000000000000000000000000000000000000}"
}

# -------- Structured trailer --------
# A journal entry is a human header, one sentinel line, then a JSON object.
# The writer emits exactly SHIPLOG_TRAILER_SENTINEL; every reader takes the
# LAST sentinel line, so user text in the header can never move the parse
# (SLT.BUG.CLI.001). Entries without a sentinel (hand-built or legacy) fall
# back to the last bare `---` line. The hook (contrib/hooks/pre-receive.shiplog
# read_commit_json) applies the same rule; keep them in sync.
SHIPLOG_TRAILER_SENTINEL='---  # structured trailer for machines'

# Documented status enum (docs/reference/json-schema.md). cmd_write validates
# against this list; validate-trailer checks the same values.
SHIPLOG_STATUS_VALUES="success failed in_progress skipped override revert finalize"

# Top-level trailer keys the writer owns. SHIPLOG_EXTRA_JSON / `append --json`
# may not set any of them (SLT.BUG.CLI.010); see docs/reference/json-schema.md.
# `commit` is reserved because export-json adds it at read time.
SHIPLOG_RESERVED_TRAILER_KEYS="version env ts who what where why how status when seq journal_parent trust_oid previous_anchor repo_head run commit"

# shiplog_extract_trailer < message
# Prints the JSON trailer of a commit message read from stdin (nothing when no
# separator is present).
shiplog_extract_trailer() {
  awk -v sentinel="$SHIPLOG_TRAILER_SENTINEL" '
    { line[NR] = $0 }
    $0 == sentinel { exact = NR }
    /^---/ { bare = NR }
    END {
      sep = exact ? exact : bare
      if (!sep) exit
      for (i = sep + 1; i <= NR; i++) print line[i]
    }'
}

# shiplog_extract_header < message
# Prints the human header: everything before the separator that
# shiplog_extract_trailer would pick (the whole message when there is none).
shiplog_extract_header() {
  awk -v sentinel="$SHIPLOG_TRAILER_SENTINEL" '
    { line[NR] = $0 }
    $0 == sentinel { exact = NR }
    /^---/ { bare = NR }
    END {
      sep = exact ? exact : bare
      if (!sep) sep = NR + 1
      for (i = 1; i < sep; i++) print line[i]
    }'
}

read_trailer_json() {
  local commit="$1"
  git show -s --format=%B "$commit" | shiplog_extract_trailer
}

# shiplog_single_line VALUE
# Header fields are one line each. Carriage returns are dropped and newlines
# become a single space, so no field can start a new header line and no header
# line can ever look like the trailer separator.
shiplog_single_line() {
  printf '%s' "$1" | tr -d '\r' | tr '\n' ' '
}

# shiplog_status_is_valid STATUS
shiplog_status_is_valid() {
  local candidate="$1" value
  for value in $SHIPLOG_STATUS_VALUES; do
    [ "$value" = "$candidate" ] && return 0
  done
  return 1
}

# shiplog_extra_json_check JSON [SOURCE]
# An extra-JSON payload must be an object and must not carry a reserved
# top-level key. Dies naming the offending key.
shiplog_extra_json_check() {
  local payload="$1" source="${2:-SHIPLOG_EXTRA_JSON}"
  need jq
  if ! printf '%s\n' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
    die "shiplog: $source must be a JSON object"
  fi
  local reserved_json clash
  # shellcheck disable=SC2086 # word-splitting the key list is intended
  reserved_json=$(printf '%s\n' $SHIPLOG_RESERVED_TRAILER_KEYS | jq -R . | jq -sc .)
  clash=$(printf '%s\n' "$payload" | jq -r --argjson reserved "$reserved_json" \
    '[keys[] | select(. as $k | $reserved | index($k) != null)] | first // empty')
  if [ -n "$clash" ]; then
    die "shiplog: $source may not set reserved trailer key \"$clash\" (reserved keys: $SHIPLOG_RESERVED_TRAILER_KEYS)"
  fi
}

trailer_value() {
  local commit="$1" filter="$2"
  local json
  json=$(read_trailer_json "$commit") || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -r "$filter" 2>/dev/null
}

compose_message() {
  local env="$1" service="$2" status="$3" reason="$4" ticket="$5" region="$6" cluster="$7" ns="$8" start_ts="$9"
  local end_ts="${10}" dur_s="${11}" repo_head="${12}" artifact="${13}" run_url="${14}" seq="${15}"
  local journal_parent="${16}" trust_oid="${17}" previous_anchor="${18}" write_ts="${19}"
  local author_name="${20}" author_email="${21}"

  need jq

  local status_upper artifact_display parent_short trust_short anchor_short json
  status_upper=$(printf '%s' "${status:-}" | tr '[:lower:]' '[:upper:]')

  if [ -n "$artifact" ]; then
    artifact_display="$artifact"
  else
    artifact_display=""
  fi

  if [ -n "$journal_parent" ]; then
    parent_short=$(git rev-parse --short "$journal_parent" 2>/dev/null || printf '%.7s' "$journal_parent")
  else
    parent_short="(genesis)"
  fi

  if [ -n "$trust_oid" ]; then
    trust_short=$(git rev-parse --short "$trust_oid" 2>/dev/null || printf '%.7s' "$trust_oid")
  else
    trust_short="(unset)"
  fi

  if [ -n "$previous_anchor" ]; then
    anchor_short=$(git rev-parse --short "$previous_anchor" 2>/dev/null || printf '%.7s' "$previous_anchor")
  else
    anchor_short="(none)"
  fi

  local jq_filter
  read -r -d '' jq_filter <<'JQ' || true
{
  version: 1,
  env: $env,
  ts: $ts,
  who: { name: $name, email: $email },
  what: {
    service: $service,
    artifact: (if $artifact == "" then null else $artifact end),
    repo_head: $repo_head
  },
  where: {
    env: $env,
    region: (if $region == "" then null else $region end),
    cluster: (if $cluster == "" then null else $cluster end),
    namespace: (if $ns == "" then null else $ns end)
  },
  why: {
    reason: (if $reason == "" then null else $reason end),
    ticket: (if $ticket == "" then null else $ticket end)
  },
  how: {
    pipeline: null,
    run_url: (if $run_url == "" then null else $run_url end)
  },
  status: $status,
  when: {
    start_ts: $start_ts,
    end_ts: $end_ts,
    dur_s: $dur
  },
  seq: $seq,
  journal_parent: (if $parent == "" then null else $parent end),
  trust_oid: $trust,
  previous_anchor: (if $anchor == "" then null else $anchor end),
  repo_head: $repo
}
JQ

  json=$(jq -n \
    --arg env "$env" \
    --arg ts "$write_ts" \
    --arg name "$author_name" \
    --arg email "$author_email" \
    --arg service "$service" \
    --arg artifact "$artifact" \
    --arg repo_head "$repo_head" \
    --arg region "$region" \
    --arg cluster "$cluster" \
    --arg ns "$ns" \
    --arg reason "$reason" \
    --arg ticket "$ticket" \
    --arg run_url "$run_url" \
    --arg status "$status" \
    --arg start_ts "$start_ts" \
    --arg end_ts "$end_ts" \
    --arg trust "$trust_oid" \
    --arg parent "$journal_parent" \
    --arg anchor "$previous_anchor" \
    --arg repo "$repo_head" \
    --argjson dur "$dur_s" \
    --argjson seq "$seq" \
    "$jq_filter")

  # `run` metadata is a core key that cmd_run supplies through SHIPLOG_RUN_JSON
  # (internal). It is attached before extras, so extras can never replace it.
  if [ -n "${SHIPLOG_RUN_JSON:-}" ]; then
    local run_merged
    if ! run_merged=$(printf '%s\n' "$json" | jq --argjson run "${SHIPLOG_RUN_JSON}" '.run = $run' 2>/dev/null); then
      die "shiplog: SHIPLOG_RUN_JSON must be a valid JSON object"
    fi
    json="$run_merged"
  fi

  # Extras (append --json / SHIPLOG_EXTRA_JSON) sit beside the core keys. A
  # payload naming a reserved key is rejected, and the merge is `$extra + .`
  # so the core trailer wins even if that check were ever bypassed.
  if [ -n "${SHIPLOG_EXTRA_JSON:-}" ]; then
    shiplog_extra_json_check "${SHIPLOG_EXTRA_JSON}" "SHIPLOG_EXTRA_JSON"
    local extra_merged
    if ! extra_merged=$(printf '%s\n' "$json" | jq -S --argjson extra "${SHIPLOG_EXTRA_JSON}" '$extra + .' 2>/dev/null); then
      die "shiplog: SHIPLOG_EXTRA_JSON must be valid JSON object"
    fi
    json="$extra_merged"
  fi

  # Build a compact location string: always env; append region/cluster when present;
  # append namespace only when provided and not redundant.
  local loc="$env"
  if [ -n "$region" ]; then
    loc="$loc/$region"
  fi
  if [ -n "$cluster" ]; then
    loc="$loc/$cluster"
  fi
  if [ -n "$ns" ]; then
    if [ -n "$region$cluster" ] || [ "$ns" != "$env" ]; then
      loc="$loc/$ns"
    fi
  fi

  cat <<EOF
Deploy: $service${artifact_display:+ $artifact_display} → $loc
Reason: ${reason:-"—"} ${ticket:+($ticket)}
Status: ${status_upper:-?} (${dur_s}s) @ $write_ts
Seq:    $seq (parent $parent_short, trust $trust_short, anchor $anchor_short)
Author: ${author_email:-unknown}
Repo:   ${repo_head}

$SHIPLOG_TRAILER_SENTINEL
$json
EOF
}

sign_commit() {
  local tree="$1"; shift
  resolve_policy
  local sign_mode="${SHIPLOG_SIGN_EFFECTIVE:-0}"
  # One identity everywhere: the email the allowlist precheck and the trailer's
  # who.email used becomes both the author and the committer of the entry
  # (SLT.BUG.LIB.012). The hook and `verify` read %ae.
  local author_name author_email
  author_name="${GIT_AUTHOR_NAME:-${SHIPLOG_AUTHOR_NAME:-$(git config user.name || echo 'Shiplog Bot')}}"
  author_email="${GIT_AUTHOR_EMAIL:-${SHIPLOG_AUTHOR_EMAIL:-$(git config user.email || echo 'shiplog-bot@local')}}"

  # Build commit-tree command safely without expanding an empty array under set -u
  local -a cmd
  cmd=(git commit-tree "$tree")
  case "$sign_mode" in
    0|false|no|off) : ;;
    *) cmd+=(-S) ;;
  esac
  # Append remaining arguments (e.g., -p <parent>)
  if [ "$#" -gt 0 ]; then
    cmd+=("$@")
  fi
  GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email" \
  GIT_COMMITTER_NAME="$author_name" GIT_COMMITTER_EMAIL="$author_email" \
    "${cmd[@]}"
}

attach_note_if_present() {
  local commit="$1" log_path="${2:-}"
  [ -z "${log_path}" ] && return 0
  if shiplog_is_dry_run; then
    shiplog_dry_run_notice "Would attach note to $commit"
    return 0
  fi
  git notes --ref="$NOTES_REF" add -F "$log_path" "$commit"
}

ensure_signed_on_verify() {
  local commit="$1"
  resolve_policy

  case "${SHIPLOG_SIGN_EFFECTIVE:-0}" in
    0|false|no|off) return 0 ;;
  esac

  if ! git cat-file commit "$commit" | grep -q '^gpgsig '; then
    return 1
  fi

  local verify_file="$SIGNERS_FILE_EFFECTIVE"
  if [ -n "$verify_file" ] && [ -f "$verify_file" ]; then
    GIT_SSH_ALLOWED_SIGNERS="$verify_file" git verify-commit "$commit" >/dev/null 2>&1 \
      || return 1
  else
    git verify-commit "$commit" >/dev/null 2>&1 || return 1
  fi
  return 0
}

author_allowed() {
  resolve_policy
  local author="$1"
  local allow="$ALLOWED_AUTHORS_EFFECTIVE"
  [ -z "$allow" ] && return 0
  for a in $allow; do
    [ "$a" = "$author" ] && return 0
  done
  return 1
}

require_allowed_author() {
  resolve_policy
  local allow="$ALLOWED_AUTHORS_EFFECTIVE"
  [ -z "$allow" ] && return 0

  local email
  if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
    email="$GIT_AUTHOR_EMAIL"
  elif [ -n "${SHIPLOG_AUTHOR_EMAIL:-}" ]; then
    email="$SHIPLOG_AUTHOR_EMAIL"
  else
    email="$(git config user.email || echo)"
  fi

  if [ -z "$email" ]; then
    die "shiplog: unable to determine author email for allowlist enforcement"
  fi

  for a in $allow; do
    [ "$a" = "$email" ] && return 0
  done

  die "shiplog: author <$email> not in allowlist: $allow"
}

require_allowed_signer() {
  resolve_policy
  case "${SHIPLOG_SIGN_EFFECTIVE:-0}" in
    0|false|no|off) return 0 ;;
  esac

  local asf="$SIGNERS_FILE_EFFECTIVE"
  [ -n "$asf" ] && [ -f "$asf" ] || return 0

  local tree tmp
  tree=$(empty_tree)
  if ! tmp=$(printf 'shiplog: signing precheck\n' |
    GIT_AUTHOR_NAME='Shiplog Precheck' \
    GIT_AUTHOR_EMAIL='shiplog-precheck@local' \
    GIT_COMMITTER_NAME='Shiplog Precheck' \
    GIT_COMMITTER_EMAIL='shiplog-precheck@local' \
    git commit-tree "$tree" -S); then
    die "shiplog: signing precheck failed (configure your signing key)"
  fi

  if ! GIT_SSH_ALLOWED_SIGNERS="$asf" git verify-commit "$tmp" >/dev/null 2>&1; then
    die "shiplog: signature not accepted by allowed signers file ($asf)"
  fi
}

pretty_ls() {
  local ref="$1" limit="$2"
  local rows=""
  local header_cols=(Commit Status Service Env Author Date)
  local header_line
  local bosun_available=0
  local bosun_bin

  if ! is_boring && shiplog_have_bosun; then
    bosun_bin=$(shiplog_bosun_bin)
    bosun_available=1
  elif ! is_boring; then
    printf 'shiplog: %s not found; falling back to plain output\n' "$(shiplog_bosun_bin)" >&2
  fi

  header_line=$(printf '%s\t' "${header_cols[@]}")
  header_line=${header_line%$'\t'}
  local old_ifs="$IFS"
  IFS=,
  local bosun_columns="${header_cols[*]}"
  IFS="$old_ifs"

  while IFS= read -r c; do
    local author date status service env body json
    author="$(git show -s --format='%ae' "$c")"
    date="$(git show -s --format='%cs' "$c")"
    body="$(git show -s --format=%B "$c")"
    json="$(shiplog_extract_trailer <<< "$body")"
    if command -v jq >/dev/null 2>&1 && [ -n "$json" ]; then
      service="$(printf '%s' "$json" | jq -r '.what.service // empty')"
      env="$(printf '%s' "$json" | jq -r '.env // .where.env // empty')"
      status="$(printf '%s' "$json" | jq -r '.status // empty' | tr '[:lower:]' '[:upper:]')"
    else
      # Fallback heuristics
      local subj
      subj="$(git show -s --format='%s' "$c")"
      service="$(echo "$subj" | awk '{print $2}')"
      env="$(echo "$subj" | awk '{print $4}' | awk -F'→' '{print $2}' | awk -F'/' '{print $1}')"
      status="$(echo "$body" | awk -F': ' '/^Status: /{print $2; exit}' | awk '{print $1}')"
      status="$(printf '%s' "$status" | tr '[:lower:]' '[:upper:]')"
    fi
    [ -n "$service" ] || service="-"
    [ -n "$env" ] || env="-"
    [ -n "$status" ] || status="-"
    rows+="$c"$'\t'"$status"$'\t'"$service"$'\t'"$env"$'\t'"$author"$'\t'"$date"$'\n'
  done < <(git rev-list --max-count="$limit" "$ref")

  if is_boring || [ "$bosun_available" -ne 1 ]; then
    printf '%s\n' "$header_line"
    printf '%s' "$rows"
  else
    printf '%s' "$rows" | "$bosun_bin" table --columns "$bosun_columns"
  fi
}

show_entry() {
  local target="$1"
  local body human json
  body="$(git show -s --format=%B "$target")"
  human="$(awk '/^---/{exit} {print}' <<< "$body")"
  json="$(awk '/^---/{flag=1;next}flag' <<< "$body")"

  local bosun_bin=""
  local bosun_available=0
  if ! is_boring && shiplog_have_bosun; then
    bosun_bin=$(shiplog_bosun_bin)
    bosun_available=1
  elif ! is_boring; then
    printf 'shiplog: %s not found; falling back to plain output\n' "$(shiplog_bosun_bin)" >&2
  fi

  if is_boring || [ "$bosun_available" -ne 1 ]; then
    printf '%s\n' "$human"
    if [ -n "$json" ]; then
      if command -v jq >/dev/null 2>&1; then
        echo "$json" | jq .
      else
        printf '%s\n' "$json"
      fi
    fi
    if git notes --ref="$NOTES_REF" show "$target" >/dev/null 2>&1; then
      git notes --ref="$NOTES_REF" show "$target"
    fi
    return 0
  fi

  "$bosun_bin" style --title "SHIPLOG Entry" -- "$human"

  if [ -n "$json" ]; then
    if command -v jq >/dev/null 2>&1; then
      echo "$json" | jq . | "$bosun_bin" style --title "Structured Trailer (JSON)"
    else
      echo "$json" | "$bosun_bin" style --title "Structured Trailer (raw)"
    fi
  fi

  if git notes --ref="$NOTES_REF" show "$target" >/dev/null 2>&1; then
    git notes --ref="$NOTES_REF" show "$target" | "$bosun_bin" style --title "Attached Log (notes)"
  fi
}

ensure_in_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Run inside a git repo."
  git rev-parse HEAD >/dev/null 2>&1 || die "Repo must have at least one commit (HEAD)."
}
