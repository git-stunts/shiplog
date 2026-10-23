#!/usr/bin/env bats
# G7b: CLI parsing and read commands (#101 #117 #119 #124 #125 #139).
# Every test name starts with "g7b" so the group can be selected with
# DOCKER_RUN_OPTS='-e BATS_FLAGS="-f g7b"' make test.

load helpers/common

REF_ROOT=${SHIPLOG_REF_ROOT:-refs/_shiplog}

setup() {
  shiplog_standard_setup
  git shiplog init >/dev/null
  export SHIPLOG_SIGN=0
  export SHIPLOG_AUTO_PUSH=0
  export SHIPLOG_BORING=1
  export SHIPLOG_ASSUME_YES=1
  export SHIPLOG_SERVICE="cli"
  export SHIPLOG_STATUS="success"
  export SHIPLOG_REASON="cli parsing"
  export SHIPLOG_REGION="us"
  export SHIPLOG_CLUSTER="c1"
  export SHIPLOG_NAMESPACE="ns"
  REMOTE_DIR=""
}

teardown() {
  if [ -n "${REMOTE_DIR:-}" ]; then
    rm -rf -- "$REMOTE_DIR" 2>/dev/null || true
  fi
  shiplog_standard_teardown
  unset SHIPLOG_SIGN SHIPLOG_AUTO_PUSH SHIPLOG_BORING SHIPLOG_ASSUME_YES
  unset SHIPLOG_SERVICE SHIPLOG_STATUS SHIPLOG_REASON SHIPLOG_REGION SHIPLOG_CLUSTER SHIPLOG_NAMESPACE
}

make_bare_origin() {
  REMOTE_DIR=$(mktemp -d)
  git remote remove origin >/dev/null 2>&1 || true
  git init -q --bare "$REMOTE_DIR"
  git remote add origin "$REMOTE_DIR"
}

line_count() {
  printf '%s\n' "$1" | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# #119 per-command --help
# ---------------------------------------------------------------------------

@test "g7b help: write --help prints the write usage, not the global one" {
  run git shiplog write --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: git shiplog write"* ]]
  [[ "$output" == *"--run-url"* ]]
  [[ "$output" != *"Global Options:"* ]]
}

@test "g7b help: global --help before the command still prints the global usage" {
  # `git shiplog --help` never reaches the script: Git rewrites `git <cmd> --help`
  # into `git help <cmd>` (a man page lookup). Call the binary directly for that
  # spelling; `-h` is not intercepted by Git.
  run git-shiplog --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Global Options:"* ]]
  run git shiplog -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Global Options:"* ]]
  run git shiplog --boring --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Global Options:"* ]]
  # `--` before the command only ends global flag parsing
  run git shiplog -- ls --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: git shiplog ls"* ]]
}

@test "g7b help: every subcommand exits 0 on --help and -h" {
  local cmd flag
  for cmd in write append publish setup config "trust show" "trust sync" trust run ls show policy verify export-json validate-trailer refs "refs root" init; do
    for flag in --help -h; do
      # shellcheck disable=SC2086
      run git shiplog $cmd $flag
      if [ "$status" -ne 0 ]; then
        echo "git shiplog $cmd $flag exited $status: $output" >&2
        return 1
      fi
      if [[ "$output" != *"Usage"* ]]; then
        echo "git shiplog $cmd $flag printed no usage: $output" >&2
        return 1
      fi
    done
  done
  # help never creates journals
  run git for-each-ref "${REF_ROOT}/journal/" --format='%(refname)'
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# #117 write rejects unknown flags and bad env names
# ---------------------------------------------------------------------------

@test "g7b write: an unknown flag dies and creates no journal" {
  run git shiplog write --log /tmp/x
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown write option: --log"* ]]
  run git shiplog write --servce web
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown write option: --servce"* ]]
  run git for-each-ref "${REF_ROOT}/journal/" --format='%(refname)'
  [ -z "$output" ]
}

@test "g7b write: invalid environment names are rejected" {
  local bad
  for bad in 'bad env' 'a..b' 'trailing.lock' 'with~tilde' 'slash/'; do
    run git shiplog write "$bad"
    if [ "$status" -eq 0 ]; then
      echo "write accepted env '$bad'" >&2
      return 1
    fi
    [[ "$output" == *"invalid environment name"* ]]
  done
  # A leading dash is caught by the flag parser first (unknown option), and the
  # validator rejects it as an env name when it arrives through --env.
  run git shiplog write -leading
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown write option: -leading"* ]]
  run git shiplog write --env=-leading
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid environment name '-leading'"* ]]
  run git for-each-ref "${REF_ROOT}/journal/" --format='%(refname)'
  [ -z "$output" ]
}

@test "g7b write: positional ENV wins over --env and a second positional is rejected" {
  run git shiplog write staging extra
  [ "$status" -ne 0 ]
  [[ "$output" == *"single ENV"* ]]
  run git shiplog write --env qa staging
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet "${REF_ROOT}/journal/staging" >/dev/null
  run git rev-parse --verify --quiet "${REF_ROOT}/journal/qa"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# #139 A missing flag values
# ---------------------------------------------------------------------------

@test "g7b flags: a value-taking flag without a value dies with a message" {
  run git shiplog append --service api --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"--json requires a value"* ]]
  run git shiplog write --service
  [ "$status" -ne 0 ]
  [[ "$output" == *"--service requires a value"* ]]
  run git shiplog run --reason
  [ "$status" -ne 0 ]
  [[ "$output" == *"--reason requires a value"* ]]
  run git shiplog publish --env
  [ "$status" -ne 0 ]
  [[ "$output" == *"--env requires a value"* ]]
  run git shiplog config --answers-file
  [ "$status" -ne 0 ]
  [[ "$output" == *"--answers-file requires a value"* ]]
  run git for-each-ref "${REF_ROOT}/journal/" --format='%(refname)'
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# #139 B show flags in any position
# ---------------------------------------------------------------------------

@test "g7b show: flags after the target are honored and unknown flags die" {
  git shiplog write >/dev/null
  local sha
  sha=$(git rev-parse "${REF_ROOT}/journal/prod")
  run git shiplog show "$sha" --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.seq' >/dev/null
  run git shiplog show "$sha" --jsonl
  [ "$status" -eq 0 ]
  [ "$(line_count "$output")" -eq 1 ]
  printf '%s\n' "$output" | jq -e '.seq' >/dev/null
  run git shiplog show --bogus "$sha"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown show option: --bogus"* ]]
  run git shiplog show "$sha" "$sha"
  [ "$status" -ne 0 ]
  [[ "$output" == *"single COMMIT|REF"* ]]
}

# ---------------------------------------------------------------------------
# #139 C run -- <command starting with ->
# ---------------------------------------------------------------------------

@test "g7b run: a wrapped command may start with a dash (run -- --help)" {
  # The wrapped command fails (there is no program named --help); the entry is
  # still recorded with the real argv instead of --help being taken as run help.
  run git shiplog run --service t -- --help
  [[ "$output" != *"Usage: git shiplog run"* ]]
  local sha
  sha=$(git rev-parse "${REF_ROOT}/journal/prod")
  run bash -lc "git shiplog show --json $sha | jq -r '.run.argv[0]'"
  [ "$status" -eq 0 ]
  [ "$output" = "--help" ]
}

# ---------------------------------------------------------------------------
# #139 D setup flags beat SHIPLOG_SETUP_AUTO_PUSH
# ---------------------------------------------------------------------------

@test "g7b setup: --no-auto-push beats SHIPLOG_SETUP_AUTO_PUSH=1" {
  make_bare_origin
  run env SHIPLOG_SETUP_AUTO_PUSH=1 git shiplog setup --strictness open --no-auto-push
  [ "$status" -eq 0 ]
  run git --git-dir="$REMOTE_DIR" rev-parse --verify --quiet refs/_shiplog/policy/current
  [ "$status" -ne 0 ]
  # Without a flag the environment default still applies
  run env SHIPLOG_SETUP_AUTO_PUSH=1 git shiplog setup --strictness open
  [ "$status" -eq 0 ]
  run git --git-dir="$REMOTE_DIR" rev-parse --verify --quiet refs/_shiplog/policy/current
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# #139 E BSD-safe tab expansion in the workflow emitter
# ---------------------------------------------------------------------------

@test "g7b config: the emitted GitHub workflow keeps every letter t and no tabs" {
  local fake_home
  fake_home=$(mktemp -d)
  mkdir -p "$fake_home/docs/examples/github"
  printf 'steps:\n\t- name: test step\n' > "$fake_home/docs/examples/github/workflow-shiplog-verify.yml"
  # Bosun rendering is the path that expands tabs, so this run is not boring.
  run env SHIPLOG_BORING=0 SHIPLOG_HOME="$fake_home" SHIPLOG_LIB_DIR="${SHIPLOG_LIB_DIR:-$SHIPLOG_PROJECT_ROOT/lib}" \
    git shiplog config --emit-github-workflow
  rm -rf "$fake_home"
  [ "$status" -eq 0 ]
  [[ "$output" == *"steps:"* ]]
  [[ "$output" == *"  - name: test step"* ]]
  [[ "$output" != *"s  eps"* ]]
  [[ "$output" != *$'\t'* ]]
}

# ---------------------------------------------------------------------------
# #101 publish [ENV]
# ---------------------------------------------------------------------------

@test "g7b publish: positional ENV is published and a second positional is rejected" {
  make_bare_origin
  run git shiplog write staging
  [ "$status" -eq 0 ]
  run git shiplog publish staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"journal/staging"* ]]
  run git --git-dir="$REMOTE_DIR" for-each-ref 'refs/_shiplog/journal/staging' --format='%(refname)'
  [[ "$output" == *"refs/_shiplog/journal/staging"* ]]
  run git --git-dir="$REMOTE_DIR" for-each-ref 'refs/_shiplog/journal/prod' --format='%(refname)'
  [ -z "$output" ]
  run git shiplog publish staging extra
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: git shiplog publish"* ]]
  run git shiplog publish --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown publish option: --bogus"* ]]
}

@test "g7b publish: positional ENV beats --env and SHIPLOG_ENV" {
  make_bare_origin
  git shiplog write staging >/dev/null
  git shiplog write qa >/dev/null
  run env SHIPLOG_ENV=qa git shiplog publish --env qa staging
  [ "$status" -eq 0 ]
  run git --git-dir="$REMOTE_DIR" for-each-ref 'refs/_shiplog/journal/' --format='%(refname)'
  [[ "$output" == *"refs/_shiplog/journal/staging"* ]]
  [[ "$output" != *"refs/_shiplog/journal/qa"* ]]
}

# ---------------------------------------------------------------------------
# #124 verify fails on a missing journal
# ---------------------------------------------------------------------------

@test "g7b verify: a missing journal is an error that names the ref" {
  run git shiplog verify does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"${REF_ROOT}/journal/does-not-exist"* ]]
  [[ "$output" != *"OK=0"* ]]
}

@test "g7b verify: an existing journal verifies; extra args and unknown flags die" {
  git shiplog write >/dev/null
  run git shiplog verify prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK=1"* ]]
  run git shiplog verify prod extra
  [ "$status" -ne 0 ]
  [[ "$output" == *"single ENV"* ]]
  run git shiplog verify --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown verify option: --bogus"* ]]
}

# ---------------------------------------------------------------------------
# #125 export-json emits one line per entry
# ---------------------------------------------------------------------------

@test "g7b export-json: one line per entry, malformed trailers flagged, exit 3 unless --lenient" {
  git shiplog write >/dev/null
  local a b c tree msg
  a=$(git rev-parse "${REF_ROOT}/journal/prod")
  tree=$(git rev-parse "$a^{tree}")
  # B: a raw commit whose trailer is not JSON
  b=$(printf 'bad entry\n\n---\n{not json' | git commit-tree "$tree" -p "$a")
  git update-ref "${REF_ROOT}/journal/prod" "$b" "$a"
  # C: a raw commit that reuses A's valid message
  msg=$(git show -s --format=%B "$a")
  c=$(printf '%s\n' "$msg" | git commit-tree "$tree" -p "$b")
  git update-ref "${REF_ROOT}/journal/prod" "$c" "$b"

  run bash -c 'git shiplog export-json 2>/dev/null'
  [ "$status" -eq 3 ]
  [ "$(line_count "$output")" -eq 3 ]
  local line1 line2 line3
  line1=$(printf '%s\n' "$output" | sed -n 1p)
  line2=$(printf '%s\n' "$output" | sed -n 2p)
  line3=$(printf '%s\n' "$output" | sed -n 3p)
  printf '%s\n' "$line1" | jq -e --arg c "$c" '.commit == $c and .seq != null' >/dev/null
  printf '%s\n' "$line2" | jq -e --arg b "$b" '.commit == $b and .error == "invalid trailer" and .subject == "bad entry"' >/dev/null
  printf '%s\n' "$line3" | jq -e --arg a "$a" '.commit == $a and .seq != null' >/dev/null

  run bash -c 'git shiplog export-json 2>&1 >/dev/null'
  [[ "$output" == *"invalid trailer"* ]]

  run bash -c 'git shiplog export-json --lenient 2>/dev/null'
  [ "$status" -eq 0 ]
  [ "$(line_count "$output")" -eq 3 ]
}

@test "g7b export-json: a missing journal is an error and a clean journal exits 0" {
  run git shiplog export-json nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"${REF_ROOT}/journal/nope"* ]]
  git shiplog write >/dev/null
  run git shiplog export-json prod
  [ "$status" -eq 0 ]
  [ "$(line_count "$output")" -eq 1 ]
  printf '%s\n' "$output" | jq -e '.commit and .seq != null' >/dev/null
}

@test "g7b show/validate-trailer: a target starting with - is rejected, never passed to git as an option" {
  git shiplog write >/dev/null
  local out="$BATS_TEST_TMPDIR/injected.out"
  rm -f "$out"
  run git shiplog show -- "--output=$out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not start with '-'"* ]]
  [ ! -e "$out" ]
  run git shiplog show --json -- "--output=$out"
  [ "$status" -ne 0 ]
  [ ! -e "$out" ]
  run git shiplog validate-trailer -- "--output=$out"
  [ "$status" -ne 0 ]
  [ ! -e "$out" ]
  # Positive control: the default target still works
  run git shiplog show --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.seq' >/dev/null
}

# ---------------------------------------------------------------------------
# `--` after the command name reaches the subcommand; read commands accept it
# ---------------------------------------------------------------------------

@test "g7b ls/validate-trailer: -- ends options and is not an unknown option" {
  git shiplog write >/dev/null
  git shiplog write staging >/dev/null
  run git shiplog ls -- staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"staging"* ]]
  local sha
  sha=$(git rev-parse "${REF_ROOT}/journal/prod")
  run git shiplog validate-trailer -- "$sha"
  [ "$status" -eq 0 ]
  # Positive control: the same target without -- validates too
  run git shiplog validate-trailer "$sha"
  [ "$status" -eq 0 ]
}

@test "g7b ls: LIMIT must be a positive integer and extra arguments die" {
  git shiplog write >/dev/null
  run git shiplog ls prod abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"LIMIT must be a positive integer"* ]]
  run git shiplog ls prod 0
  [ "$status" -ne 0 ]
  run git shiplog ls prod 5 extra
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected argument to ls: extra"* ]]
  run git shiplog ls prod --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown ls option: --bogus"* ]]
  # Positive control
  run git shiplog ls prod 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"cli"* ]]
}
