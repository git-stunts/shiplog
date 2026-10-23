{
  "id": "SLT.ALPHA.027",
  "labels": ["ci", "lint", "quality"],
  "milestone": "Alpha",
  "name": "CI: flip linters to blocking",
  "description": "Tighten CI by making shellcheck, markdownlint-cli2, and yamllint fail the build once baseline issues are resolved. Maintain lightweight suppressions where needed.",
  "priority": "P2",
  "impact": "Prevents regressions and keeps docs/scripts tidy as the project grows.",
  "steps": [
    "Triage current lint outputs and add minimal suppressions",
    "Flip continue-on-error settings to strict",
    "Add a brief CONTRIBUTING note about linting"
  ],
  "blocked_by": [],
  "notes": ["Use consistent versions across matrix"],
  "created": "2025-10-05",
  "updated": "2025-10-05",
  "estimate": "med",
  "expected_complexity": "medium"
}

