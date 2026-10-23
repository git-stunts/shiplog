# shellcheck shell=bash
# Policy resolution (jq-powered JSON policy documents).
#
# Two entry points:
#
#   shiplog_policy_load ENV   Read every source and fill the effective values for
#                             ENV. No side effects beyond reading. A policy
#                             document that exists but fails to parse or
#                             validate stops the command; it never degrades to
#                             the built-in defaults.
#   shiplog_policy_enforce    Side-effect checks that only the write/verify path
#                             needs (the allowed signers file must exist when
#                             signing is required). `git shiplog policy ...`
#                             calls load only, so a repository can be repaired
#                             while signing is on and the roster is missing.
#
# ENV is always a parameter. Commands thread the environment they operate on
# (positional ENV, then --env, then the global --env / SHIPLOG_ENV) and never
# rely on DEFAULT_ENV implicitly.
#
# One ordered precedence table applies to every field; the first source that
# provides a value wins:
#
#   field            1. CLI / env               2. git config                      3. policy document                              4. default
#   ---------------  -------------------------  ---------------------------------  ----------------------------------------------  -------------------------------------------
#   authors          SHIPLOG_AUTHORS            shiplog.policy.allowedAuthors      authors.default_allowlist                       (none: unrestricted)
#                                                                                  ∪ authors.env_overrides.default
#                                                                                  ∪ authors.env_overrides[ENV]
#   signers file     SHIPLOG_ALLOWED_SIGNERS    shiplog.policy.allowedSignersFile  allow_ssh_signers_file                          gpg.ssh.allowedSignersFile,
#                                                                                                                                  else <repo>/.shiplog/allowed_signers
#   require_signed   SHIPLOG_SIGN               shiplog.policy.requireSigned       deployment_requirements[ENV].require_signed     false
#                                                                                  → deployment_requirements.default.require_signed
#                                                                                  → require_signed
#   notes ref        SHIPLOG_NOTES_REF          (none)                             notes_ref                                       refs/_shiplog/notes/logs
#
# The policy document itself comes from the policy ref ($POLICY_REF, default
# refs/_shiplog/policy/current) when it exists, otherwise from
# <repo root>/.shiplog/policy.json. Relative signers paths resolve against the
# repository root, never against $PWD.
#
# Outputs (globals):
#   POLICY_SOURCE                 document source: policy-ref:<ref>, policy-file:.shiplog/policy.json, or default
#   POLICY_ENV                    environment the values were resolved for
#   ALLOWED_AUTHORS_EFFECTIVE     space-separated allowlist ("" = unrestricted)
#   SIGNERS_FILE_EFFECTIVE        absolute path of the allowed signers file ("" = none)
#   SHIPLOG_SIGN_EFFECTIVE        1 or 0
#   NOTES_REF                     effective notes ref
#   POLICY_SOURCE_AUTHORS, POLICY_SOURCE_SIGNERS, POLICY_SOURCE_REQUIRE_SIGNED,
#   POLICY_SOURCE_NOTES_REF       per-field provenance (env:<VAR>, git-config:<key>, <document source>, default)
#   POLICY_REQUIRE_SIGNED, POLICY_ALLOWED_SIGNERS_FILE, POLICY_ALLOWED_AUTHORS,
#   POLICY_NOTES_REF              raw values taken from the document ("" when absent)

SHIPLOG_POLICY_LOADED_ENV="${SHIPLOG_POLICY_LOADED_ENV:-}"
POLICY_ENV="${POLICY_ENV:-}"
POLICY_SOURCE_AUTHORS="${POLICY_SOURCE_AUTHORS:-}"
POLICY_SOURCE_SIGNERS="${POLICY_SOURCE_SIGNERS:-}"
POLICY_SOURCE_REQUIRE_SIGNED="${POLICY_SOURCE_REQUIRE_SIGNED:-}"
POLICY_SOURCE_NOTES_REF="${POLICY_SOURCE_NOTES_REF:-}"
POLICY_DOC_PATH=""

# Fields extracted from a validated document, printed one per line in this
# order: require_signed, allow_ssh_signers_file, notes_ref, authors.
# Per-environment fields use explicit has() checks so an explicit `false`
# overrides an inherited `true`; the lookup order is
# deployment_requirements[ENV] → deployment_requirements.default → top level.
# The pre-receive hook applies the same rule for require_signed.
SHIPLOG_POLICY_EXTRACT_JQ='
  def envreq($f):
    if (.deployment_requirements | type) == "object"
       and (.deployment_requirements[$env] | type) == "object"
       and (.deployment_requirements[$env] | has($f))
    then .deployment_requirements[$env][$f]
    elif (.deployment_requirements | type) == "object"
       and (.deployment_requirements.default | type) == "object"
       and (.deployment_requirements.default | has($f))
    then .deployment_requirements.default[$f]
    elif has($f) then .[$f]
    else null end;
  def str($v): if $v == null then "" else ($v | tostring) end;
  def authors:
    if (.authors | type) == "object" then
      [ (.authors.default_allowlist // []),
        ((.authors.env_overrides // {}) | (.default // [])),
        ((.authors.env_overrides // {}) | (.[$env] // [])) ]
      | flatten
      | map(select(type == "string" and . != ""))
      | unique
      | join(" ")
    else "" end;
  [ str(envreq("require_signed")),
    str(.allow_ssh_signers_file),
    str(.notes_ref),
    authors ]
  | .[]
'

# Path of the canonical jq validator shared by the CLI, scripts/policy/validate.sh
# and the pre-receive hook.
shiplog_policy_validator_filter() {
  local candidate
  for candidate in \
    "${SHIPLOG_HOME:-}/scripts/lib/policy_validate.jq" \
    "${SHIPLOG_LIB_DIR:-}/../scripts/lib/policy_validate.jq"; do
    case "$candidate" in /scripts/*|/../*) continue ;; esac
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# shiplog_policy_validate_file PATH LABEL
# Dies with the jq/validator message when PATH is not valid JSON or fails the
# structural validator. Succeeds silently otherwise.
shiplog_policy_validate_file() {
  local src="$1" label="$2"
  command -v jq >/dev/null 2>&1 || die "shiplog: jq command not found"
  [ -r "$src" ] || die "shiplog: cannot read policy document ($label): $src"
  local filter
  filter=$(shiplog_policy_validator_filter) || die "shiplog: policy validator filter not found (expected \$SHIPLOG_HOME/scripts/lib/policy_validate.jq)"
  local errs status=0
  # Exactly one JSON value: an empty file would otherwise validate (jq runs the
  # filter zero times) and load as the defaults, and with several values each
  # reader would pick a different one.
  errs=$(jq -n '[inputs] | length' "$src" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    die "shiplog: policy document ($label) is not valid JSON: ${errs:-jq exited with status $status}"
  fi
  if [ "$errs" != 1 ]; then
    die "shiplog: policy document ($label) must contain exactly one JSON value (found $errs)"
  fi
  errs=$(jq -r -f "$filter" "$src" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    die "shiplog: policy document ($label) is not valid JSON: ${errs:-jq exited with status $status}"
  fi
  if [ -n "$errs" ]; then
    printf '%s\n' "$errs" >&2
    die "shiplog: policy document ($label) failed validation; fix it or remove it (no fallback to defaults)"
  fi
}

# shiplog_policy_document
# Locates the policy document. Sets POLICY_SOURCE and POLICY_DOC_PATH (a temp
# file for the ref; the working-tree file otherwise). Returns 1 when no document
# exists. A policy ref without .shiplog/policy.json is an error, not an absence.
shiplog_policy_document() {
  POLICY_DOC_PATH=""
  local ref="${POLICY_REF:-refs/_shiplog/policy/current}"
  if git rev-parse -q --verify "$ref" >/dev/null 2>&1; then
    local tmp
    tmp=$(mktemp) || die "shiplog: unable to create a temp file for the policy document"
    if ! git show "$ref:.shiplog/policy.json" >"$tmp" 2>/dev/null; then
      rm -f "$tmp"
      die "shiplog: policy ref $ref exists but has no .shiplog/policy.json; republish it with scripts/shiplog-sync-policy.sh"
    fi
    POLICY_DOC_PATH="$tmp"
    POLICY_SOURCE="policy-ref:$ref"
    return 0
  fi
  local root
  if root=$(shiplog_repo_root) && [ -n "$root" ] && [ -f "$root/.shiplog/policy.json" ]; then
    POLICY_DOC_PATH="$root/.shiplog/policy.json"
    POLICY_SOURCE="policy-file:.shiplog/policy.json"
    return 0
  fi
  POLICY_SOURCE="default"
  return 1
}

# shiplog_policy_resolve_path PATH
# Expands ~ and roots relative paths at the repository root. Canonicalizes only
# when the file exists so error messages still name the configured location.
shiplog_policy_resolve_path() {
  local candidate="${1:-}"
  [ -n "$candidate" ] || return 0
  case "$candidate" in
    "~") candidate="$HOME" ;;
    "~/"*) candidate="$HOME/${candidate#\~/}" ;;
  esac
  case "$candidate" in
    /*|[A-Za-z]:[\\/]*|'\\'*) ;;
    *)
      local root
      if root=$(shiplog_repo_root) && [ -n "$root" ]; then
        candidate="$root/$candidate"
      fi
      ;;
  esac
  local canonical=""
  if [ -e "$candidate" ]; then
    if command -v realpath >/dev/null 2>&1; then
      canonical=$(realpath "$candidate" 2>/dev/null || true)
    elif command -v readlink >/dev/null 2>&1; then
      canonical=$(readlink -f "$candidate" 2>/dev/null || true)
    fi
  fi
  printf '%s' "${canonical:-$candidate}"
}

shiplog_policy_reset() {
  POLICY_SOURCE=""
  POLICY_REQUIRE_SIGNED=""
  POLICY_ALLOWED_SIGNERS_FILE=""
  POLICY_ALLOWED_AUTHORS=""
  POLICY_NOTES_REF=""
  POLICY_SOURCE_AUTHORS=""
  POLICY_SOURCE_SIGNERS=""
  POLICY_SOURCE_REQUIRE_SIGNED=""
  POLICY_SOURCE_NOTES_REF=""
  ALLOWED_AUTHORS_EFFECTIVE=""
  SIGNERS_FILE_EFFECTIVE=""
  SHIPLOG_SIGN_EFFECTIVE=""
  SHIPLOG_POLICY_LOADED_ENV=""
}

# shiplog_policy_load ENV
shiplog_policy_load() {
  local env="${1:-}"
  [ -n "$env" ] || die "shiplog: internal error: shiplog_policy_load requires an environment"
  if [ "${SHIPLOG_POLICY_LOADED_ENV:-}" = "$env" ]; then
    return 0
  fi

  shiplog_policy_reset
  POLICY_ENV="$env"

  local in_repo=0
  if git rev-parse --git-dir >/dev/null 2>&1; then
    in_repo=1
  fi

  # --- 3. policy document ---------------------------------------------------
  if [ "$in_repo" -eq 1 ] && shiplog_policy_document; then
    shiplog_policy_validate_file "$POLICY_DOC_PATH" "$POLICY_SOURCE"
    local fields status=0
    fields=$(jq -r --arg env "$env" "$SHIPLOG_POLICY_EXTRACT_JQ" "$POLICY_DOC_PATH" 2>&1) || status=$?
    case "$POLICY_SOURCE" in
      policy-ref:*) rm -f "$POLICY_DOC_PATH" ;;
    esac
    POLICY_DOC_PATH=""
    if [ "$status" -ne 0 ]; then
      die "shiplog: failed to extract fields from policy document ($POLICY_SOURCE): $fields"
    fi
    {
      IFS= read -r POLICY_REQUIRE_SIGNED || true
      IFS= read -r POLICY_ALLOWED_SIGNERS_FILE || true
      IFS= read -r POLICY_NOTES_REF || true
      IFS= read -r POLICY_ALLOWED_AUTHORS || true
    } <<<"$fields"
  else
    POLICY_SOURCE="default"
  fi

  local cfg

  # --- authors ----------------------------------------------------------------
  if [ -n "${SHIPLOG_AUTHORS:-}" ]; then
    ALLOWED_AUTHORS_EFFECTIVE="$SHIPLOG_AUTHORS"
    POLICY_SOURCE_AUTHORS="env:SHIPLOG_AUTHORS"
  elif [ "$in_repo" -eq 1 ] && cfg=$(git config --get shiplog.policy.allowedAuthors 2>/dev/null) && [ -n "$cfg" ]; then
    ALLOWED_AUTHORS_EFFECTIVE="$cfg"
    POLICY_SOURCE_AUTHORS="git-config:shiplog.policy.allowedAuthors"
  elif [ -n "$POLICY_ALLOWED_AUTHORS" ]; then
    ALLOWED_AUTHORS_EFFECTIVE="$POLICY_ALLOWED_AUTHORS"
    POLICY_SOURCE_AUTHORS="$POLICY_SOURCE"
  else
    ALLOWED_AUTHORS_EFFECTIVE=""
    POLICY_SOURCE_AUTHORS="default"
  fi

  # --- allowed signers file -----------------------------------------------------
  local signers_raw=""
  if [ -n "${SHIPLOG_ALLOWED_SIGNERS:-}" ]; then
    signers_raw="$SHIPLOG_ALLOWED_SIGNERS"
    POLICY_SOURCE_SIGNERS="env:SHIPLOG_ALLOWED_SIGNERS"
  elif [ "$in_repo" -eq 1 ] && cfg=$(git config --get shiplog.policy.allowedSignersFile 2>/dev/null) && [ -n "$cfg" ]; then
    signers_raw="$cfg"
    POLICY_SOURCE_SIGNERS="git-config:shiplog.policy.allowedSignersFile"
  elif [ -n "$POLICY_ALLOWED_SIGNERS_FILE" ]; then
    signers_raw="$POLICY_ALLOWED_SIGNERS_FILE"
    POLICY_SOURCE_SIGNERS="$POLICY_SOURCE"
  elif [ "$in_repo" -eq 1 ] && cfg=$(git config --path --get gpg.ssh.allowedSignersFile 2>/dev/null) && [ -n "$cfg" ]; then
    # Fallback only: the per-user Git setting never overrides an explicit choice.
    signers_raw="$cfg"
    POLICY_SOURCE_SIGNERS="git-config:gpg.ssh.allowedSignersFile"
  elif [ "$in_repo" -eq 1 ]; then
    signers_raw=".shiplog/allowed_signers"
    POLICY_SOURCE_SIGNERS="default"
  else
    POLICY_SOURCE_SIGNERS="default"
  fi
  SIGNERS_FILE_EFFECTIVE=$(shiplog_policy_resolve_path "$signers_raw")

  # --- require_signed -----------------------------------------------------------
  if [ -n "${SHIPLOG_SIGN:-}" ]; then
    shiplog_bool_var SHIPLOG_SIGN_EFFECTIVE "SHIPLOG_SIGN" "$SHIPLOG_SIGN"
    POLICY_SOURCE_REQUIRE_SIGNED="env:SHIPLOG_SIGN"
  elif [ "$in_repo" -eq 1 ] && cfg=$(git config --get shiplog.policy.requireSigned 2>/dev/null) && [ -n "$cfg" ]; then
    shiplog_bool_var SHIPLOG_SIGN_EFFECTIVE "git config shiplog.policy.requireSigned" "$cfg"
    POLICY_SOURCE_REQUIRE_SIGNED="git-config:shiplog.policy.requireSigned"
  elif [ -n "$POLICY_REQUIRE_SIGNED" ]; then
    shiplog_bool_var SHIPLOG_SIGN_EFFECTIVE "require_signed for environment '$env' in $POLICY_SOURCE" "$POLICY_REQUIRE_SIGNED"
    POLICY_SOURCE_REQUIRE_SIGNED="$POLICY_SOURCE"
  else
    SHIPLOG_SIGN_EFFECTIVE=0
    POLICY_SOURCE_REQUIRE_SIGNED="default"
  fi

  # --- notes ref ----------------------------------------------------------------
  if [ -n "${SHIPLOG_NOTES_REF:-}" ]; then
    NOTES_REF="$SHIPLOG_NOTES_REF"
    POLICY_SOURCE_NOTES_REF="env:SHIPLOG_NOTES_REF"
  elif [ -n "$POLICY_NOTES_REF" ]; then
    NOTES_REF="$POLICY_NOTES_REF"
    POLICY_SOURCE_NOTES_REF="$POLICY_SOURCE"
  else
    NOTES_REF="${NOTES_REF:-refs/_shiplog/notes/logs}"
    POLICY_SOURCE_NOTES_REF="default"
  fi

  # Only the true absence of a document yields defaults. Say so when signing
  # would otherwise be expected (signing requested, or a trust ref is present).
  if [ "$POLICY_SOURCE" = "default" ] && [ "${SHIPLOG_POLICY_QUIET:-0}" != "1" ] && [ "$in_repo" -eq 1 ]; then
    local trust_ref="${TRUST_REF:-refs/_shiplog/trust/root}"
    if [ "$SHIPLOG_SIGN_EFFECTIVE" = 1 ] || git rev-parse -q --verify "$trust_ref" >/dev/null 2>&1; then
      printf '⚠️ shiplog: no policy document found (%s or .shiplog/policy.json); using built-in defaults for environment %s\n' \
        "${POLICY_REF:-refs/_shiplog/policy/current}" "$env" >&2
    fi
  fi

  SHIPLOG_POLICY_LOADED_ENV="$env"
}

# shiplog_policy_enforce
# Side-effect checks for the write/verify path. Requires a prior load.
shiplog_policy_enforce() {
  shiplog_policy_assert_loaded
  if [ "${SHIPLOG_SIGN_EFFECTIVE:-0}" = 1 ]; then
    if [ -z "$SIGNERS_FILE_EFFECTIVE" ]; then
      die "shiplog: signing is required but no allowed signers file is configured"
    fi
    if [ ! -r "$SIGNERS_FILE_EFFECTIVE" ]; then
      die "shiplog: allowed signers file '$SIGNERS_FILE_EFFECTIVE' not found or unreadable (source: $POLICY_SOURCE_SIGNERS)"
    fi
  fi
}

# Guard for helpers that consume the effective values.
shiplog_policy_assert_loaded() {
  [ -n "${SHIPLOG_POLICY_LOADED_ENV:-}" ] || die "shiplog: internal error: policy used before shiplog_policy_load"
}

# shiplog_policy_warnings
# Prints advisory lines (stdout) for `policy show`: a missing signers file while
# signing is on is a warning there, not an error.
shiplog_policy_warnings() {
  shiplog_policy_assert_loaded
  if [ "${SHIPLOG_SIGN_EFFECTIVE:-0}" = 1 ]; then
    if [ -z "$SIGNERS_FILE_EFFECTIVE" ]; then
      printf 'Warning: signing is required but no allowed signers file is configured\n'
    elif [ ! -r "$SIGNERS_FILE_EFFECTIVE" ]; then
      printf 'Warning: allowed signers file %s is missing or unreadable; run `git shiplog trust sync` or fix the path (source: %s)\n' \
        "$SIGNERS_FILE_EFFECTIVE" "$POLICY_SOURCE_SIGNERS"
    fi
  fi
}
