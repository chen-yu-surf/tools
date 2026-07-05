# Phase 8 — Post-audit Quality Review *(user-triggered after Phase 5)*

Trigger: user says `review` (or `audit quality`, `phase 8`) after Phase 5 completes.

This phase spawns a **fresh-context subagent** to evaluate the quality of
the completed audit without the anchoring bias of the same-session reasoning chain.
The subagent receives only the saved `rca_email_body` and a self-contained evaluation rubric —
it has no knowledge of the Phase 1–5 reasoning that produced the email.

Findings are reported in chat, then offered for immediate fix — [BUG], [DATA-GAP], and
[STRUCTURAL] findings are all fixed the same way: auditperf applies the fix itself (with
user confirmation) and commits.

---

## Step 1 — Prepare the review package

Assemble from session state (these are the only values passed to the subagent):

```
review_date   = today's date (YYYY-MM-DD)
fbc_hash10    = fbc_hash[:10]
suite         = extracted from result_root or rca_email_body ## Impact Mechanism
stressor      = same
analysis_mode = bisect-driven / result-search / static-only
static_prediction = (if set; pass as empty string if unset)
rca_email_body = full Phase 4 markdown (all ## sections verbatim)
```

Do **not** pass any other session variables. The subagent must derive everything else from
the email body alone.

---

## Step 2 — Spawn the review subagent

Call:

```python
runSubagent(
    description = "audit quality review",
    prompt = <review_prompt>   # assembled below
)
```

The subagent returns a single structured findings block. Parse it in Step 3.

---

## Review prompt template

Assemble the prompt by substituting session values into the template below.
The prompt is entirely self-contained — the subagent needs nothing else.

```
You are reviewing the quality of a completed Linux kernel performance regression audit.
Your job is to identify gaps in evidence, reasoning, and skill instructions.
You have NO prior knowledge of how this analysis was performed — evaluate only what is
written in the audit output below.

## Audit metadata

- Commit: {fbc_hash10}
- Suite/stressor: {suite}/{stressor}
- Analysis mode: {analysis_mode}
- Date: {review_date}
- Static prediction (if bisect-driven): {static_prediction}

## Audit output to review

{rca_email_body}

---

## Evaluation criteria

Apply each criterion to the audit output above. For each criterion, produce a rating and
a one-sentence justification citing specific text from the audit output.

### Criterion 1 — Evidence chain completeness

The chain must have all four links filled with concrete values:
  metric → profile/stat entry → callgraph/LSP link → FBC-changed function in file.c

Rate:
- **Complete**: all four links are cited with evidence (not inferred)
- **Partial**: one link is stated without citing a specific data point — name the missing link
- **Gap-heavy**: two or more links are inferred — name each gap

If **Partial** or **Gap-heavy**: include a [BUG] or [STRUCTURAL] entry in `criterion_4_findings`
identifying which instruction (which ## section in the audit output) allowed the gap.

### Criterion 2 — Alternative hypothesis coverage

Read `.agents/skills/lkp-auditperf/references/regression-patterns.md` to get the full
list of named regression patterns.

The audit must name ≥2 patterns by their EXACT name from that file, each with a one-line
exclusion that cites a specific data point (metric value, profile entry, correlation.txt
line, or LSP result). Vague exclusions ("unlikely", "possible") do not count.

Rate:
- **Pass**: ≥2 named patterns with data-backed exclusions found in ## Evidence or ## Causal Chain
- **Partial**: patterns named but exclusions lack specific data citations
- **Fail**: fewer than 2 named patterns, or no exclusions at all

If **Partial** or **Fail**: include a [STRUCTURAL] entry in `criterion_4_findings` noting which
section should carry the alternatives and what data was available to support them.

### Criterion 3 — Prediction calibration (bisect-driven / result-search only)

Compare the static_prediction above against the measured outcome in ## Prediction vs Measurement.

Rate: [AGREES] / [PARTIAL] / [CONTRADICTS]

- **[AGREES]**: direction AND mechanism both match the measured outcome
- **[PARTIAL]**: direction matches but mechanism or scale condition differs from measurement
  — explain why the diff alone could not have predicted the discrepancy
- **[CONTRADICTS]**: direction or hw_tag disagrees

If [PARTIAL] or [CONTRADICTS]: include a [STRUCTURAL] entry in `criterion_4_findings` identifying
what information (threshold constant, hardware topology, workload parameter) would have been
needed to predict correctly.

Skip this criterion if analysis_mode is static-only or static_prediction is empty.

### Criterion 4 — Skill improvement candidates

Read the following reference files to check for completeness:
- `.agents/skills/lkp-auditperf/references/domain-reference.md` (Suite Index)
- `.agents/skills/lkp-auditperf/references/domain/suites/{suite}.md` (if it exists)
- The relevant domain subsystem file (e.g. `domain/subsystems/sched.md`) to avoid filing
  findings already captured in the domain files

Identify any of the following visible from the audit output:
- A suite missing from the Suite Index that is now documented in the audit
- A kernel pattern, threshold constant, or hot-path function now confirmed by data that
  is absent from the relevant domain file
- An instruction that was ambiguous and led to an observable output gap (section missing,
  wrong format, inconsistent claim)

For each finding produce a typed entry:
- `[DATA-GAP]` — domain content missing that the audit data could fill
- `[STRUCTURAL]` — instruction ambiguity visible from the output

---

## Required output format

Return ONLY a structured block in this exact format (no preamble, no explanation outside it):

```
PHASE8_REVIEW_START
date: {review_date}
commit: {fbc_hash10}
suite_stressor: {suite}/{stressor}

criterion_1_rating: Complete | Partial | Gap-heavy
criterion_1_note: <one sentence citing specific text>

criterion_2_rating: Pass | Partial | Fail
criterion_2_note: <one sentence>

criterion_3_rating: AGREES | PARTIAL | CONTRADICTS | N/A
criterion_3_note: <one sentence>

criterion_4_findings:
- [TYPE] [references/<file>]: <finding>
- [TYPE] [references/<file>]: <finding>
(or "none" if no findings)
PHASE8_REVIEW_END
```
```

---

## Step 3 — Process findings

Parse the `PHASE8_REVIEW_START … PHASE8_REVIEW_END` block from the subagent's response.

**Immediate fix offer**

- If any `[BUG]` / `[DATA-GAP]` / `[STRUCTURAL]` entries exist: list them in chat and ask
  *"I found N gap(s)/note(s) in the audit. Shall I fix them now?"*
  If yes: apply each fix directly to the relevant skill/reference/domain file and commit
  per `lkp-git-commit` SKILL.md.
- If all criteria passed and no criterion_4 findings: tell the user
  *"Phase 8 complete. No gaps found in this audit."*
