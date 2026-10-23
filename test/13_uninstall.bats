#!/usr/bin/env bats

load helpers/common

setup() {
  shiplog_install_cli
  shiplog_use_sandbox_repo
  git shiplog init >/dev/null

  # Fake install that passes the uninstaller's checkout check: bin/git-shiplog
  # plus remote.origin.url pointing at the Shiplog repo.
  mkdir -p "$HOME/.shiplog/bin" "$HOME/.shiplog/scripts"
  cat <<'SCRIPT' > "$HOME/.shiplog/bin/git-shiplog"
#!/usr/bin/env bash
exit 0
SCRIPT
  chmod +x "$HOME/.shiplog/bin/git-shiplog"
  git -C "$HOME/.shiplog" init -q
  git -C "$HOME/.shiplog" remote add origin https://github.com/flyingrobots/shiplog.git

  cat <<'BOSUN' > "$HOME/.shiplog/scripts/bosun"
#!/usr/bin/env bash
exit 0
BOSUN
  chmod +x "$HOME/.shiplog/scripts/bosun"

  # Shims live in a test-owned bin dir on PATH, so the harness copy of
  # git-shiplog in /usr/local/bin is never overwritten or removed (#148 C).
  SHIM_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$SHIM_BIN"
  install -m 0755 "$HOME/.shiplog/bin/git-shiplog" "$SHIM_BIN/shiplog"
  ln -sf "$HOME/.shiplog/scripts/bosun" "$SHIM_BIN/bosun"
  export PATH="$SHIM_BIN:$PATH"

  # Store original config for restoration
  ORIGINAL_FETCH=$(git config --get-all remote.origin.fetch 2>/dev/null || echo "")
  ORIGINAL_PUSH=$(git config --get-all remote.origin.push 2>/dev/null || echo "")

  git config --add remote.origin.fetch '+refs/_shiplog/*:refs/_shiplog/*'
  git config --add remote.origin.push 'refs/_shiplog/*:refs/_shiplog/*'

  PROFILE="$HOME/.test_profile"
  cat <<PROFILE > "$PROFILE"
# Shiplog
export SHIPLOG_HOME="$HOME/.shiplog"
export PATH="$HOME/.shiplog/bin:$PATH"
PROFILE
  export SHIPLOG_PROFILE="$PROFILE"
  export SHIPLOG_HOME="$HOME/.shiplog"
}

teardown() {
  # Restore repo config only if still inside a git repo
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git config --unset-all remote.origin.fetch '+refs/_shiplog/*:refs/_shiplog/*' 2>/dev/null || true
    git config --unset-all remote.origin.push 'refs/_shiplog/*:refs/_shiplog/*' 2>/dev/null || true

    if [ -n "$ORIGINAL_FETCH" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && git config --add remote.origin.fetch "$line"
      done <<< "$ORIGINAL_FETCH"
    fi
    if [ -n "$ORIGINAL_PUSH" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && git config --add remote.origin.push "$line"
      done <<< "$ORIGINAL_PUSH"
    fi
  fi

  shiplog_cleanup_sandbox_repo
  rm -rf "$HOME/.shiplog" "$HOME/.test_profile" "$HOME/.test_profile.shiplog.bak" 2>/dev/null || true
}

@test "uninstall removes shiplog artifacts" {
  local script_path
  script_path="${BATS_TEST_DIRNAME}/../scripts/uninstall-shiplog.sh"
  run "$script_path" --silent
  [ "$status" -eq 0 ]

  [ ! -d "$HOME/.shiplog" ]
  [ ! -e "$SHIM_BIN/shiplog" ]
  [ ! -e "$SHIM_BIN/bosun" ]
  # The harness copy is not a Shiplog shim and must survive.
  [ -e /usr/local/bin/git-shiplog ]

  local fetch_config
  fetch_config=$(git config --get-all remote.origin.fetch 2>/dev/null || echo "")
  [[ "$fetch_config" != *"refs/_shiplog"* ]]

  local push_config
  push_config=$(git config --get-all remote.origin.push 2>/dev/null || echo "")
  [[ "$push_config" != *"refs/_shiplog"* ]]

  # File should exist but not contain Shiplog
  [ -f "$HOME/.test_profile" ]
  run grep 'Shiplog' "$HOME/.test_profile"
  [ "$status" -ne 0 ]
  [ -f "$HOME/.test_profile.shiplog.bak" ]
}

@test "uninstall removes a copied shim on systems without cmp (arch/fedora base images)" {
  # Shadow cmp with a stub that fails like a missing binary.
  printf '#!/bin/sh\nexit 127\n' > "$SHIM_BIN/cmp"
  chmod +x "$SHIM_BIN/cmp"
  # Control: an unrelated file named like a shim must survive.
  OTHER_BIN="$BATS_TEST_TMPDIR/other"
  mkdir -p "$OTHER_BIN"
  printf '#!/bin/sh\necho not shiplog\n' > "$OTHER_BIN/bosun"
  chmod +x "$OTHER_BIN/bosun"
  rm -f "$SHIM_BIN/bosun"
  export PATH="$SHIM_BIN:$OTHER_BIN:$PATH"

  run "${BATS_TEST_DIRNAME}/../scripts/uninstall-shiplog.sh" --silent
  [ "$status" -eq 0 ]
  [ ! -e "$SHIM_BIN/shiplog" ]
  [ -e "$OTHER_BIN/bosun" ]
}
