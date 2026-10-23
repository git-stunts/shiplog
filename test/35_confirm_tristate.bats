#!/usr/bin/env bats
# shiplog_confirm honors "no" (#157): bosun confirm exit 1 aborts, exit 2 falls
# back to the plain prompt, and bosun's stdout never leaks into the CLI output.

load helpers/common

REF_ROOT=${SHIPLOG_REF_ROOT:-refs/_shiplog}

setup() {
  shiplog_standard_setup
  git shiplog init >/dev/null
  export SHIPLOG_SIGN=0
  export SHIPLOG_AUTO_PUSH=0
  export SHIPLOG_SERVICE="web"
  export SHIPLOG_STATUS="success"
  export SHIPLOG_REASON="confirm test"
  export SHIPLOG_TICKET="OPS-157"
  export SHIPLOG_REGION="us-west-2"
  export SHIPLOG_CLUSTER="prod-1"
  export SHIPLOG_NAMESPACE="pf3"
  export SHIPLOG_IMAGE="ghcr.io/example/web"
  export SHIPLOG_TAG="test.1"
  unset SHIPLOG_ASSUME_YES SHIPLOG_BORING

  STUB_DIR="$(mktemp -d)"
  export STUB_DIR
  # A stand-in for bosun: answers input/choose with their defaults, passes
  # spin/style through, and lets the test pick confirm's exit code. It always
  # writes a marker to stdout so a leak into the CLI's stdout is detectable.
  cat > "$STUB_DIR/bosun" <<'STUB'
#!/usr/bin/env bash
cmd="${1:-}"; shift || true
case "$cmd" in
  confirm)
    echo "STUB_BOSUN_STDOUT_LEAK"
    exit "${STUB_CONFIRM_RC:-2}"
    ;;
  input)
    val=""
    while [ $# -gt 0 ]; do
      case "$1" in --value|--default) val="${2:-}"; shift ;; esac
      shift
    done
    printf '%s\n' "$val"
    ;;
  choose)
    def=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --default) def="${2:-}"; shift ;;
        --header) shift ;;
        --json|--no-color) ;;
        *) break ;;
      esac
      shift
    done
    printf '%s\n' "${def:-${1:-}}"
    ;;
  spin)
    while [ $# -gt 0 ]; do
      case "$1" in --) shift; break ;; esac
      shift
    done
    "$@"
    ;;
  style)
    while [ $# -gt 0 ]; do
      case "$1" in --) shift; break ;; --title|--width) shift ;; esac
      shift
    done
    printf '%s\n' "$*"
    ;;
  table) cat ;;
  *) exit 64 ;;
esac
STUB
  chmod +x "$STUB_DIR/bosun"
}

teardown() {
  unset SHIPLOG_SERVICE SHIPLOG_STATUS SHIPLOG_REASON SHIPLOG_TICKET
  unset SHIPLOG_REGION SHIPLOG_CLUSTER SHIPLOG_NAMESPACE SHIPLOG_IMAGE SHIPLOG_TAG
  unset SHIPLOG_AUTO_PUSH SHIPLOG_SIGN
  [ -n "${STUB_DIR:-}" ] && rm -rf "$STUB_DIR"
  shiplog_standard_teardown
}

journal_exists() {
  git rev-parse -q --verify "${REF_ROOT}/journal/prod" >/dev/null 2>&1
}

@test "bosun confirm exit 1 (no) aborts the write even when stdin holds a 'y'" {
  run bash -c "printf 'y\n' | env SHIPLOG_BOSUN_BIN='$STUB_DIR/bosun' STUB_CONFIRM_RC=1 git shiplog write"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Aborted."* ]]
  [[ "$output" != *"[y/N]"* ]]
  [[ "$output" != *"STUB_BOSUN_STDOUT_LEAK"* ]]
  ! journal_exists
}

@test "bosun confirm exit 2 (cannot prompt) falls back to the plain prompt; piped 'y' proceeds" {
  run bash -c "printf 'y\n' | env SHIPLOG_BOSUN_BIN='$STUB_DIR/bosun' STUB_CONFIRM_RC=2 git shiplog write"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[y/N]"* ]]
  [[ "$output" != *"STUB_BOSUN_STDOUT_LEAK"* ]]
  journal_exists
}

@test "bosun confirm exit 2 (cannot prompt) falls back to the plain prompt; piped 'n' aborts" {
  run bash -c "printf 'n\n' | env SHIPLOG_BOSUN_BIN='$STUB_DIR/bosun' STUB_CONFIRM_RC=2 git shiplog write"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Aborted."* ]]
  ! journal_exists
}

@test "bosun confirm exit 0 (yes) proceeds without a second prompt" {
  run bash -c "env SHIPLOG_BOSUN_BIN='$STUB_DIR/bosun' STUB_CONFIRM_RC=0 git shiplog write </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" != *"[y/N]"* ]]
  [[ "$output" != *"STUB_BOSUN_STDOUT_LEAK"* ]]
  journal_exists
}
