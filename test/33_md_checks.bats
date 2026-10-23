#!/usr/bin/env bats
#
# scripts/dev/check-md-fences.sh and scripts/dev/check-md-links.sh (#150).
# Each check has a positive control (a seeded defect must fail) next to the
# clean case, so a checker that silently checks nothing cannot pass here.

FENCES="$BATS_TEST_DIRNAME/../scripts/dev/check-md-fences.sh"
LINKS="$BATS_TEST_DIRNAME/../scripts/dev/check-md-links.sh"
FENCE='```'

setup() {
  WORK="$BATS_TEST_TMPDIR/docs"
  mkdir -p "$WORK"
  cd "$WORK"
  git init -q
}

@test "md checks: the shipped tree has balanced fences and resolvable links" {
  cd "$BATS_TEST_DIRNAME/.."
  # The suite's copy of the checkout may be owned by another uid (CI mounts).
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
  run bash "$FENCES"
  [ "$status" -eq 0 ]
  run bash "$LINKS"
  [ "$status" -eq 0 ]
}
