#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_DIR="$ROOT_DIR/docs/tasks"
README_TASKS="$TASK_DIR/README.md"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need jq

# Refuse to run as a silent no-op: both markers must exist in the README.
for marker in '<!-- tasks-moc:start -->' '<!-- tasks-moc:end -->'; do
  if ! grep -qF "$marker" "$README_TASKS"; then
    echo "Missing marker $marker in $README_TASKS; nothing updated" >&2
    exit 1
  fi
done

tmp_json=$(mktemp)
tmp_out=$(mktemp)

state_dirs=(backlog active complete)

printf '[' >"$tmp_json"
first=1
for state in "${state_dirs[@]}"; do
  dir="$TASK_DIR/$state"
  [ -d "$dir" ] || continue
  shopt -s nullglob
  for f in "$dir"/*.md; do
    json=$(cat "$f") || continue
    id=$(printf '%s' "$json" | jq -r '.id // empty' || true)
    name=$(printf '%s' "$json" | jq -r '.name // empty' || true)
    ms=$(printf '%s' "$json" | jq -r '.milestone // empty' || true)
    [ -n "$id" ] || continue
    [ -n "$ms" ] || ms="Unknown"
    # Links are rendered inside docs/tasks/README.md, so emit paths relative to docs/tasks/.
    path="${f#"$TASK_DIR"/}"
    if [ $first -eq 0 ]; then printf ',' >>"$tmp_json"; fi
    first=0
    printf '{' >>"$tmp_json"
    printf '"id":%s,"name":%s,"milestone":%s,"state":%s,"path":%s' \
      "$(jq -Rn --arg v "$id" '$v')" \
      "$(jq -Rn --arg v "$name" '$v')" \
      "$(jq -Rn --arg v "$ms" '$v')" \
      "$(jq -Rn --arg v "$state" '$v')" \
      "$(jq -Rn --arg v "$path" '$v')" >>"$tmp_json"
    printf '}' >>"$tmp_json"
  done
  shopt -u nullglob
done
printf ']\n' >>"$tmp_json"

for ms in MVP Alpha Beta "v1.0.0" HOTFIX; do
  heading="$ms"
  [ "$ms" = "HOTFIX" ] && heading="HOTFIX (unscored)"
  printf '### %s\n\n' "$heading" >>"$tmp_out"
  for st in backlog active complete; do
    count=$(jq --arg ms "$ms" --arg st "$st" -r '[ .[] | select(.milestone==$ms and .state==$st) ] | length' "$tmp_json")
    if [ "$count" -gt 0 ]; then
      # Capitalize state name for label
      label="$(printf '%s' "$st" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"
      printf -- '- %s:\n' "$label" >>"$tmp_out"
      jq --arg ms "$ms" --arg st "$st" -r '.[] | select(.milestone==$ms and .state==$st) | "  - [\(.id) — \(.name)](\(.path))"' "$tmp_json" >>"$tmp_out"
    fi
  done
  printf '\n' >>"$tmp_out"
done

# Replace block between markers in README
awk -v cf="$tmp_out" '
  BEGIN{inblk=0}
  /<!-- tasks-moc:start -->/ {print; while ((getline line < cf) > 0) print line; close(cf); inblk=1; next}
  /<!-- tasks-moc:end -->/ {print; inblk=0; next}
  inblk==0 {print}
' "$README_TASKS" >"$README_TASKS.tmp"
mv "$README_TASKS.tmp" "$README_TASKS"

rm -f "$tmp_json" "$tmp_out"
echo "Updated Milestone MoC in $README_TASKS"
