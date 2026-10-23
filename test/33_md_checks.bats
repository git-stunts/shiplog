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

@test "md fences: an unclosed fence fails and names the file" {
  printf '# ok\n\n%sbash\necho hi\n%s\n' "$FENCE" "$FENCE" > good.md
  printf '# bad\n\n%sbash\necho never closed\n' "$FENCE" > bad.md
  git add good.md bad.md
  run bash "$FENCES"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad.md: 1 fence line(s)"* ]]
  [[ "$output" != *"good.md"* ]]
}

@test "md fences: an unclosed fence inside a blockquote fails" {
  printf '> tip\n> %sbash\n> echo hi\n\n## next\n' "$FENCE" > quote.md
  git add quote.md
  run bash "$FENCES"
  [ "$status" -eq 1 ]
  [[ "$output" == *"quote.md: 1 fence line(s)"* ]]
}

@test "md fences: balanced files pass" {
  printf '# ok\n\n%sbash\necho hi\n%s\n\n> %s\n> x\n> %s\n' "$FENCE" "$FENCE" "$FENCE" "$FENCE" > good.md
  git add good.md
  run bash "$FENCES"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 file(s) OK"* ]]
}

@test "md links: a missing relative target fails with file:line target" {
  mkdir -p sub
  printf '# t\n' > sub/target.md
  printf 'ok [a](sub/target.md#x) [b](/sub/target.md "t")\nbad [c](sub/missing.md)\n' > index.md
  git add index.md sub/target.md
  run bash "$LINKS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"index.md:2 sub/missing.md"* ]]
  [[ "$output" != *"index.md:1"* ]]
}

@test "md links: resolved, external, anchor and fenced links pass" {
  mkdir -p sub
  printf '# t\n' > sub/target.md
  printf '[up](../index.md) [ext](https://example.com/x) [mail](mailto:a@b) [here](#top)\n%s\n[fenced](nope.md)\n%s\n' "$FENCE" "$FENCE" > sub/page.md
  printf '[s](sub/target.md)\n' > index.md
  git add index.md sub/target.md sub/page.md
  run bash "$LINKS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 file(s) OK"* ]]
}

@test "md checks: a named file that does not exist fails instead of being skipped" {
  run bash "$FENCES" no-such-file.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-such-file.md"* ]]
  run bash "$LINKS" no-such-file.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-such-file.md"* ]]
}

@test "md checks: zero Markdown files checked is a failure, not a pass" {
  printf 'x\n' > notes.txt
  git add notes.txt
  run bash "$FENCES"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Markdown files"* ]]
  run bash "$LINKS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Markdown files"* ]]
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
