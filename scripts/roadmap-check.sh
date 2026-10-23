#!/usr/bin/env bash
# roadmap-check.sh — evaluate ROADMAP.md goal definitions of done and update the tracking issue.
#
# Each goal in ROADMAP.md lists checks as `kind:arg[:arg...]`. This script implements those
# kinds, runs them per goal, prints a table, and (with --update) ticks or un-ticks the goal
# and issue checkboxes on the tracking issue. It never runs the Bats suite: test-backed
# checks read the latest CI result on main (D4 in ROADMAP.md).
#
# Usage:
#   scripts/roadmap-check.sh [--goal Gn] [--markdown] [--update] [--issue N] [--self-test]
# Exit codes: 0 all goals pass, 1 some goal fails (normal while the roadmap is open),
#             2 tooling error (gh missing, auth, parse).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
ROADMAP="${ROADMAP_CHECK_ROADMAP:-$ROOT/ROADMAP.md}"

ISSUE=155
LABEL="audit-2026-10"
ONLY_GOAL=""
MARKDOWN=0
UPDATE=0
SELF_TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --goal) shift; ONLY_GOAL="${1:-}"; [ -n "$ONLY_GOAL" ] || { echo "--goal requires a value" >&2; exit 2; } ;;
    --issue) shift; ISSUE="${1:-}"; [ -n "$ISSUE" ] || { echo "--issue requires a value" >&2; exit 2; } ;;
    --markdown) MARKDOWN=1 ;;
    --update) UPDATE=1 ;;
    --self-test) SELF_TEST=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Result recording
# ---------------------------------------------------------------------------
declare -a RESULTS=()          # "goal<TAB>status<TAB>check<TAB>detail"
declare -A GOAL_PASS=() GOAL_TOTAL=()

record() { # goal status check detail
  RESULTS+=("$1	$2	$3	$4")
  GOAL_TOTAL[$1]=$(( ${GOAL_TOTAL[$1]:-0} + 1 ))
  if [ "$2" = ok ]; then GOAL_PASS[$1]=$(( ${GOAL_PASS[$1]:-0} + 1 )); fi
}

# ---------------------------------------------------------------------------
# gh-backed data, fetched once
# ---------------------------------------------------------------------------
GH_OK=0
declare -A ISSUE_STATE=()
TRACKING_BODY=""
CI_MAIN=""

have_gh() { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }

load_gh_data() {
  have_gh || return 1
  local json
  json=$(gh issue list --label "$LABEL" --state all --limit 300 --json number,state 2>/dev/null) || return 1
  while IFS=$'\t' read -r n s; do
    [ -n "$n" ] && ISSUE_STATE[$n]="$s"
  done < <(printf '%s' "$json" | jq -r '.[] | "\(.number)\t\(.state)"')
  TRACKING_BODY=$(gh issue view "$ISSUE" --json body -q .body 2>/dev/null) || return 1
  CI_MAIN=$(gh run list --workflow ci.yml --branch main --status completed --limit 1 --json conclusion -q '.[0].conclusion' 2>/dev/null) || return 1
  GH_OK=1
  return 0
}

issue_closed() { # number
  [ "$GH_OK" -eq 1 ] || return 2
  case "${ISSUE_STATE[$1]:-}" in
    CLOSED) return 0 ;;
    "") # not in the label set; ask directly
      local s; s=$(gh issue view "$1" --json state -q .state 2>/dev/null) || return 2
      ISSUE_STATE[$1]="$s"; [ "$s" = CLOSED ] ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Check kinds. Each returns 0 ok, 1 fail, 2 skip (tooling), and prints a detail.
# ---------------------------------------------------------------------------
chk_file()     { [ -f "$1" ] && echo "present" || { echo "missing: $1"; return 1; }; }
chk_no_file()  { [ ! -e "$1" ] && echo "absent" || { echo "still present: $1"; return 1; }; }
chk_grep()     { # path:pattern
  local path="$1" pat="$2"
  [ -f "$path" ] || { echo "missing: $path"; return 1; }
  grep -Eq -- "$pat" "$path" && echo "found" || { echo "not found: $pat"; return 1; }
}
chk_grep_zero() { # "paths" pattern  (paths space-separated; files or dirs)
  local paths="$1" pat="$2" n
  # shellcheck disable=SC2086
  n=$(git grep -c -E -- "$pat" -- $paths 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')
  [ "$n" -eq 0 ] && echo "0 matches" || { echo "$n match(es)"; return 1; }
}
chk_count_ge() { # path pattern-or-glob min
  local path="$1" pat="$2" min="$3" n
  if [ -d "$path" ]; then
    n=$(find "$path" -maxdepth 1 -name "$pat" -type f 2>/dev/null | wc -l | tr -d ' ')
  elif [ -f "$path" ]; then
    n=$(grep -Ec -- "$pat" "$path" 2>/dev/null); n=${n:-0}  # grep -c prints 0 (exit 1) on no match
  else
    echo "missing: $path"; return 1
  fi
  [ "$n" -ge "$min" ] && echo "$n >= $min" || { echo "$n < $min"; return 1; }
}
chk_size_lt()  { # path bytes
  [ -f "$1" ] || { echo "missing: $1"; return 1; }
  local b; b=$(wc -c < "$1" | tr -d ' ')
  [ "$b" -lt "$2" ] && echo "$b bytes" || { echo "$b bytes >= $2"; return 1; }
}
chk_exec()     { # command...
  local out; out=$(bash -c "$*" 2>&1); local rc=$?
  [ $rc -eq 0 ] && echo "exit 0" || { echo "exit $rc: $(printf '%s' "$out" | tail -1)"; return 1; }
}
chk_exec_bits() { # dirs...
  local bad
  # shellcheck disable=SC2086
  bad=$(git ls-files -s -- $* | while read -r mode _ _ path; do
      [ "$mode" = 100755 ] && continue
      head -c2 "$path" 2>/dev/null | grep -q '^#!' && echo "$path"
    done)
  [ -z "$bad" ] && echo "all scripts 100755" || { echo "not executable: $(printf '%s' "$bad" | tr '\n' ' ')"; return 1; }
}
chk_issues_closed() { # comma list
  [ "$GH_OK" -eq 1 ] || { echo "gh unavailable"; return 2; }
  local open=() n
  IFS=, read -ra nums <<< "$1"
  for n in "${nums[@]}"; do issue_closed "$n" || open+=("#$n"); done
  [ ${#open[@]} -eq 0 ] && echo "${#nums[@]} closed" || { echo "open: ${open[*]}"; return 1; }
}
chk_label_all_closed() { # label
  [ "$GH_OK" -eq 1 ] || { echo "gh unavailable"; return 2; }
  local n; n=$(gh issue list --label "$1" --state open --limit 300 --json number -q length 2>/dev/null) || { echo "gh error"; return 2; }
  [ "$n" -eq 0 ] && echo "none open" || { echo "$n open"; return 1; }
}
chk_issue_body() { # issue pattern
  [ "$GH_OK" -eq 1 ] || { echo "gh unavailable"; return 2; }
  local body="$TRACKING_BODY"
  if [ "$1" != "$ISSUE" ]; then
    body=$(gh issue view "$1" --json body -q .body 2>/dev/null) || { echo "gh error"; return 2; }
  fi
  printf '%s' "$body" | grep -Eq -- "$2" && echo "found" || { echo "not found: $2"; return 1; }
}
chk_ci_main_green() { # workflow (informational; only ci.yml is read)
  [ "$GH_OK" -eq 1 ] || { echo "gh unavailable"; return 2; }
  [ "$CI_MAIN" = success ] && echo "latest main run: success" || { echo "latest main run: ${CI_MAIN:-none}"; return 1; }
}
chk_tag() { # tag
  if git rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1; then echo "local tag"; return 0; fi
  git ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null 2>&1 && echo "remote tag" || { echo "no tag $1"; return 1; }
}

run_check() { # goal spec
  local goal="$1" spec="$2" kind rest detail rc
  kind="${spec%%:*}"; rest="${spec#*:}"
  case "$kind" in
    file)             detail=$(chk_file "$rest"); rc=$? ;;
    no-file)          detail=$(chk_no_file "$rest"); rc=$? ;;
    grep)             detail=$(chk_grep "${rest%%:*}" "${rest#*:}"); rc=$? ;;
    grep-zero)        detail=$(chk_grep_zero "${rest%%:*}" "${rest#*:}"); rc=$? ;;
    count-ge)         IFS=: read -r p pat min <<< "$rest"; detail=$(chk_count_ge "$p" "$pat" "$min"); rc=$? ;;
    size-lt)          detail=$(chk_size_lt "${rest%%:*}" "${rest#*:}"); rc=$? ;;
    exec)             detail=$(chk_exec "$rest"); rc=$? ;;
    exec-bits)        detail=$(chk_exec_bits "$rest"); rc=$? ;;
    issues-closed)    detail=$(chk_issues_closed "$rest"); rc=$? ;;
    label-all-closed) detail=$(chk_label_all_closed "$rest"); rc=$? ;;
    issue-body)       detail=$(chk_issue_body "${rest%%:*}" "${rest#*:}"); rc=$? ;;
    ci-main-green)    detail=$(chk_ci_main_green "$rest"); rc=$? ;;
    tag)              detail=$(chk_tag "$rest"); rc=$? ;;
    *)                detail="unknown check kind"; rc=2 ;;
  esac
  case $rc in 0) record "$goal" ok "$spec" "$detail" ;; 1) record "$goal" fail "$spec" "$detail" ;; *) record "$goal" skip "$spec" "$detail" ;; esac
}

# ---------------------------------------------------------------------------
# Parse ROADMAP.md: goals (## Gn:) and their check bullets (- `kind:...`) under
# "### Definition of done". Keeps ROADMAP.md as the single list of checks.
# ---------------------------------------------------------------------------
declare -a GOALS=()
declare -A GOAL_TITLE=() GOAL_CHECKS=()

parse_roadmap() {
  local goal="" in_dod=0 line spec
  while IFS= read -r line; do
    if [[ "$line" =~ ^##\ (G[0-9]+):\ (.*)$ ]]; then
      goal="${BASH_REMATCH[1]}"; GOALS+=("$goal"); GOAL_TITLE[$goal]="${BASH_REMATCH[2]}"; in_dod=0; continue
    fi
    [ -n "$goal" ] || continue
    if [[ "$line" =~ ^###\  ]]; then
      [[ "$line" =~ ^###\ Definition\ of\ done ]] && in_dod=1 || in_dod=0; continue
    fi
    if [ "$in_dod" -eq 1 ] && [[ "$line" =~ ^-\ \`([^\`]+)\` ]]; then
      spec="${BASH_REMATCH[1]}"
      GOAL_CHECKS[$goal]="${GOAL_CHECKS[$goal]:-}${spec}"$'\n'
    fi
  done < "$ROADMAP"
  [ ${#GOALS[@]} -gt 0 ] || { echo "no goals parsed from ROADMAP.md" >&2; return 2; }
}

# ---------------------------------------------------------------------------
# Self-test: exercise the check kinds against fixtures, no network.
# ---------------------------------------------------------------------------
# Fixture runs: a fake gh on PATH, a fixture roadmap, and this script run as a child.
ST_DIR=""
st_setup() {
  ST_DIR=$(mktemp -d)
  mkdir -p "$ST_DIR/bin"
  cat > "$ST_DIR/roadmap.md" <<'EOF'
## G1: one
### Definition of done
- `file:ROADMAP.md`
## G2: two
### Definition of done
- `no-file:ROADMAP.md`
## G3: ci
### Definition of done
- `ci-main-green:ci.yml`
EOF
  printf '%s\n' 'intro' '- [ ] G1: one' '- [x] G2: two' '- [ ] G3: ci' \
    '- [ ] #10 ten' '- [x] #11 eleven' '- [ ] #12' '- [ ] #100 not ten' > "$ST_DIR/body.md"
  printf '%s\n' '[{"number":10,"state":"CLOSED"},{"number":11,"state":"OPEN"},{"number":12,"state":"CLOSED"}]' > "$ST_DIR/issues.json"
  echo success > "$ST_DIR/run.txt"
  cat > "$ST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
d="$FAKE_GH_DIR"
case "$1 $2" in
  "auth status") exit 0 ;;
  "issue list")
    case " $* " in
      *" --state open "*) jq '[.[] | select(.state == "OPEN")] | length' "$d/issues.json" ;;
      *) cat "$d/issues.json" ;;
    esac ;;
  "issue view")
    if [ "$3" = 155 ]; then cat "$d/body.md"; exit 0; fi
    s=$(jq -r --argjson n "$3" '.[] | select(.number == $n) | .state' "$d/issues.json")
    [ -n "$s" ] || exit 1
    printf '%s\n' "$s" ;;
  "run list") [ ! -f "$d/run_fail" ] || exit 1; cat "$d/run.txt" ;;
  "issue edit")
    while [ $# -gt 0 ]; do
      [ "$1" = --body ] && { printf '%s' "$2" > "$d/edited.md"; exit 0; }
      shift
    done
    exit 1 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$ST_DIR/bin/gh"
}
st_run() { # args... -> child exit code; an edited body lands in $ST_DIR/edited.md
  rm -f "$ST_DIR/edited.md"
  PATH="$ST_DIR/bin:$PATH" FAKE_GH_DIR="$ST_DIR" ROADMAP_CHECK_ROADMAP="$ST_DIR/roadmap.md" \
    bash "$ROOT/scripts/roadmap-check.sh" --issue 155 "$@" >/dev/null 2>&1
}
st_line() { grep -qxF -- "$1" "$ST_DIR/edited.md" 2>/dev/null; }

self_test() {
  local t rc=0; t=$(mktemp -d)
  printf 'alpha\nbeta\n' > "$t/f.txt"; : > "$t/a.json"; : > "$t/b.json"
  chk_file "$t/f.txt" >/dev/null || { echo "self-test: file"; rc=1; }
  chk_no_file "$t/none" >/dev/null || { echo "self-test: no-file"; rc=1; }
  chk_grep "$t/f.txt" '^beta$' >/dev/null || { echo "self-test: grep"; rc=1; }
  chk_grep "$t/f.txt" gamma >/dev/null && { echo "self-test: grep negative"; rc=1; }
  chk_count_ge "$t/f.txt" 'a' 2 >/dev/null || { echo "self-test: count-ge file"; rc=1; }
  chk_count_ge "$t" '*.json' 2 >/dev/null || { echo "self-test: count-ge dir"; rc=1; }
  chk_count_ge "$t" '*.json' 3 >/dev/null && { echo "self-test: count-ge dir negative"; rc=1; }
  chk_count_ge "$t/f.txt" 'gamma' 0 >/dev/null || { echo "self-test: count-ge file with zero matches"; rc=1; }
  chk_size_lt "$t/f.txt" 100 >/dev/null || { echo "self-test: size-lt"; rc=1; }
  chk_exec "true" >/dev/null || { echo "self-test: exec"; rc=1; }
  chk_exec "false" >/dev/null && { echo "self-test: exec negative"; rc=1; }
  GOALS=(); GOAL_TITLE=(); GOAL_CHECKS=()
  parse_roadmap || rc=1
  [ "${#GOALS[@]}" -ge 9 ] || { echo "self-test: expected >= 9 goals, got ${#GOALS[@]}"; rc=1; }
  [ -n "${GOAL_CHECKS[G1]:-}" ] || { echo "self-test: G1 has no checks"; rc=1; }
  rm -rf "$t"
  # The workflow holds an issues:write token: actions pinned to a full SHA, no persisted credentials.
  if grep -E '^[[:space:]]*(- )?uses:' "$ROOT/.github/workflows/roadmap.yml" | grep -Evq '@[0-9a-f]{40}([[:space:]]|$)' \
    || ! grep -Eq '^[[:space:]]*persist-credentials:[[:space:]]*false' "$ROOT/.github/workflows/roadmap.yml"; then
    echo "self-test: roadmap.yml has an unpinned action or persisted credentials"; rc=1
  fi
  st_setup
  # Issue updates need no perl, and a failed transformation must not reach gh issue edit.
  printf '#!/bin/sh\nexit 127\n' > "$ST_DIR/bin/perl"; chmod +x "$ST_DIR/bin/perl"
  st_run --update
  { st_line 'intro' && st_line '- [x] G1: one' && st_line '- [x] #10 ten' && st_line '- [ ] #100 not ten'; } \
    || { echo "self-test: update without perl"; rc=1; }
  rm -f "$ST_DIR/bin/perl"
  # --goal limits --update to that goal; an unknown goal is rejected before any edit.
  st_run --goal G1 --update
  { st_line '- [x] G1: one' && st_line '- [x] G2: two'; } || { echo "self-test: --goal --update touched other goals"; rc=1; }
  st_run --goal G9 --update; local st_rc=$?
  { [ "$st_rc" -eq 2 ] && [ ! -e "$ST_DIR/edited.md" ]; } || { echo "self-test: unknown --goal not rejected (exit $st_rc)"; rc=1; }
  # A reopened issue's row is unticked; closed rows are ticked.
  st_run --update
  { st_line '- [ ] #11 eleven' && st_line '- [x] #12'; } || { echo "self-test: reopened issue row stays ticked"; rc=1; }
  # A failed body lookup for another issue is a skip (tooling), not a fail.
  ( export PATH="$ST_DIR/bin:$PATH" FAKE_GH_DIR="$ST_DIR"; GH_OK=1; chk_issue_body 999 x >/dev/null ); st_rc=$?
  [ "$st_rc" -eq 2 ] || { echo "self-test: issue-body lookup failure reported as exit $st_rc, want 2"; rc=1; }
  # A failed CI lookup is a tooling error, not a red main: no edit, exit 2.
  : > "$ST_DIR/run_fail"
  st_run --update; st_rc=$?
  rm -f "$ST_DIR/run_fail"
  { [ "$st_rc" -eq 2 ] && [ ! -e "$ST_DIR/edited.md" ]; } || { echo "self-test: failed CI lookup not treated as tooling error (exit $st_rc)"; rc=1; }
  rm -rf "$ST_DIR"
  [ $rc -eq 0 ] && echo "self-test: ok"
  return $rc
}

if [ "$SELF_TEST" -eq 1 ]; then self_test; exit $?; fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
parse_roadmap || exit 2
if [ -n "$ONLY_GOAL" ] && [ -z "${GOAL_TITLE[$ONLY_GOAL]+set}" ]; then
  echo "unknown goal: $ONLY_GOAL" >&2; exit 2
fi
load_gh_data || echo "note: gh unavailable or unauthenticated; issue/CI checks are skipped" >&2

for g in "${GOALS[@]}"; do
  [ -z "$ONLY_GOAL" ] || [ "$g" = "$ONLY_GOAL" ] || continue
  while IFS= read -r spec; do
    [ -n "$spec" ] && run_check "$g" "$spec"
  done <<< "${GOAL_CHECKS[$g]}"
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
goal_status() { # goal -> pass|fail|partial
  local p=${GOAL_PASS[$1]:-0} t=${GOAL_TOTAL[$1]:-0}
  [ "$t" -gt 0 ] || { echo none; return; }
  [ "$p" -eq "$t" ] && echo pass || echo fail
}

ALL_PASS=1
if [ "$MARKDOWN" -eq 1 ]; then
  echo "## Roadmap check — $(date -u +%Y-%m-%dT%H:%MZ)"; echo
  echo "| Goal | Status | Checks | Title |"; echo "|---|---|---|---|"
  for g in "${GOALS[@]}"; do
    [ -z "$ONLY_GOAL" ] || [ "$g" = "$ONLY_GOAL" ] || continue
    s=$(goal_status "$g"); [ "$s" = pass ] || ALL_PASS=0
    icon=$([ "$s" = pass ] && echo "✅" || echo "⬜")
    echo "| $g | $icon $s | ${GOAL_PASS[$g]:-0}/${GOAL_TOTAL[$g]:-0} | ${GOAL_TITLE[$g]} |"
  done
  echo; echo "<details><summary>Failing or skipped checks</summary>"; echo
  for r in "${RESULTS[@]}"; do
    IFS=$'\t' read -r g st c d <<< "$r"
    [ "$st" = ok ] || echo "- **$g** \`$c\` — $st: $d"
  done
  echo; echo "</details>"
else
  printf '%-4s %-6s %-7s %s\n' GOAL STATUS CHECKS TITLE
  for g in "${GOALS[@]}"; do
    [ -z "$ONLY_GOAL" ] || [ "$g" = "$ONLY_GOAL" ] || continue
    s=$(goal_status "$g"); [ "$s" = pass ] || ALL_PASS=0
    printf '%-4s %-6s %-7s %s\n' "$g" "$s" "${GOAL_PASS[$g]:-0}/${GOAL_TOTAL[$g]:-0}" "${GOAL_TITLE[$g]}"
  done
  echo
  for r in "${RESULTS[@]}"; do
    IFS=$'\t' read -r g st c d <<< "$r"
    [ "$st" = ok ] || printf '  %s %-4s %-5s %s — %s\n' "$([ "$st" = fail ] && echo ✗ || echo ~)" "$g" "$st" "$c" "$d"
  done
fi

# ---------------------------------------------------------------------------
# Update the tracking issue: tick goal lines and closed-issue rows.
# ---------------------------------------------------------------------------
# Rewrite TRACKING_BODY line by line: goal rows from GOAL_BOX, issue rows from ISSUE_BOX,
# and the stamp line (appended when absent). Pure bash, so a missing tool cannot blank it.
render_body() {
  local line seen=0 re_goal='^- \[[ x]\] (G[0-9]+):' re_issue='^- \[[ x]\] #([0-9]+)([^0-9]|$)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ $re_goal ]] && [ -n "${GOAL_BOX[${BASH_REMATCH[1]}]:-}" ]; then
      line="- [${GOAL_BOX[${BASH_REMATCH[1]}]}]${line:5}"
    elif [[ "$line" =~ $re_issue ]] && [ -n "${ISSUE_BOX[${BASH_REMATCH[1]}]:-}" ]; then
      line="- [${ISSUE_BOX[${BASH_REMATCH[1]}]}]${line:5}"
    elif [[ "$line" == "_Last roadmap-check:"* ]]; then
      line="$stamp"; seen=1
    fi
    printf '%s\n' "$line"
  done <<< "$TRACKING_BODY"
  [ "$seen" -eq 1 ] || printf '\n%s\n' "$stamp"
}

if [ "$UPDATE" -eq 1 ]; then
  if [ "$GH_OK" -ne 1 ]; then echo "cannot update #$ISSUE: gh unavailable" >&2; exit 2; fi
  declare -A GOAL_BOX=() ISSUE_BOX=()
  for g in "${GOALS[@]}"; do
    [ -z "$ONLY_GOAL" ] || [ "$g" = "$ONLY_GOAL" ] || continue
    s=$(goal_status "$g")
    GOAL_BOX[$g]=$([ "$s" = pass ] && echo x || echo ' ')
  done
  for n in "${!ISSUE_STATE[@]}"; do
    case "${ISSUE_STATE[$n]}" in CLOSED) ISSUE_BOX[$n]=x ;; OPEN) ISSUE_BOX[$n]=' ' ;; esac
  done
  stamp="_Last roadmap-check: $(date -u +%Y-%m-%dT%H:%MZ) · $(git rev-parse --short HEAD)_"
  new=$(render_body) && [ -n "$new" ] || { echo "cannot update #$ISSUE: body transformation failed" >&2; exit 2; }
  if [ "$new" != "$TRACKING_BODY" ]; then
    gh issue edit "$ISSUE" --body "$new" >/dev/null && echo "updated #$ISSUE" || { echo "failed to update #$ISSUE" >&2; exit 2; }
  else
    echo "#$ISSUE unchanged"
  fi
fi

[ "$ALL_PASS" -eq 1 ] && exit 0 || exit 1
