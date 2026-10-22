#!/usr/bin/env bats

# Installer / uninstaller smoke tests (#93, #105, #106, #107, #134, #144).
#
# Everything runs inside the test container: the "upstream" is a local bare
# clone of this checkout (SHIPLOG_REPO_URL=file://...), the install target
# lives under a throw-away $HOME, and no nested Docker is needed.

load helpers/common

INSTALLER="$BATS_TEST_DIRNAME/../scripts/install-shiplog.sh"
UNINSTALLER="$BATS_TEST_DIRNAME/../scripts/uninstall-shiplog.sh"
DEPS_INSTALLER="$BATS_TEST_DIRNAME/../install-shiplog-deps.sh"
UPSTREAM_URL="https://github.com/flyingrobots/shiplog.git"

# Snapshot this checkout into a bare repo once per file; the installer clones it.
setup_file() {
  local src="$BATS_FILE_TMPDIR/src"
  mkdir -p "$src"
  cp -a "$SHIPLOG_PROJECT_ROOT/." "$src/"
  rm -rf "$src/.git"
  git -C "$src" init -q
  git -C "$src" add -A
  git -C "$src" -c user.name="Shiplog Tester" -c user.email="shiplog-tester@example.com" \
    commit -q -m "shiplog snapshot for installer smoke tests"
  git clone -q --bare "$src" "$BATS_FILE_TMPDIR/origin.git"
  export SHIPLOG_SMOKE_ORIGIN="file://$BATS_FILE_TMPDIR/origin.git"
}

setup() {
  shiplog_install_cli
  shiplog_use_sandbox_repo
  # Throw-away HOME: default allowed base and default install dir live here.
  SMOKE_ORIG_HOME="$HOME"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset SHIPLOG_PROFILE
  unset SHIPLOG_ALLOWED_BASES
  export SHIPLOG_REPO_URL="$SHIPLOG_SMOKE_ORIGIN"
}

teardown() {
  shiplog_cleanup_sandbox_repo
  export HOME="${SMOKE_ORIG_HOME:-$HOME}"
  # A real uninstall may remove the harness copy of git-shiplog; put it back.
  shiplog_install_cli
}

# A fake install dir that passes the "is this a Shiplog checkout" check.
make_fake_checkout() {
  local dir="$1" origin="${2:-$UPSTREAM_URL}"
  mkdir -p "$dir/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/git-shiplog"
  chmod +x "$dir/bin/git-shiplog"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$origin"
}

# A PATH holding only the listed tools (symlinked from the real PATH).
make_restricted_path() {
  local bin="$1"
  shift
  mkdir -p "$bin"
  local tool real
  for tool in "$@"; do
    real=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$real" "$bin/$tool"
  done
}

# ---------------------------------------------------------------------------
# Dependency installer
# ---------------------------------------------------------------------------

@test "deps installer --dry-run prints the jq install plan" {
  local bin="$BATS_TEST_TMPDIR/nojq-bin"
  make_restricted_path "$bin" bash sh uname id sudo brew apt-get dnf yum pacman apk zypper
  run env PATH="$bin" bash -c 'command -v jq'
  [ "$status" -ne 0 ]

  run env PATH="$bin" bash "$DEPS_INSTALLER" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detected OS:"* ]]
  # A planned (not executed) package-manager command that installs jq.
  [[ "$output" == *"+ "*"jq"* ]]
  [[ "$output" != *"already installed"* ]]
}

# ---------------------------------------------------------------------------
# Installer: happy paths
# ---------------------------------------------------------------------------

@test "installer --dry-run against a local clone exits 0 and plans the clone" {
  SHIPLOG_HOME="$HOME/.shiplog" run bash "$INSTALLER" --no-profile --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ git clone "*"origin.git"* ]]
  [[ "$output" == *"Would run dependency installer"* ]]
  [ ! -e "$HOME/.shiplog" ]
}

@test "installer --dry-run honours SHIPLOG_ALLOWED_BASES" {
  SHIPLOG_ALLOWED_BASES="$BATS_TEST_TMPDIR/opt" SHIPLOG_HOME="$BATS_TEST_TMPDIR/opt/shiplog" \
    run bash "$INSTALLER" --no-profile --dry-run --silent
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ git clone "* ]]
}

@test "installer performs a real install from the local clone; git shiplog --version works" {
  SHIPLOG_HOME="$HOME/.shiplog" run bash "$INSTALLER" --no-profile
  [ "$status" -eq 0 ]
  # #144 A: the dependency installer runs without --silent, so its diagnostics show.
  [[ "$output" == *"Detected OS:"* ]]
  [ -x "$HOME/.shiplog/bin/git-shiplog" ]
  [ -x "$HOME/.shiplog/install-shiplog-deps.sh" ]
  [ -L "$HOME/.shiplog/bin/bosun" ]

  # Exercise the installed copy on its own (not the harness lib/bosun paths).
  run env -u SHIPLOG_LIB_DIR -u SHIPLOG_BOSUN_BIN \
    PATH="$HOME/.shiplog/bin:$PATH" SHIPLOG_HOME="$HOME/.shiplog" git shiplog --version
  [ "$status" -eq 0 ]
  [[ "$output" == shiplog\ * ]]

  # Second run takes the update path: fetch + reset on the verified checkout.
  SHIPLOG_HOME="$HOME/.shiplog" run bash "$INSTALLER" --no-profile --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"fetch origin"* ]]
  [[ "$output" == *"reset --hard origin/"* ]]

  # --force on a verified checkout plans rm + clone (dry-run leaves it alone).
  SHIPLOG_HOME="$HOME/.shiplog" run bash "$INSTALLER" --no-profile --dry-run --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ rm -rf "* ]]
  [[ "$output" == *"+ git clone "* ]]
  [ -d "$HOME/.shiplog/.git" ]

  # Uninstaller accepts the real checkout: dry-run plans the rm, real run removes it.
  SHIPLOG_HOME="$HOME/.shiplog" run bash "$UNINSTALLER" --dry-run --silent
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ rm -rf "* ]]
  [ -d "$HOME/.shiplog" ]

  SHIPLOG_HOME="$HOME/.shiplog" run bash "$UNINSTALLER" --silent
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.shiplog" ]
}

@test "installer --dry-run --profile does not create the profile file (#144 B)" {
  local profile="$BATS_TEST_TMPDIR/newprofile"
  SHIPLOG_HOME="$HOME/.shiplog" run bash "$INSTALLER" --dry-run --profile "$profile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would append env vars to $profile"* ]]
  [ ! -e "$profile" ]
  [ ! -e "$profile.bak" ]
}

@test "installer --silent passes --silent to the dependency installer" {
  SHIPLOG_HOME="$HOME/.shiplog" run bash "$INSTALLER" --no-profile --silent
  [ "$status" -eq 0 ]
  [[ "$output" != *"Detected OS:"* ]]
}

# ---------------------------------------------------------------------------
# Installer: guard refusals (#107)
# ---------------------------------------------------------------------------

@test "installer refuses SHIPLOG_HOME=\$HOME even with --force (#107)" {
  : > "$HOME/keep-me"
  SHIPLOG_HOME="$HOME" run bash "$INSTALLER" --force --dry-run --no-profile
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing"* ]]
  [[ "$output" != *"rm -rf"* ]]
  [[ "$output" != *"reset --hard"* ]]
  [ -f "$HOME/keep-me" ]
}

@test "installer refuses SHIPLOG_HOME=/ (#107)" {
  SHIPLOG_HOME=/ run bash "$INSTALLER" --dry-run --no-profile
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing"* ]]
  [[ "$output" != *"git clone"* ]]
  [[ "$output" != *"rm -rf"* ]]
}

@test "installer refuses a path outside the allowed bases" {
  SHIPLOG_HOME="$BATS_TEST_TMPDIR/elsewhere/shiplog" run bash "$INSTALLER" --dry-run --no-profile
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside permitted bases"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]
}

@test "installer refuses an allowed base itself" {
  mkdir -p "$BATS_TEST_TMPDIR/opt"
  SHIPLOG_ALLOWED_BASES="$BATS_TEST_TMPDIR/opt" SHIPLOG_HOME="$BATS_TEST_TMPDIR/opt" \
    run bash "$INSTALLER" --force --dry-run --no-profile
  [ "$status" -ne 0 ]
  [[ "$output" == *"allowed base itself"* ]]
  [[ "$output" != *"rm -rf"* ]]
}

@test "installer refuses to reset a non-Shiplog repo and keeps uncommitted work (#107)" {
  local proj="$HOME/myproject"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" remote add origin https://example.com/someone/other.git
  echo "precious" > "$proj/uncommitted.txt"

  SHIPLOG_HOME="$proj" run bash "$INSTALLER" --dry-run --no-profile
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a Shiplog checkout"* ]]
  [[ "$output" != *"reset --hard"* ]]
  [[ "$output" != *"git fetch"* ]]

  # Real (non-dry) run must refuse the same way and touch nothing.
  SHIPLOG_HOME="$proj" run bash "$INSTALLER" --no-profile
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a Shiplog checkout"* ]]
  [ -f "$proj/uncommitted.txt" ]
  [ "$(cat "$proj/uncommitted.txt")" = "precious" ]

  # --force must not rm -rf it either.
  SHIPLOG_HOME="$proj" run bash "$INSTALLER" --force --dry-run --no-profile
  [ "$status" -ne 0 ]
  [[ "$output" != *"rm -rf"* ]]
  [ -f "$proj/uncommitted.txt" ]
}

@test "installer refuses a repo whose origin is not the Shiplog repo even if bin/git-shiplog exists" {
  local dir="$HOME/.shiplog"
  make_fake_checkout "$dir" "https://github.com/someone-else/shiplog.git"
  SHIPLOG_HOME="$dir" run bash "$INSTALLER" --dry-run --no-profile
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a Shiplog checkout"* ]]
  [[ "$output" != *"reset --hard"* ]]
}

@test "installer refuses a symlinked install dir" {
  mkdir -p "$HOME/real"
  ln -s "$HOME/real" "$HOME/.shiplog"
  SHIPLOG_HOME="$HOME/.shiplog" run bash "$INSTALLER" --force --dry-run --no-profile
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [[ "$output" != *"rm -rf"* ]]
  [ -d "$HOME/real" ]
}

# ---------------------------------------------------------------------------
# Uninstaller: guard refusals and acceptance (#93)
# ---------------------------------------------------------------------------

@test "uninstaller refuses a non-Shiplog directory and keeps the sentinel (#93)" {
  local d="$HOME/notshiplog"
  mkdir -p "$d"
  : > "$d/sentinel"

  SHIPLOG_HOME="$d" run bash "$UNINSTALLER" --dry-run --silent
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a Shiplog checkout"* ]]
  [[ "$output" != *"rm -rf"* ]]
  [ -f "$d/sentinel" ]

  SHIPLOG_HOME="$d" run bash "$UNINSTALLER" --silent
  [ "$status" -ne 0 ]
  [ -f "$d/sentinel" ]
}

@test "uninstaller refuses SHIPLOG_HOME=/ and SHIPLOG_HOME=\$HOME (#93)" {
  : > "$HOME/keep-me"
  SHIPLOG_HOME=/ run bash "$UNINSTALLER" --dry-run --silent
  [ "$status" -ne 0 ]
  [[ "$output" != *"rm -rf"* ]]

  SHIPLOG_HOME="$HOME" run bash "$UNINSTALLER" --dry-run --silent
  [ "$status" -ne 0 ]
  [[ "$output" != *"rm -rf"* ]]
  [ -f "$HOME/keep-me" ]

  SHIPLOG_HOME="$HOME" run bash "$UNINSTALLER" --silent
  [ "$status" -ne 0 ]
  [ -f "$HOME/keep-me" ]
}

@test "uninstaller refuses an allowed base itself and a symlinked target" {
  mkdir -p "$BATS_TEST_TMPDIR/opt"
  SHIPLOG_ALLOWED_BASES="$BATS_TEST_TMPDIR/opt" SHIPLOG_HOME="$BATS_TEST_TMPDIR/opt" \
    run bash "$UNINSTALLER" --dry-run --silent
  [ "$status" -ne 0 ]
  [[ "$output" == *"allowed base itself"* ]]

  make_fake_checkout "$HOME/real-shiplog"
  ln -s "$HOME/real-shiplog" "$HOME/.shiplog"
  SHIPLOG_HOME="$HOME/.shiplog" run bash "$UNINSTALLER" --dry-run --silent
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ -d "$HOME/real-shiplog" ]
}

@test "uninstaller --dry-run accepts a verified checkout and prints the rm line (#93)" {
  make_fake_checkout "$HOME/.shiplog" "$UPSTREAM_URL"
  SHIPLOG_HOME="$HOME/.shiplog" run env -u SHIPLOG_REPO_URL bash "$UNINSTALLER" --dry-run --silent
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ rm -rf "*".shiplog"* ]]
  [ -d "$HOME/.shiplog" ]
}

@test "uninstaller matches ssh and https forms of the repo URL" {
  make_fake_checkout "$HOME/.shiplog" "git@github.com:flyingrobots/shiplog.git"
  SHIPLOG_HOME="$HOME/.shiplog" run env -u SHIPLOG_REPO_URL bash "$UNINSTALLER" --dry-run --silent
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ rm -rf "* ]]

  make_fake_checkout "$HOME/.shiplog-b" "ssh://git@github.com/flyingrobots/shiplog"
  SHIPLOG_HOME="$HOME/.shiplog-b" run env -u SHIPLOG_REPO_URL bash "$UNINSTALLER" --dry-run --silent
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ rm -rf "* ]]
}

@test "uninstaller --force-unsafe bypasses only the checkout check" {
  local d="$HOME/notshiplog"
  mkdir -p "$d"
  SHIPLOG_HOME="$d" run bash "$UNINSTALLER" --dry-run --silent --force-unsafe
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ rm -rf "* ]]
  [ -d "$d" ]

  SHIPLOG_HOME="$HOME" run bash "$UNINSTALLER" --dry-run --silent --force-unsafe
  [ "$status" -ne 0 ]
  [[ "$output" != *"rm -rf"* ]]
}

# ---------------------------------------------------------------------------
# Uninstaller: remote ref check without GNU timeout (#106)
# ---------------------------------------------------------------------------

@test "uninstaller works without a timeout binary and does not call pushed refs unpublished (#106)" {
  # Sandbox repo (cwd) gets a bare origin with one pushed Shiplog ref.
  local remote="$BATS_TEST_TMPDIR/origin-bare.git"
  git init -q --bare "$remote"
  git remote add origin "$remote"
  git update-ref refs/_shiplog/journal/x HEAD
  git push -q origin refs/_shiplog/journal/x:refs/_shiplog/journal/x

  make_fake_checkout "$HOME/.shiplog"

  local bin="$BATS_TEST_TMPDIR/notimeout-bin"
  make_restricted_path "$bin" bash sh git awk sed grep dirname mktemp mv rm cp cat cmp readlink
  run env PATH="$bin" bash -c 'command -v timeout'
  [ "$status" -ne 0 ]

  SHIPLOG_HOME="$HOME/.shiplog" run env -u SHIPLOG_REPO_URL PATH="$bin" \
    bash "$UNINSTALLER" --dry-run --profile "$BATS_TEST_TMPDIR/no-such-profile"
  [ "$status" -eq 0 ]
  [[ "$output" != *"not pushed"* ]]
  [[ "$output" != *"unreachable"* ]]
  [[ "$output" == *"+ rm -rf "* ]]
}

@test "uninstaller still aborts on a genuinely unpublished ref" {
  local remote="$BATS_TEST_TMPDIR/origin-bare.git"
  git init -q --bare "$remote"
  git remote add origin "$remote"
  git update-ref refs/_shiplog/journal/x HEAD

  make_fake_checkout "$HOME/.shiplog"
  SHIPLOG_HOME="$HOME/.shiplog" run env -u SHIPLOG_REPO_URL bash "$UNINSTALLER" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"not pushed"* ]]
  [[ "$output" == *"refs/_shiplog/journal/x"* ]]
  [[ "$output" != *"rm -rf"* ]]
}

@test "uninstaller treats an unreachable remote as unknown, not unpublished (#106)" {
  git remote add origin "$BATS_TEST_TMPDIR/does-not-exist.git"
  git update-ref refs/_shiplog/journal/x HEAD

  make_fake_checkout "$HOME/.shiplog"
  SHIPLOG_HOME="$HOME/.shiplog" run env -u SHIPLOG_REPO_URL bash "$UNINSTALLER" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"unreachable"* ]]
  [[ "$output" != *"not pushed"* ]]
}

# ---------------------------------------------------------------------------
# Executable bits (#105)
# ---------------------------------------------------------------------------

@test "every shebang script under scripts/ bin/ contrib/hooks/ is executable (#105)" {
  local bad=()
  local f
  while IFS= read -r f; do
    if head -c2 "$f" 2>/dev/null | grep -q '^#!' && [ ! -x "$f" ]; then
      bad+=("$f")
    fi
  done < <(find "$SHIPLOG_PROJECT_ROOT/scripts" "$SHIPLOG_PROJECT_ROOT/bin" "$SHIPLOG_PROJECT_ROOT/contrib/hooks" -type f)
  if [ ${#bad[@]} -gt 0 ]; then
    printf 'not executable: %s\n' "${bad[@]}" >&2
    return 1
  fi
}

@test "git shiplog refs migrate --dry-run runs the migration helper (#105)" {
  # Directly under the root: the helper's for-each-ref pattern "<root>/*" does
  # not descend into journal/<env> (tracked for the G6 ref-root work).
  git update-ref refs/_shiplog/smoke HEAD
  run git shiplog refs migrate --to refs/heads/_shiplog --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"refs/_shiplog/smoke -> refs/heads/_shiplog/smoke"* ]]
  [[ "$output" == *"Dry-run"* ]]
  run git show-ref --verify --quiet refs/heads/_shiplog/smoke
  [ "$status" -ne 0 ]
}
