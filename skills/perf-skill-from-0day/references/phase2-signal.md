# Phase 2 — Verify / Detect Signal

**If `analysis_mode = bisect-driven`**: run the original signal verification below.
**If `analysis_mode ≠ bisect-driven`**: run the Result Search block instead, then skip to
the Output section.

---

## Track A — bisect-driven signal verification

Run the classifier script with `boundary_valid`, `perf_change`, and `change_direction` from the
Phase 1 manifest:

```bash
.agents/skills/lkp-auditperf/scripts/classify-signal-confidence <boundary_valid> <perf_change> <change_direction>
```

It implements the Magnitude threshold (`|perf_change| < 5%` → `Noise/Flake` regardless of
`boundary_valid`), the Polarity check (`boundary_valid` is always `False` for improvements by
construction — it only detects FBC-caused failures, so the script ignores it and classifies on
magnitude alone when `change_direction=improvement`), and the Confidence rubric below. Read its
`status`, `confidence_estimate`, and `explanation` output lines directly into the JSON below.

**Polarity check note**: for `change_direction: improvement` (FBC raised a "higher-is-better"
metric), the "validated" label in `history.txt` is the bisect's own signal validation and is a
separate concept from `boundary_valid` — do not treat a `False` `boundary_valid` on an
improvement as a weak signal. In Phase 4 Verdict `Fix hint`: write `"N/A — performance
improvement; update test expectation baseline if the gain causes bisect noise in future runs"`
instead of a fix strategy.

## Confidence rubric

The estimate above uses manifest data only — do not wait for Phase 4 evidence. Phase 4
modifiers will refine this estimate into the final Verdict confidence.

| Confidence estimate | Criteria (Phase 1 manifest data only) |
|---|---|
| **High** | `boundary_valid=True` AND `|perf_change| ≥ 20%` |
| **Medium** | `boundary_valid=True` AND `5% ≤ |perf_change| < 20%` |
| **Low** | `boundary_valid=False` but consistent regression present; OR `|perf_change|` in 5–10% range with sparse parent data |

**Phase 4 modifiers** (applied in Phase 4 after evidence review; may upgrade or downgrade the estimate above):
- `[MULTI-METRIC CONFIRMED]` AND `boundary_valid=True` AND single-hop causal chain → upgrades borderline Medium to High
- `[MULTI-METRIC CONFIRMED]` AND `boundary_valid=False` → upgrades one tier (Low → Medium)
- `[SINGLE-METRIC]` → downgrades one tier
- `[HIGH VARIANCE]` on top call stack (std% > 30%) → downgrades one tier
- Multiple modifiers stack (e.g. `[SINGLE-METRIC]` + `[HIGH VARIANCE]` → two-tier downgrade)

Once Phase 4 evidence review has decided which of the above apply, do not work out the tier
arithmetic by hand — pass the base estimate, `data_source_tag`, and modifier tokens
(`upgrade-to-high`, `upgrade-one`, `downgrade-one`, repeatable) to the script and read its
`confidence=` line directly (see `phase4-rca.md`'s "Confidence caps by data source" for the
`data_source_tag` cap applied in the same call):
```bash
.agents/skills/lkp-auditperf/scripts/apply-confidence-modifiers <base_confidence> <data_source_tag> [modifier ...]
```

## Output

Output raw JSON (no markdown wrapper) built from the script's `status` / `confidence_estimate` /
`explanation` fields:

```json
{"status": "Validated Boundary", "confidence_estimate": "High", "explanation": "boundary_valid=true, perf_change=-52%, change_direction=regression"}
```

Valid `status` values: `"Validated Boundary"` · `"Noise/Flake"` · `"Infrastructure Failure"`
Valid `confidence_estimate` values: `"High"` · `"Medium"` · `"Low"` · `"N/A"` (Noise/Flake only)

Then output this checkpoint:

```
Phase 2 ✓
  fbc_hash:            {fbc_hash[:12]}
  status:              {status}
  confidence_estimate: {confidence_estimate}
```

If `status ≠ "Validated Boundary"` → stop and report clearly. Otherwise continue automatically to
Phase 3A.

---

## Track B — result-search / static-only signal detection

**Step 1 — Search for result roots** (run even for `static-only` tentative mode):

```
mcp_shz_lkp_mcp_search_lkp_test_roots(commit=fbc_hash, suite=search_suite or None)
```

If `mcp_shz_lkp_mcp_search_lkp_test_roots` is unavailable: use the SSH fallback from SKILL.md
`## MCP Fallback` (`find /result/<suite or '*'>` via SSH); treat the output the same way.

- If **results found**:
  - Set `analysis_mode = result-search`, `data_source_tag = [RESULT-FOUND]`
  - Record all found result roots; pick the one with the most runs as `result_root`
  - Find the parent commit's result root: `mcp_shz_git_mcp_get_linux_commit(fbc_hash)` → read
    `parents[0]` SHA; search again for parent result roots
  - If parent root found: run `mcp_shz_lkp_mcp_compare_lkp_results([result_root, parent_result_root])`
    → derive `perf_change` from the most regressed metric; set `metric_tag` from count of
    significant deltas (same rules as Phase 3A step 4).
    If unavailable: `ssh <lkp_server> "lkp compare <parent_result_root> <result_root>"` (see SKILL.md `## MCP Fallback`).
  - If parent root not found: set `perf_change = "unknown (parent result absent)"`
  - Set `change_direction`: use `external_metrics[primary].change_direction` if already populated
    (URL-input path); otherwise infer from sign of `perf_change` (`> 0` → `"improvement"`;
    `< 0` → `"regression"`); default `"regression"` when `perf_change` is unknown.
  - `confidence_estimate = Medium` (real data, no bisect validation)
  - `status = "Result Found"`
- If **no results found**:
  - Set `analysis_mode = static-only`, `data_source_tag = [STATIC-ONLY]`
  - Set `perf_change = "N/A"`, `result_root = null`
  - Set `change_direction = "regression"` (no measured data; assume regression for static analysis)
  - `confidence_estimate = Low` (static analysis only)
  - `status = "Static Analysis"`
  - Do NOT stop — proceed to Phase 3B

**Step 2 — Offer job queuing** (for `static-only`; see Phase 3B §Queue section):
Ask the user: *"No result roots found for `{fbc_hash[:12]}`. Shall I queue comparison jobs to
gather real performance data? (yes / no — can proceed with static analysis either way)"*
Record the answer; if yes, Phase 3B §Queue runs after static analysis.

Output this checkpoint:

```
Phase 2 ✓
  fbc_hash:            {fbc_hash[:12]}
  analysis_mode:       {analysis_mode}
  status:              {status}
  confidence_estimate: {confidence_estimate}
  result_root:         {result_root or "none"}
  perf_change:         {perf_change}
  change_direction:    {change_direction}
```

Continue automatically to Phase 3B.
