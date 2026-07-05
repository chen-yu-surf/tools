# Phase 7 — e2e Fixture Entry *(offered after Phase 5)*

> ⏸ **Ask the user**: *"Shall I add an e2e test fixture entry for this case? (yes / no)"*

If yes, synthesize and show the proposed entry before writing:

```yaml
- sha: "<full fbc_hash>"
  expected_report_type: "performance"
  min_confidence: <8 for High confidence, 7 for Medium, 5 for Low>
  expected_keywords:
    - "<2-4 unique identifiers: function names, metric strings, or struct names>"
  expected_patch: "<first line of fix commit subject, double-quoted>"
  required_tools:
    - "<each distinct MCP tool actually called this session>"
```

- `expected_patch`: if no patch was generated, use the RCA symptom as a fallback string.
- Append to `tests/llm/app/auditfbc/fixtures/e2e_cases.yaml` in the lkp-core workspace only after
  the user confirms.
- Commit separately following the `lkp-git-commit` skill
  (`.agents/skills/lkp-git-commit/SKILL.md`):
  `tests: add e2e case for <fbc_hash[:12]>`
