# Security Policy

- Please report security issues privately to <james@flyingrobots.dev>.
- Do not open public issues for vulnerabilities.
- We aim to triage within 72 hours and provide a fix or guidance swiftly.

Hardening notes:

- `git shiplog run` stores the wrapped command's output as a git note and its
  argv in the entry trailer, and pushes both unredacted (#86). Never run
  commands that print secrets, or pass secrets as arguments, through `run`.
- Server-side hooks are only enforceable on self-hosted Git. For GitHub/GitLab
  SaaS, use branch namespace + protected rulesets and required checks. See
  docs/hosting/matrix.md and docs/hosting/github.md.
