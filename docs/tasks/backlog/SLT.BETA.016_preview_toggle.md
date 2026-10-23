{
  "id": "SLT.BETA.016",
  "labels": ["cli", "ux"],
  "milestone": "Beta",
  "name": "Configurable preview suppression",
  "description": "Introduce a `SHIPLOG_NO_PREVIEW` toggle (and matching flag) to silence write previews for CI/non-interactive environments.",
  "priority": "P3",
  "impact": "Keeps automated logs clean while retaining interactive preview by default.",
  "steps": [
    "Add env/flag plumbing (`--no-preview`?) to skip preview rendering",
    "Ensure structured logging still fires when disabled",
    "Document usage and add tests"
  ],
  "blocked_by": [],
  "notes": [
    "DX feedback suggested optional preview suppression for CI pipelines"
  ],
  "created": "2025-09-30",
  "updated": "2025-09-30",
  "estimate": "small",
  "expected_complexity": "low"
}
