{
  "id": "SLT.ALPHA.028",
  "labels": ["release", "versioning"],
  "milestone": "Alpha",
  "name": "Tag v0.3.0 and update changelog",
  "description": "Prepare a v0.3.0 release including the Config Wizard, hosting cross-links, trust gate docs, and fixes. Update CHANGELOG.md and tag the release after CI is green.",
  "priority": "P2",
  "impact": "Communicates progress and provides a stable reference for adopters.",
  "steps": [
    "Draft CHANGELOG.md entries",
    "Verify release build/tests across matrix",
    "Tag v0.3.0 and push tags"
  ],
  "blocked_by": ["SLT.ALPHA.033", "SLT.ALPHA.023"],
  "notes": ["Consider a GitHub Release with notes and links"],
  "created": "2025-10-05",
  "updated": "2025-10-05",
  "estimate": "small",
  "expected_complexity": "low"
}

