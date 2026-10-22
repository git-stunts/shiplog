#!/usr/bin/env bats

load helpers/common

setup() {
  shiplog_standard_setup
  mkdir -p .shiplog/plugins/pre-commit-message.d
  cat <<'PLUGIN' > .shiplog/plugins/pre-commit-message.d/10-scrub.sh
#!/usr/bin/env bash
set -euo pipefail

awk '{ gsub(/password=[^ ]+/, "password=[REDACTED]"); print }'
PLUGIN
  chmod +x .shiplog/plugins/pre-commit-message.d/10-scrub.sh
}

teardown() {
  shiplog_standard_teardown
}

@test "pre-commit message plugins can scrub secrets" {
  export SHIPLOG_SERVICE="web"
  export SHIPLOG_STATUS="success"
  export SHIPLOG_REASON="deploy password=supersecret"
  export SHIPLOG_TICKET="OPS-100"
  export SHIPLOG_AUTO_PUSH=0

  run git shiplog --yes write
  [ "$status" -eq 0 ]

  ref="${SHIPLOG_REF_ROOT:-refs/_shiplog}/journal/prod"
  commit="$(git rev-parse "$ref")"
  message="$(git show -s --format=%B "$commit")"
  [[ "$message" != *"password=supersecret"* ]]
  [[ "$message" == *"password=[REDACTED]"* ]]
}

# --- SLT.BUG.LIB.009 (#143): discovery rule and trailer guard ---------------

@test "plugins run regardless of file name (executable regular files)" {
  rm -f .shiplog/plugins/pre-commit-message.d/10-scrub.sh
  cat <<'PLUGIN' > .shiplog/plugins/pre-commit-message.d/10-scrub
#!/usr/bin/env bash
set -euo pipefail
awk '/^---  # structured trailer for machines$/ && !done { print "X-Plugin: ran"; done = 1 } { print }'
PLUGIN
  chmod +x .shiplog/plugins/pre-commit-message.d/10-scrub
  # Non-executable files are not plugins.
  printf '#!/bin/sh\nexit 1\n' > .shiplog/plugins/pre-commit-message.d/20-not-executable
  export SHIPLOG_SERVICE="web"
  export SHIPLOG_STATUS="success"
  export SHIPLOG_REASON="plugin discovery"
  export SHIPLOG_AUTO_PUSH=0

  run git shiplog --yes write
  [ "$status" -eq 0 ]

  ref="${SHIPLOG_REF_ROOT:-refs/_shiplog}/journal/prod"
  message="$(git show -s --format=%B "$ref")"
  [[ "$message" == *"X-Plugin: ran"* ]]
  run git shiplog validate-trailer "$ref"
  [ "$status" -eq 0 ]
}

@test "symlinked plugins run when they resolve inside the plugins directory" {
  mkdir -p .shiplog/plugins/common
  mv .shiplog/plugins/pre-commit-message.d/10-scrub.sh .shiplog/plugins/common/scrub.sh
  ln -s ../common/scrub.sh .shiplog/plugins/pre-commit-message.d/10-scrub
  export SHIPLOG_SERVICE="web"
  export SHIPLOG_STATUS="success"
  export SHIPLOG_REASON="deploy password=supersecret"
  export SHIPLOG_AUTO_PUSH=0

  run git shiplog --yes write
  [ "$status" -eq 0 ]

  ref="${SHIPLOG_REF_ROOT:-refs/_shiplog}/journal/prod"
  message="$(git show -s --format=%B "$ref")"
  [[ "$message" != *"password=supersecret"* ]]
  [[ "$message" == *"password=[REDACTED]"* ]]
}

@test "symlinked plugins that resolve outside the plugins directory are ignored" {
  local outside
  outside=$(mktemp)
  printf '#!/bin/sh\nexit 1\n' > "$outside"
  chmod +x "$outside"
  ln -s "$outside" .shiplog/plugins/pre-commit-message.d/05-outside
  export SHIPLOG_SERVICE="web"
  export SHIPLOG_STATUS="success"
  export SHIPLOG_REASON="traversal"
  export SHIPLOG_AUTO_PUSH=0

  run git shiplog --yes write
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring plugin outside plugins dir"* ]]
  rm -f "$outside"
}

@test "a plugin that exits 0 with no output aborts the write" {
  cat <<'PLUGIN' > .shiplog/plugins/pre-commit-message.d/20-empty
#!/usr/bin/env bash
exit 0
PLUGIN
  chmod +x .shiplog/plugins/pre-commit-message.d/20-empty
  export SHIPLOG_SERVICE="web"
  export SHIPLOG_STATUS="success"
  export SHIPLOG_REASON="empty plugin"
  export SHIPLOG_AUTO_PUSH=0

  run git shiplog --yes write
  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin 20-empty removed the structured trailer"* ]]
  run git show-ref "${SHIPLOG_REF_ROOT:-refs/_shiplog}/journal/prod"
  [ "$status" -ne 0 ]
}

@test "a plugin that drops the JSON trailer aborts the write" {
  cat <<'PLUGIN' > .shiplog/plugins/pre-commit-message.d/30-truncate
#!/usr/bin/env bash
set -euo pipefail
awk '/^---  # structured trailer for machines$/ { exit } { print }'
PLUGIN
  chmod +x .shiplog/plugins/pre-commit-message.d/30-truncate
  export SHIPLOG_SERVICE="web"
  export SHIPLOG_STATUS="success"
  export SHIPLOG_REASON="truncating plugin"
  export SHIPLOG_AUTO_PUSH=0

  run git shiplog --yes write
  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin 30-truncate removed the structured trailer"* ]]
}
