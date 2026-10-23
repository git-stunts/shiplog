{
  "id": "SLT.ALPHA.023",
  "labels": ["tests", "cli", "config", "ci"],
  "milestone": "Alpha",
  "name": "Config wizard tests (Dockerized Bats)",
  "description": "Bats tests cover dry-run plan output, apply side-effects, SaaS vs self-host defaults, threshold coercion, ref_root normalization, explicit vs env dry-run precedence, and mutual exclusion for --apply + --dry-run.",
  "priority": "P1",
  "impact": "Prevents regressions in the new onboarding flow; raises confidence for Alpha readiness.",
  "steps": [
    "Add test file under test/ (config wizard) with matrix-safe helpers",
    "Dry-run: emits valid JSON and no file writes",
    "Apply: writes .shiplog/policy.json and sets git config only when dry_run=0",
    "Defaults: SaaS host → refs/heads/_shiplog + attestation (threshold>1)",
    "Coercion: non-numeric threshold → 1; normalize ref_root to refs/*",
    "Precedence: env dry-run vs explicit; mutual exclusion error on explicit both"
  ],
  "blocked_by": [],
  "notes": ["Implemented in v0.3.0; green in matrix"],
  "created": "2025-10-05",
  "updated": "2025-10-05",
  "estimate": "med",
  "expected_complexity": "medium",
  "status": "complete"
}

