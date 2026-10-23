#!/usr/bin/env bats

load helpers/common

REF_ROOT=${SHIPLOG_REF_ROOT:-refs/_shiplog}

count_exact_matches() {
  local needle="$1"
  local haystack="$2"
  printf '%s\n' "$haystack" | grep -F -x -c -- "$needle" || true
}

setup() {
  shiplog_standard_setup
  git config --unset-all remote.origin.fetch >/dev/null 2>&1 || true
  git config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git config --unset-all remote.origin.push >/dev/null 2>&1 || true
}

teardown() {
  shiplog_standard_teardown
}

# A bare remote of our own, selected with SHIPLOG_REMOTE, so pushes and fetches
# never touch the sandbox origin.
add_plain_remote() {
  PLAIN_DIR=$(mktemp -d)
  git init -q --bare "$PLAIN_DIR"
  git remote remove plain >/dev/null 2>&1 || true
  git remote add plain "$PLAIN_DIR"
  export SHIPLOG_REMOTE=plain
}

drop_plain_remote() {
  git remote remove plain >/dev/null 2>&1 || true
  [ -z "${PLAIN_DIR:-}" ] || rm -rf "$PLAIN_DIR"
  unset SHIPLOG_REMOTE
}

@test "git shiplog init sets a non-forced fetch refspec and reflogs, and no push refspecs (#140)" {
  run git shiplog init
  [ "$status" -eq 0 ]

  run git config --get-all remote.origin.fetch
  [ "$status" -eq 0 ]
  [ "$(count_exact_matches "${REF_ROOT}/*:${REF_ROOT}/*" "$output")" -eq 1 ]
  [ "$(count_exact_matches "+${REF_ROOT}/*:${REF_ROOT}/*" "$output")" -eq 0 ]

  run git config --get-all remote.origin.push
  [ -z "$output" ] || { echo "init must not install push refspecs by default; got: $output"; false; }

  run git config --get core.logAllRefUpdates
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "git shiplog init is idempotent" {
  run git shiplog init
  [ "$status" -eq 0 ]
  run git shiplog init
  [ "$status" -eq 0 ]
  run git config --get-all remote.origin.fetch
  [ "$(count_exact_matches "${REF_ROOT}/*:${REF_ROOT}/*" "$output")" -eq 1 ] || { echo "expected exactly one fetch refspec"; false; }
  run git config --get-all remote.origin.push
  [ -z "$output" ] || { echo "expected no push refspecs; got: $output"; false; }
}

@test "after init a plain git push sends the current branch only, not Shiplog refs (#140)" {
  add_plain_remote
  run git shiplog init
  [ "$status" -eq 0 ]
  git update-ref "${REF_ROOT}/journal/prod" HEAD
  branch=$(git symbolic-ref --short HEAD)

  run git push plain
  echo "$output" >&2
  [ "$status" -eq 0 ]
  git --git-dir="$PLAIN_DIR" rev-parse -q --verify "refs/heads/$branch" >/dev/null
  [ -z "$(git --git-dir="$PLAIN_DIR" rev-parse -q --verify "${REF_ROOT}/journal/prod" || true)" ] \
    || { echo "plain git push must not publish Shiplog refs"; false; }
  drop_plain_remote
}

@test "git shiplog init removes the push refspecs older versions installed and keeps user ones (#140)" {
  # The pair older versions wrote on a remote with no push config.
  git config --add remote.origin.push "${REF_ROOT}/*:${REF_ROOT}/*"
  git config --add remote.origin.push HEAD
  run git shiplog init
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed"* ]]
  run git config --get-all remote.origin.push
  [ -z "$output" ] || { echo "expected the Shiplog pair to be removed; got: $output"; false; }

  # With a user refspec present, only the Shiplog one goes; HEAD and the user spec stay.
  git config --add remote.origin.push 'refs/heads/*:refs/remotes/origin/*'
  git config --add remote.origin.push HEAD
  git config --add remote.origin.push "${REF_ROOT}/*:${REF_ROOT}/*"
  run git shiplog init
  [ "$status" -eq 0 ]
  run git config --get-all remote.origin.push
  [ "$(count_exact_matches 'refs/heads/*:refs/remotes/origin/*' "$output")" -eq 1 ]
  [ "$(count_exact_matches HEAD "$output")" -eq 1 ]
  [ "$(count_exact_matches "${REF_ROOT}/*:${REF_ROOT}/*" "$output")" -eq 0 ]
}

@test "git shiplog init replaces the forced fetch refspec older versions installed (#140)" {
  git config --add remote.origin.fetch "+${REF_ROOT}/*:${REF_ROOT}/*"
  run git shiplog init
  [ "$status" -eq 0 ]
  run git config --get-all remote.origin.fetch
  [ "$(count_exact_matches "+${REF_ROOT}/*:${REF_ROOT}/*" "$output")" -eq 0 ]
  [ "$(count_exact_matches "${REF_ROOT}/*:${REF_ROOT}/*" "$output")" -eq 1 ]
  [ "$(count_exact_matches '+refs/heads/*:refs/remotes/origin/*' "$output")" -eq 1 ]
}

@test "after init a rewritten remote ledger makes git fetch fail and keeps the local copy (#140)" {
  add_plain_remote
  run git shiplog init
  [ "$status" -eq 0 ]
  first=$(git commit-tree "$(git mktree </dev/null)" -m "entry 1")
  git push -q plain "$first:${REF_ROOT}/journal/prod"
  run git fetch plain
  [ "$status" -eq 0 ]
  [ "$(git rev-parse "${REF_ROOT}/journal/prod")" = "$first" ]

  # Someone rewrites the remote ledger to an unrelated history.
  forged=$(git commit-tree "$(git mktree </dev/null)" -m "rewritten history")
  git push -q --force plain "$forged:${REF_ROOT}/journal/prod"
  git update-ref "${REF_ROOT}/journal/prod" "$first"
  run git fetch plain
  echo "$output" >&2
  [ "$status" -ne 0 ]
  [ "$(git rev-parse "${REF_ROOT}/journal/prod")" = "$first" ] || { echo "fetch overwrote the local ledger"; false; }
  drop_plain_remote
}

@test "git shiplog init --push-refspecs installs them on request with a warning (#140)" {
  run git shiplog init --push-refspecs
  [ "$status" -eq 0 ]
  [[ "$output" == *"plain git push"* ]]
  run git config --get-all remote.origin.push
  [ "$(count_exact_matches "${REF_ROOT}/*:${REF_ROOT}/*" "$output")" -eq 1 ]
  [ "$(count_exact_matches HEAD "$output")" -eq 1 ]
  # A later plain init keeps an explicit opt-in.
  run git shiplog init
  run git config --get-all remote.origin.push
  [ "$(count_exact_matches "${REF_ROOT}/*:${REF_ROOT}/*" "$output")" -eq 1 ]
}

@test "ls on empty journal errors cleanly" {
  run git shiplog ls
  [ "$status" -ne 0 ]
  [[ "$output" == *"No entries at"* ]]
}
