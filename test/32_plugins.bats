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
