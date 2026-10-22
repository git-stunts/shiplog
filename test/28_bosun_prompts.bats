#!/usr/bin/env bats
# Bosun prompt primitives: TTY detection when stdout is captured (#108),
# tri-state confirm (#157), empty table cells (#131), docs/code flag lint (#145).
#
# Pty cases drive bosun through util-linux `script` so stdin is a real terminal
# while stdout is captured by $(...) exactly as lib/common.sh does. They skip
# when `script` is not installed (some matrix images).

load helpers/common

setup() {
  BOSUN="${SHIPLOG_BOSUN_BIN:-${SHIPLOG_HOME:-$SHIPLOG_PROJECT_ROOT}/scripts/bosun}"
  [ -x "$BOSUN" ] || { echo "bosun not executable at $BOSUN" >&2; return 1; }
  WORK="$(mktemp -d)"
  export BOSUN WORK
  unset BOSUN_FORCE_TTY
}

teardown() {
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}

# Run CMD_FILE inside a pseudo-terminal, feeding INPUT on the terminal's stdin
# after a short delay so the prompt is already waiting on read(2).
run_in_pty() {
  local cmd_file="$1" input="$2"
  command -v script >/dev/null 2>&1 || skip "util-linux script not available in this image"
  chmod +x "$cmd_file"
  run bash -c "{ sleep 0.5; printf '%s\n' '$input'; } | timeout 30 script -q -c '$cmd_file' /dev/null > '$WORK/typescript' 2>&1"
  [ "$status" -eq 0 ] || { echo "script exited $status; typescript:" >&2; cat "$WORK/typescript" >&2; return 1; }
}

# ---- #108: non-TTY contract unchanged ----------------------------------------

@test "input: non-TTY empty stdin returns the default" {
  run bash -c "printf '' | '$BOSUN' input --value d"
  [ "$status" -eq 0 ]
  [ "$output" = "d" ]
}

@test "input: non-TTY closed stdin returns the default" {
  run bash -c "'$BOSUN' input --placeholder Ticket --value UNKNOWN --json </dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = '{"value":"UNKNOWN"}' ]
}

@test "input: non-TTY piped data is read" {
  run bash -c "printf 'typed\n' | '$BOSUN' input --value d"
  [ "$status" -eq 0 ]
  [ "$output" = "typed" ]
}

@test "choose: non-TTY returns the default without rendering a menu" {
  run bash -c "'$BOSUN' choose --header Env --default stage dev stage prod </dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "stage" ]
}

# ---- #108: pty — prompts render on the terminal, captured stdout stays clean ---

@test "input: under a pty with stdout captured, prompt renders and the typed value is returned" {
  cat > "$WORK/inner.sh" <<EOF
#!/usr/bin/env bash
out=\$("$BOSUN" input --no-color --placeholder PLACEHOLDER_MARK --value dflt)
printf '%s' "\$out" > "$WORK/out.txt"
EOF
  run_in_pty "$WORK/inner.sh" "typed"
  [ "$(cat "$WORK/out.txt")" = "typed" ]
  grep -q "PLACEHOLDER_MARK" "$WORK/typescript"
}

@test "choose: under a pty with stdout captured, menu renders and the selection is returned" {
  cat > "$WORK/inner.sh" <<EOF
#!/usr/bin/env bash
out=\$("$BOSUN" choose --no-color --header HEADER_MARK dev stage prod)
printf '%s' "\$out" > "$WORK/out.txt"
EOF
  run_in_pty "$WORK/inner.sh" "2"
  [ "$(cat "$WORK/out.txt")" = "stage" ]
  grep -q "HEADER_MARK" "$WORK/typescript"
  grep -q "2) stage" "$WORK/typescript"
}

@test "confirm: under a pty, 'n' exits 1 with 'no' on stdout and the prompt on the terminal" {
  cat > "$WORK/inner.sh" <<EOF
#!/usr/bin/env bash
"$BOSUN" confirm --no-color "CONFIRM_MARK?" > "$WORK/out.txt"
printf '%s' "\$?" > "$WORK/rc.txt"
EOF
  run_in_pty "$WORK/inner.sh" "n"
  [ "$(cat "$WORK/rc.txt")" = "1" ]
  [ "$(cat "$WORK/out.txt")" = "no" ]
  grep -q "CONFIRM_MARK? \[y/N\]" "$WORK/typescript"
  ! grep -q "CONFIRM_MARK" "$WORK/out.txt"
}

@test "confirm: under a pty, 'y' exits 0 with 'yes' on stdout" {
  cat > "$WORK/inner.sh" <<EOF
#!/usr/bin/env bash
"$BOSUN" confirm --no-color "Go?" > "$WORK/out.txt"
printf '%s' "\$?" > "$WORK/rc.txt"
EOF
  run_in_pty "$WORK/inner.sh" "y"
  [ "$(cat "$WORK/rc.txt")" = "0" ]
  [ "$(cat "$WORK/out.txt")" = "yes" ]
}

# ---- #157: tri-state confirm -------------------------------------------------

@test "confirm: non-TTY without --default-yes exits 2 and prints nothing on stdout" {
  run bash -c "printf 'y\n' | '$BOSUN' confirm Q 2>/dev/null"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run bash -c "printf 'y\n' | '$BOSUN' confirm Q 2>&1 >/dev/null"
  [[ "$output" == *"no terminal available"* ]]
}

@test "confirm: non-TTY --json exits 2 with ok:null" {
  run bash -c "'$BOSUN' confirm --json Q </dev/null 2>/dev/null"
  [ "$status" -eq 2 ]
  [ "$output" = '{"ok":null}' ]
}

@test "confirm: non-TTY --default-yes exits 0 with yes" {
  run bash -c "'$BOSUN' confirm --default-yes Q </dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "yes" ]
}

@test "confirm: --yes exits 0 without a terminal" {
  run bash -c "'$BOSUN' confirm --yes --json Q </dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
}

# ---- #131: table accepts empty cells ------------------------------------------

@test "table: consecutive tabs are an empty middle cell" {
  run bash -c "printf 'a\t\tc\n' | '$BOSUN' table --no-color --columns 'A,B,C'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "A  B  C" ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[2]}" = "a     c" ]
}

@test "table: leading tab is an empty first cell" {
  run bash -c "printf '\tb\tc\n' | '$BOSUN' table --no-color --columns 'A,B,C'"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[2]}" = "   b  c" ]
}

@test "table: trailing tab is an empty last cell" {
  run bash -c "printf 'a\tb\t\n' | '$BOSUN' table --no-color --columns 'A,B,C'"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[2]}" == "a  b"* ]]
}

@test "table: a row with too few cells still exits 3" {
  run bash -c "printf 'a\tb\n' | '$BOSUN' table --no-color --columns 'A,B,C'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"row has 2 columns but expected 3"* ]]
}

@test "table: --rows-file with empty cells renders" {
  printf 'web\t\tready\n' > "$WORK/rows.tsv"
  run "$BOSUN" table --no-color --columns 'Svc,Ticket,Status' --rows-file "$WORK/rows.tsv"
  [ "$status" -eq 0 ]
  # "web" + 2 gap + 6 blank (Ticket) + 2 gap + "ready" padded to 6
  local expected
  expected="web$(printf '%10s' '')ready"
  [[ "${lines[2]}" == "$expected"* ]]
}

# ---- #145: docs match code ----------------------------------------------------

@test "check-bosun-docs.sh: docs/bosun agree with scripts/bosun" {
  local root="${SHIPLOG_HOME:-$SHIPLOG_PROJECT_ROOT}"
  run bash "$root/scripts/dev/check-bosun-docs.sh" --bosun "$BOSUN" --docs "$root/docs/bosun"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agree"* ]]
}

@test "check-bosun-docs.sh: a documented flag the code lacks fails the lint" {
  local root="${SHIPLOG_HOME:-$SHIPLOG_PROJECT_ROOT}"
  cp -R "$root/docs/bosun" "$WORK/docs"
  printf '\n- `--bogus-flag` is not real.\n' >> "$WORK/docs/table.md"
  run bash "$root/scripts/dev/check-bosun-docs.sh" --bosun "$BOSUN" --docs "$WORK/docs"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--bogus-flag"* ]]
}

@test "check-bosun-docs.sh: a code flag the docs lack fails the lint" {
  local root="${SHIPLOG_HOME:-$SHIPLOG_PROJECT_ROOT}"
  cp -R "$root/docs/bosun" "$WORK/docs"
  sed -i.bak '/--rows-file/d' "$WORK/docs/table.md"
  run bash "$root/scripts/dev/check-bosun-docs.sh" --bosun "$BOSUN" --docs "$WORK/docs"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--rows-file"*"not documented"* ]]
}
