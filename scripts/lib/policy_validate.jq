# jq filter to validate Shiplog policy JSON. Emits one error per line and never
# crashes on malformed shapes: every has()/index access is guarded by a type
# check so a wrong-typed field yields "<path>: <type> required" (exit 1 from
# scripts/policy/validate.sh) instead of a jq error (exit 2).
#
# This filter is the enforcement path (CLI, scripts/policy/validate.sh and the
# pre-receive hook). It mirrors examples/policy.schema.json field for field:
# unknown keys are rejected at every level that the schema closes with
# additionalProperties:false, and every typed field is type-checked.
#
# Version strings are canonical semver (no leading zeros); the schema uses the
# same pattern.

def semver_pattern:
  "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(?:\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$";
# A full ref name under refs/ (no ".." / ".lock" / control characters / "@{" ...).
def ref_pattern:
  "^refs/(?!.*(?:^|/)\\.)(?!.*\\.\\.)(?!.*\\.lock$)(?!.*//@)(?!.*@\\{)(?!.*[~^:?*\\[\\]\\\\])\\S+(?:/\\S+)*$";
# A ref prefix under refs/ that ends with "/".
def ref_prefix_pattern:
  "^refs/(?!.*(?:^|/)\\.)(?!.*\\.\\.)(?!.*\\.lock$)(?!.*//@)(?!.*@\\{)(?!.*[~^:?*\\[\\]\\\\])\\S+/(?:\\S+/)*$";

def top_keys:
  ["schema", "version", "format_compat", "require_signed", "allow_ssh_signers_file",
   "authors", "deployment_requirements", "ff_only", "notes_ref",
   "journals_ref_prefix", "anchors_ref_prefix"];
def authors_keys: ["default_allowlist", "env_overrides"];
def env_keys: ["require_signed", "require_ticket", "require_service", "require_where"];
def allowed_require_where: ["region", "cluster", "namespace", "service", "environment"];

def fieldpath($path; $key): if $path == "" then $key else "\($path).\($key)" end;

def is_string_array: type == "array" and all(.[]; type == "string");
def is_nonempty_string_array: type == "array" and all(.[]; type == "string" and length > 0);
def require_where_ok:
  is_string_array
  and ((unique | length) == length)
  and all(.[]; . as $v | (allowed_require_where | index($v)) != null);

# Emits "<path>.<key>: unknown key" for every key of the input object not in $allowed.
def unknown_keys($path; $allowed):
  keys_unsorted[] | select(. as $k | ($allowed | index($k)) == null) | "\(fieldpath($path; .)): unknown key";

# When $key is present, require that its value satisfies `pred`.
def typed($path; $key; pred; $msg):
  if has($key) then
    if (.[$key] | pred) then empty else "\(fieldpath($path; $key)): \($msg)" end
  else empty end;

def authors_errors:
  if has("authors") then
    if (.authors | type) != "object" then
      "authors: object required"
    else
      (.authors | unknown_keys("authors"; authors_keys)),
      (if (.authors | has("default_allowlist")) then
         (if (.authors.default_allowlist | is_nonempty_string_array and length > 0) then empty
          else "authors.default_allowlist: non-empty array of non-empty strings required" end)
       else
         "authors.default_allowlist: non-empty array of non-empty strings required when authors is present"
       end),
      (if (.authors | has("env_overrides")) then
         if (.authors.env_overrides | type) != "object" then
           "authors.env_overrides: object required"
         else
           (.authors.env_overrides | to_entries[]
             | select((.value | is_nonempty_string_array) | not)
             | "authors.env_overrides.\(.key): array of non-empty strings required")
         end
       else empty end)
    end
  else empty end;

def env_entry_errors($name):
  ("deployment_requirements.\($name)") as $path
  | if type != "object" then
      "\($path): object required"
    else
      unknown_keys($path; env_keys),
      typed($path; "require_signed"; type == "boolean"; "boolean required"),
      typed($path; "require_ticket"; type == "boolean"; "boolean required"),
      typed($path; "require_service"; type == "boolean"; "boolean required"),
      typed($path; "require_where"; require_where_ok;
            "unique array of allowed strings (region, cluster, namespace, service, environment) required")
    end;

def deployment_errors:
  if has("deployment_requirements") then
    if (.deployment_requirements | type) != "object" then
      "deployment_requirements: object required"
    else
      (if (.deployment_requirements | length) > 0 then empty
       else "deployment_requirements: must contain at least one environment" end),
      (.deployment_requirements | to_entries[] | .key as $name | .value | env_entry_errors($name))
    end
  else empty end;

if type != "object" then
  "policy: object required"
else
  unknown_keys(""; top_keys),
  (if has("version") and (.version | type) == "string" and (.version | test(semver_pattern)) then empty
   else "version: semver string (e.g. 1.0.0) required" end),
  typed(""; "schema"; type == "string"; "string required"),
  typed(""; "format_compat"; type == "string"; "string required"),
  typed(""; "require_signed"; type == "boolean"; "boolean required"),
  typed(""; "ff_only"; type == "boolean"; "boolean required"),
  typed(""; "allow_ssh_signers_file"; type == "string" and length > 0; "non-empty string required"),
  typed(""; "notes_ref"; type == "string" and test(ref_pattern); "Git ref under refs/ required"),
  typed(""; "journals_ref_prefix"; type == "string" and test(ref_prefix_pattern);
        "ref prefix under refs/ ending in / required (reserved; not yet honored)"),
  typed(""; "anchors_ref_prefix"; type == "string" and test(ref_prefix_pattern);
        "ref prefix under refs/ ending in / required (reserved; not yet honored)"),
  authors_errors,
  deployment_errors
end
