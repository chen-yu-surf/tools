# Phase 4 — Root Cause Analysis *(runs automatically → proceeds directly to Phase 5)*

**Role anchor**: You are an expert Linux kernel performance engineer. Your RCA must be defensible to kernel maintainers on LKML. The audience knows kernel internals — write at that level. Every claim must trace to evidence; every inference must be labeled as such.

Evidence snippets from tool output are **mandatory** — do not assert conclusions without quoting them.
Assume `a`/`mean_a` = FBC, `b`/`mean_b` = baseline.

## Step 1 — Coverage gate + commit fetch

From `correlation.txt` (Phase 3a):
- A changed file is **disabled** if it shows only `|- miss CONFIG_*` entries (no `|- y`, no
  `|- CONFIG_XXX=y`, no `CC …` line)
- If **every** changed file is disabled → **FBC cannot be root cause; stop and report clearly**
- If at least one file shows `|- y`, `|- CONFIG_XXX=y`, or `CC …` → code was compiled → proceed

Run the gate mechanically instead of eyeballing the file — read `file=`/`status=` and the final
`gate=` line directly, do not re-derive them by hand:
```bash
.agents/skills/lkp-auditperf/scripts/check-coverage-gate <correlation.txt>
```
`gate=fail` → stop and report clearly (per-file `status=disabled` lines are the evidence). `gate=pass`
→ proceed; treat any `status=enabled` file as compiled.

**In `bisect-driven` mode** the diff was already fetched in Phase 3 Step 0 — use the
already-loaded diff; skip re-fetching. For `result-search` or `static-only` modes: call
`mcp_shz_git_mcp_get_linux_commit(fbc_hash)` now. If fails: stop — cannot proceed without the diff.

**Patch analysis** — complete this structured block immediately after loading the diff, before any
RCA reasoning:
1. *Mechanism* (1–2 sentences): what the commit changes in the codebase — factual description only,
   no performance inference
2. *Key snippets*: quote verbatim the 2–3 lines most likely responsible for the performance impact,
   with `file.c:function()` citations — do NOT paraphrase diffs
3. *Path connection* (subject to Evidence Attribution Tiers below): one sentence connecting the
   changed code to the stressor's hot path; omit if no callgraph or LSP evidence links them

**Merge commit**: if subject begins `"Merge branch"`, `"Merge tag"`, or `"Merge remote"` → examine
parent SHAs, call `mcp_shz_git_mcp_get_linux_commit` on 1–3 merged commits touching perf-sensitive paths.
Note: *"FBC is a merge commit — true change: {actual_sha}"*.

**Diff rules:**
- Massive tree-wide refactor → grep for stressor's syscalls to narrow to 1–2 relevant files
- Non-x86 arch only (all changes under `arch/arm*/`, `arch/riscv/`, `arch/mips/`, `arch/powerpc/`,
  `arch/s390/`, `arch/loongarch/`; no changes to `arch/x86/`, `kernel/`, `mm/`, `fs/`, `include/`)
  → cannot be root cause on x86
- Config-gated code → verify config enabled in `{result_root}/config`; disabled code cannot regress
- FBC changes only `tools/perf/` or `tools/testing/selftests/` but causes kernel regression → FBC
  is an *exposing commit*; identify the true kernel fault regardless
- **Security** (subject or body contains `CVE-`, `[vuln]`, `spectre`, `meltdown`, `IBRS`, `STIBP`,
  `SSBD`, `retbleed`, `MDS`, `TAA`, `MMIO Stale Data`, or references `security@kernel.org`) → do
  **not** recommend revert; note security context; find reduced-overhead mitigation; recommend
  updating test expectation baseline; proceed to Phase 5
- **Functional fix** ("fix use-after-free", "fix race condition", "fix memory leak", "fix overflow")
  → do **not** recommend revert; generate a patch that reduces regression without breaking the fix

**Profile-diff overlap** — perform immediately after reading diff, before writing any RCA
text. Compare FBC-modified functions/files against the **full** recorded call chain from each top
positive-delta profile entry (check every hop, not just the leaf):

| Overlap | Interpretation | Verdict row value |
|---|---|---|
| Profile entry **directly in** FBC diff | True root cause | `Yes — profile entry {fn} in FBC-modified {file}` |
| Profile entry **one hop from** FBC-changed fn | True root cause (likely) | `Yes (one-hop) — {fn} calls FBC-modified {fn2}` |
| **No overlap** | Exposing commit likely | `No — profile entries in {A}, FBC only touched {B}` |
| **Partial overlap** | FBC overhead + pre-existing bottleneck | `Partial — {matched_fn} direct; {unmatched_fn} pre-existing` |

## Step 2 — Trace via LSP

**LSP is always required** for code-level traversal. Use the `site` session variable (resolved in
Phase 1 from `bisect_tag`, default `shz`) as the `<site>` prefix below — never hardcode `shz`.
After Step 1 coverage gate passes:
1. `mcp_<site>_lsp_mcp_init_lsp_workspace(workspace_id=lkp-auditperf-{fbc_hash[:12]}, fbc_hash={fbc_hash}, build_dir={result_root})`
2. For every function changed by the FBC: call `mcp_<site>_lsp_mcp_get_lsp_references` (find all
   callers) and `mcp_<site>_lsp_mcp_get_lsp_definition` (read the implementation in context) **in
   parallel across all changed functions** — these are independent per-function lookups; do not
   serialize them one function at a time.
3. For **header/inline** changes and `[CHAIN TRUNCATED]` chains: extend upward via `mcp_<site>_lsp_mcp_get_lsp_references` on the topmost visible frame until the stressor's syscall entry is reached.
4. `mcp_<site>_lsp_mcp_cleanup_lsp_workspace(workspace_id)` after Phase 4 is complete.

If `mcp_<site>_lsp_mcp_init_lsp_workspace` fails: record gap in `## Evidence`; fall back to
`mcp_shz_git_mcp_grep_repo` + `mcp_shz_git_mcp_read_repo_file` for all code search/grep (do not use plain SSH
grep as primary). Kernel source content is identical across sites, so the git_mcp fallback stays
on `shz` even when `site = igk`.

**`mcp_shz_git_mcp_grep_repo` stale-repo warning**: the MCP server's linux tree may be behind the FBC
commit. If `mcp_shz_git_mcp_grep_repo` returns the **old** pattern (e.g. `tg->cfs_rq[cpu]` when the FBC
introduced `tg_cfs_rq(tg, cpu)`), the cached repo is stale. Fall back to SSH to read the post-FBC
state of specific files:
```
ssh <lkp_server> "git -C /var/repo/linux show <fbc_hash> -- <path/to/file.c>"
```

**Extend `[CHAIN TRUNCATED]`**: call `mcp_<site>_lsp_mcp_get_lsp_references` on the topmost visible frame to trace
upward toward the stressor's entry syscall.

## Step 3 — Index test suite source (if applicable)

If Phase 3b found a test suite URL: `mcp_shz_git_mcp_ensure_repo` + `mcp_shz_git_mcp_grep_repo` +
`mcp_shz_git_mcp_read_repo_file` to trace syscalls and hot loops. Do NOT clone locally.
If `mcp_shz_git_mcp_ensure_repo` fails: skip Step 3; note gap in `## Evidence`.

## Step 4 — Establish the causal chain

**At Step 4 start**, read [regression-patterns.md](regression-patterns.md) for the 8 regression
patterns and fix-approach table. Cross-reference against the loaded subsystem file for
subsystem-specific hints (e.g. [domain/subsystems/mm.md](domain/subsystems/mm.md) for mm regressions).

**Evidence Attribution Tiers** — enforced across ALL output sections and the email body. Causation
claims must match the evidence tier; path-level data justifies only correlation language.

| Data available | Permitted claim | Prohibited |
|---|---|---|
| Path-level perf-sched / perf-stat only | *"delay increased on path X"* (correlation) | *"change Y caused the delay"* — causation without callgraph |
| Callgraph profile (`perf_profile_fbc.txt`, flamegraph) | *"cycles land in fn Z → calls FBC-modified fn W"* (callgraph-backed) | Function-level causation without a traced chain |
| perf annotate / full reproducer | Instruction-level attribution | — |
| Static diff only (`[STATIC-ONLY]`) | *"this change appears to…"* / *"likely introduces…"* | Any measured-data language (`"confirmed"`, `"caused"`, `"the regression is"`) |

State the evidence tier explicitly in `## Impact Mechanism` and `## Causal Chain`.

**Syscall intersection** (mandatory — choose strongest evidence):
1. Full perf-profile chain including syscall entry: quote verbatim
2. LSP-extended chain (if `[CHAIN TRUNCATED]`): cite upward trace from Step 2
3. domain-reference.md table entry (if perf-profile absent): note data gap

**Cross-subsystem mismatch**: compare FBC's primary subsystem (from changed file paths, e.g.
`kernel/sched/fair.c` → `sched`) against stressor's expected subsystem (from the loaded suite
file). If different AND profile-diff overlap shows "no overlap": investigate the dependency chain
(CPU share, memory pressure, IRQ budget, lock order). Confirmed link → **indirect regression**;
unconfirmed → **exposing commit**.

**Pattern matching**: use the Regression Patterns table from regression-patterns.md. Pre-classified
tag narrows candidates: `[MEMORY-BOUND]` → struct layout / NUMA locality / false sharing;
`[LOCK-CONTENTION]` → lock contention; `[TLB-BOUND]` → TLB shootdown.

**Coverage confirmation**: quote the exact `correlation.txt` entry for each changed file.

## Step 5 — Check for existing fix

Search the kernel tree for any patch already addressing this regression. This avoids duplicating
work that the community has already done.

1. `mcp_shz_git_mcp_grep_repo(pattern="Fixes: {fbc_hash[:12]}", repo="linux")` — find any commit in the
   tree with a `Fixes:` tag referencing the FBC.
2. If found: record `fix_status = "fix posted: <commit subject>"`.
3. If not found: record `fix_status = "unaddressed"`.
4. If `mcp_shz_git_mcp_grep_repo` fails or is unavailable: record `fix_status = "unknown"` and continue.

Carry `fix_status` into the pre-output scratchpad and `## Community Awareness`.

## Step 6 — Optimization Discovery *(improvements only — skip if `change_direction == "regression"`)*

If `change_direction == "improvement"`: read
[phase4-optimization.md](phase4-optimization.md) now and complete 6a/6b before continuing. If
`change_direction == "regression"`: skip this step entirely — do not load that file.

## Required pre-output scratchpad (write this BEFORE any ## section)

Force your reasoning into this block first. Do not skip it.

```
Analysis mode: {analysis_mode} / {data_source_tag}

Profile-diff overlap:
  Commit modified:    {key functions/files changed}
  Top profile entries: {top 3 positive-delta function names, or "N/A — static analysis" if no perf data}
  Overlap result:     {Direct | One-hop | None | Partial | N/A (static)}
  Evidence tier:      {Path-level correlation | Callgraph-backed | Reproducer | Static diff only}
  LLM inference:      {1-sentence reasoning chain from Phase 3B step 3c, if static-only}

Alternatives ruled out:
  1. {Alternative A} — ruled out: {reason from diff/perf/LLM reasoning}
  2. {Alternative B} — ruled out: {reason}
  (For improvements: name ≥2 alternative optimization techniques considered; cite diff/profile for why this technique was chosen over them)

Static prediction: {static_prediction value, or "N/A — not bisect-driven"}
Prediction agreement: {[AGREES] | [PARTIAL] | [CONTRADICTS] | N/A}
Conclusion: {1 sentence root cause or predicted impact}
Fix status: {fix_status from Step 5}
```

## Required output sections (order fixed; verdict first, evidence last)

**Output prohibitions** — apply to ALL sections and the email body:
- The final report MUST be fully self-contained — do not assume the reader has the bisect report
  available or will switch context to check it; include all facts needed to understand and validate
  the regression classification without reading any other document
- Do NOT dump all perf-stat / perf-profile rows indiscriminately — select the 5 most informative
  metric rows for `## Evidence`; omit rows that do not bear on the classified regression type
- Do NOT explain standard kernel concepts (RCU, spinlock semantics, TLB, cacheline, slab,
  refcounting, NUMA) — assume the reader knows; write for kernel developers
- Do NOT paraphrase diffs — quote code verbatim with `file.c:function()` citations
- Do NOT assert causation without callgraph evidence (see Evidence Attribution Tiers above)

- `## Summary` — exactly 2 plain-language sentences for a reader who has not seen the bisect report or diff.
  Written to answer: *what happened, how confident are we, is it the root cause, and what should be done next?*
  Do NOT explain the kernel mechanism here — that belongs in `## Impact Mechanism`.
  **CRITICAL — follow the template EXACTLY**: write exactly the 2 template sentences filling their slots; stop after `fix_hint_one_phrase`. Do not add a 3rd sentence, do not expand the fix hint into a mechanism description, and do not name kernel internals (`mmap_miss`, `VM_FAULT_NOPAGE`, `MMAP_LOTSAMISS`, function names, etc.) in this section.
  **CRITICAL — format is sentences, not a table**: do NOT render `## Summary` as a Field/Value metadata table
  (listing Commit, Subject, Hardware, Kernel, OS, Primary metric, Change, Confidence, Fix status as rows).
  That layout has never been correct. The section must be plain prose only.
  - `bisect-driven` / regression: *`{fbc_hash[:10]}` causes a {perf_change} regression in {suite}/{stressor}. Root cause confirmed ({confidence} confidence): {fix_hint_one_phrase}.*
    — `fix_hint_one_phrase` must be ≤ 10 words naming the fix action (e.g. *"restore partial mmap_miss credit in filemap_map_pages()"*), not a mechanism explanation.
    — `is_true_root_cause == false`: replace "Root cause confirmed" with "Root cause not confirmed — FBC is an exposing commit; underlying fault: {fault_description}."
  - `result-search` / regression: *`{fbc_hash[:10]}` likely causes a {perf_change} regression in {suite}/{stressor} ({confidence} confidence). Proposed fix: {fix_hint_one_phrase}.*
  - `static-only` / regression: *`{fbc_hash[:10]}` is predicted to degrade {affected_suites} performance ({confidence} confidence). Proposed fix: {fix_hint_one_phrase}. (No measured data — static analysis only.)*
  - `bisect-driven` / improvement: *`{fbc_hash[:10]}` improves {suite}/{stressor} by {perf_change}. Root cause confirmed ({confidence} confidence) via {technique_label}. Top generalization candidate: {top_candidate_function} in {candidate_file}.*
  - `result-search` / improvement: *`{fbc_hash[:10]}` likely improves {suite}/{stressor} by {perf_change} ({confidence} confidence) via {technique_label}. Top generalization candidate: {top_candidate_function} in {candidate_file}.*
  - `static-only` / improvement: *`{fbc_hash[:10]}` is predicted to improve {affected_suites} performance ({confidence} confidence) via {technique_label}. (No measured data — static analysis only.)*
- `## Verdict` — exactly the 8-row table below; no other format is acceptable.
  **CRITICAL — Verdict is a table, not a paragraph**: do NOT render `## Verdict` as a prose paragraph
  starting with `[REGRESSION] [MEMORY-BOUND] …` tags followed by a mechanism explanation.
  Mechanism explanation belongs in `## Impact Mechanism`, not here.
  | | |
  |---|---|
  | **Regression** or **Improvement** | Use `**Regression**` as the row label for regressions; use `**Improvement**` for improvements. Cell value: `{metric}` {perf_change} (or `Predicted — {impact_direction}` for static-only) |
  | **Commit** | `{fbc_hash[:10]}` — {commit_subject} |
  | **True root cause** | Yes/No/Predicted — cite profile-diff overlap or LLM inference chain. In `bisect-driven` mode this row IS the audit's answer to "is the bisect report's causal attribution correct?": `Yes` confirms it; `No` means the bisect correctly found the triggering commit but it is an exposing commit, not the true mechanism — state the underlying fault instead |
  | **Confidence** | {High/Medium/Low} — one-sentence justification including modifiers applied |
  | **Data source** | `[BISECT-REPORT] {mail_subject}` / `[RESULT-FOUND]` / `[STATIC-ONLY]` — for bisect reports, render as **two lines** using `<br>` (both lines are required): first line `[BISECT-REPORT] {mail_subject}` (shz format: `[shz] [validated N] {hash} bisect for {metric}`, e.g. `[BISECT-REPORT] [shz] [validated 1] 0b9c0aeba9 bisect for pts.graphics-magick.Swirl.iterations_per_minute`), second line `{email_archive_server}:{report_path}` (from Phase 1 variables, e.g. `inn:/result/pts.graphics-magick/Swirl/lkp-gnr-2sp3/.../0b9c0aeba938`); omit second line for non-bisect modes |
  | **hw_tag** | `{hw_tag}` from Phase 3 (`[MEMORY-BOUND]` / `[TLB-BOUND]` / `[LOCK-CONTENTION]` / `none`) |
  | **Regression type** | `{regression_type}` from Phase 4 JSON (`[MEMORY-BOUND]` / `[LOCK-CONTENTION]` / `[TLB-BOUND]` / `general`) — note if it differs from hw_tag |
  | **Fix hint** | one-line fix strategy (regressions) · `Optimization pattern: {technique_label}` (improvements) |
- `## Impact Mechanism` — structured in three parts:
  - *Test case* (always first, 1 sentence): what the test case does, what syscalls it exercises,
    and why those syscalls reach the FBC's changed code path. Use `test_case_description` from
    Phase 3b. This sentence must make the performance change rational to a reader who has not
    seen the job.yaml — it justifies why changing the FBC's subsystem would affect this
    benchmark at all. Cover the test type (not just stressor name), the key syscalls, and
    the kernel path link.
    Example: *"stress-ng/session creates 192 POSIX session leaders via setsid(2)/fork(2),
    driving high-frequency CFS task-group enqueue/dequeue events that dereference
    tg->cfs_rq[cpu] on every scheduling cycle."*
  - *Measured facts* (second): what the data shows, using only correlation language when
    only path-level perf-sched/perf-stat is available — e.g. *"latency increased X% on path Y"*.
    Quote the verbatim perf-profile entry (with file:line from the diff) if present.
    **CRITICAL — do NOT include a metric delta table here**: inline metric references
    (e.g. *"major faults increased +5895%"*) are acceptable; a full `| Metric | Before | After |`
    table is not. The metric delta table belongs exclusively in `## Evidence`.
  - *Causal inference* (third, only when callgraph or LSP chain links the FBC to the hot path):
    label explicitly — *"likely caused by…"* / *"appears to originate from…"* / *"based on
    the diff, the added …"*. Omit entirely rather than assert causation without evidence.
  For `[STATIC-ONLY]`: only the inference part exists; prefix the entire paragraph with
  *"Static analysis predicts…"* and end with *"(no measured data)"*.
- `## Causal Chain` — mermaid flowchart for in-IDE display, starting from the test case logic
  and following the full chain to the bottleneck. Use `test_case_description` from Phase 3b:
  ```
  flowchart LR
    tc["{suite}/{test_case}<br/>{test_case_description.what}"] --"{test_case_description.syscalls}"--> entry["kernel entry<br/>(syscall handler)"]
    entry --> path["{test_case_description.path<br/>first hop}"] --> ... --> bottleneck["{bottleneck}<br/>(before FBC)"]
  ```
  **CRITICAL**: Use `<br/>` (not `\n`) for multi-line text inside node labels. Raw `\n` renders
  as literal backslash-n text in mermaid.ink; `<br/>` renders as a proper line break.
  Omit nodes for which there is no evidence (callgraph or LSP chain). If only diff-level evidence
  is available, collapse the middle hops into a single inference node labeled *"[inferred path]"*.
  Follow the mermaid block with 1–2 sentence text summary: first sentence states what the measured
  data shows (correlation, path-level); second sentence (only if callgraph/LSP chain exists) states
  the inferred mechanism using *"likely"* / *"appears to"*.
  **When no callgraph or LSP chain exists** (diff-only evidence, e.g. `debug_mode: 0`): open the
  text summary with the tag `[INFERRED — no callgraph]` so the reader knows the causal link is not
  data-backed. Example: *"[INFERRED — no callgraph] Based on the diff, the reduced decrement
  appears to cause…"*
- `## Evidence` — the following are required to make the report self-contained and the regression
  classification defensible to a reader who has NOT seen the bisect report:
  - Metric delta: quoted from compare file (or `[STATIC-ONLY — no perf data]`)
  - Top 3 exact `correlation.txt` line(s) for each changed file
  - **Alternative hypothesis exclusions** — for each of ≥2 regression patterns considered and
    rejected, one line naming the exact pattern (from `regression-patterns.md`) and the specific
    data point that excludes it (metric value, profile entry, `correlation.txt` line, or LSP
    result). Vague exclusions (*"unlikely"*, *"possible"*) do not satisfy this requirement.
    These must appear in `## Evidence` (or `## Causal Chain`) — not only in the scratchpad.
  - **Classification-supporting environment fact** — the one hardware fact that makes the
    regression type classification credible; without it the reader cannot validate the tag:
    - `[LOCK-CONTENTION]`: CPU count and socket count — reader can judge whether contention
      scaling at this thread count is plausible
    - `[MEMORY-BOUND]`: NUMA node count and memory-per-node — reader can judge whether the
      workload footprint exceeds per-node memory, making locality sensitivity credible
    - `[TLB-BOUND]`: CPU microarch (e.g. Haswell, Sapphire Rapids) — TLB flush costs differ
      significantly by generation; reader needs this to judge the overhead magnitude
    - `general`: stressor parameters from job.yaml that set the workload intensity
  Source: read from `{result_root}/job.yaml` or `hosts/{tbox}`. Do not include compiler version
  or kernel config flags (already verified in Step 1 coverage gate — not needed here)
- `## Prediction vs Measurement` *(bisect-driven and result-search only — omit for static-only)*:
  Compare `static_prediction` (Phase 3 Step 0) against the bisect evidence:
  - **Static prediction**: render as a 4-row table (not a pipe-delimited one-liner):
    | Field | Value |
    |---|---|
    | Direction | {direction} |
    | Mechanism | {mechanism_1_sentence} |
    | hw_tag | {hw_tag} |
    | scale_condition | {scale_condition_or_none} |
  - **Bisect outcome**: actual `direction`, `hw_tag`, `perf_change` from bisect evidence
  - **Agreement tag**: one of:
    - `[AGREES]` — direction and mechanism both match
    - `[PARTIAL]` — direction matches but mechanism or scale condition differs
    - `[CONTRADICTS]` — direction or hw_tag disagrees
  - **Gap explanation** (required for `[PARTIAL]` or `[CONTRADICTS]`): 1–2 sentences explaining
    why they differ. Common causes: scale amplification invisible in the diff, exposing-commit
    pattern (small diff but large measured regression because a latent fault was exposed),
    environment-specific effect (NUMA topology, CPU microarch), multiple concurrent changes
    inside a merge commit, or a **threshold-constant cliff** — the FBC changes a rate feeding a
    fixed constant (`MMAP_LOTSAMISS`, `MAX_RETRY`, a `HZ`-based timeout, `WARN_ON_ONCE`, a fixed
    array size) and the static diff can only see the rate change, not the saturation point. For
    this last case, tag `[PARTIAL]` (never `[AGREES]`) even if direction and mechanism otherwise
    match, and state: *"direction matched but the cliff at {constant}={value} is invisible
    without tbox fault-count data."*
  - When `[CONTRADICTS]`: prefer bisect data for the final verdict but set
    `is_true_root_cause = false` if static analysis suggests the regression has a deeper cause
    not visible in the FBC diff.
  Omit this section if `static_prediction` is unset.
- `## Fix Strategy` — concrete: file/function, technique, why it resolves the bottleneck.
  **Skip this section for improvements** — replace with `## Optimization Opportunities` below.
- `## Optimization Opportunities` *(improvements only — omit for regressions)*:
  This section is **not** about the commit itself. It identifies OTHER functions elsewhere in the
  kernel that share the same inefficiency pattern as `fbc_hash` and have not yet received the
  same optimization treatment — they are candidates for a follow-up patch (Phase 5).
  - **Pattern**: `{technique_label}` — one sentence describing the before-state inefficiency and
    the technique `fbc_hash` used to fix it
  - **Candidates** (from Step 6b): table of top 3 similar code paths in OTHER files/functions:
    | File | Function | Pattern match | Effort |
    |---|---|---|---|
    | `file.c` | `function()` | why the same technique applies | Easy / Medium / Hard |
  - Omit this section entirely if `change_direction == "regression"`
- `## Community Awareness` — 1–2 sentences from Step 5: community awareness, performance concerns
  raised during review, and fix status (`fix_status` value). Use `✅` if fixed, `❌` if
  unaddressed, `⚠️` if acknowledged. Omit section if `fix_status = "unknown — lore search unavailable"`.

Append raw JSON (no markdown wrapper):

```json
{"confidence": "High", "is_true_root_cause": true, "regression_type": "[LOCK-CONTENTION]"}
```

Valid `confidence` values: `"High"` · `"Medium"` · `"Low"`
`is_true_root_cause`: boolean `true` or `false`
Valid `regression_type` values: `"[MEMORY-BOUND]"` · `"[LOCK-CONTENTION]"` · `"[TLB-BOUND]"` · `"general"`

**Confidence caps by data source** (applied before Phase 4 modifiers):

| `data_source_tag` | Confidence cap | Reason |
|---|---|---|
| `[BISECT-REPORT]` | None (cap = High) | Full validated signal |
| `[RESULT-FOUND]` + perf profile | Medium → High allowed via modifiers | Real data, no bisect validation |
| `[RESULT-FOUND]` no perf profile | Cap at Medium | Real data, no call-stack evidence |
| `[STATIC-ONLY]` | Cap at Low | No measured regression |

Apply the modifiers from `phase2-signal.md` and this cap together in one call — pass the script
the tag matching the row above (`BISECT-REPORT`, `RESULT-FOUND-WITH-PROFILE`,
`RESULT-FOUND-NO-PROFILE`, or `STATIC-ONLY`) and read its `confidence=` line as the final Verdict
`confidence` value directly, instead of manually working out tier arithmetic and the cap:
```bash
.agents/skills/lkp-auditperf/scripts/apply-confidence-modifiers <base_confidence> <data_source_tag> [modifier ...]
```

The cap is applied last — `[MULTI-METRIC CONFIRMED]` can raise `[RESULT-FOUND]` from Medium to High,
but cannot raise `[STATIC-ONLY]` above Low.

Then output this checkpoint (compacts all session state for Phases 5–6):

```
Phase 4 ✓
  fbc_hash:           {fbc_hash[:12]}
  result_root:        {result_root}
  metric_tag:         {metric_tag}
  hw_tag:             {hw_tag}
  confidence:         {confidence}
  is_true_root_cause: {is_true_root_cause}
  regression_type:    {regression_type}
```
(confidence ∈ `"High"` · `"Medium"` · `"Low"`)
(is_true_root_cause ∈ `true` · `false`)
(regression_type ∈ `"[MEMORY-BOUND]"` · `"[LOCK-CONTENTION]"` · `"[TLB-BOUND]"` · `"general"`)

Build the email markdown body and **save it as `rca_email_body`** in session state.

**Pre-flight checklist** — mechanical preconditions; apply corrections before building `rca_email_body`:

- □ **Pre-output scratchpad was filled in** with concrete values in all six fields — no `{template}` placeholders remaining.
  → If incomplete: fill from the Steps 1–5 analysis now; do not emit sections with unfilled placeholders.
- □ **`## Summary` is prose, not a table**: the section must contain 2-3 sentences only — no Field/Value rows.
  → If it is a table: rewrite as sentences following the mode-specific template above.
- □ **`## Verdict` is an 8-row table, not a paragraph**: the section must be the table with rows Regression/Improvement, Commit, True root cause, Confidence, Data source, hw_tag, Regression type, Fix hint — no `[TAG]` paragraph.
  → If it is a paragraph: replace with the 8-row table; move mechanism text to `## Impact Mechanism`.
- □ **Coverage gate was applied**: every FBC-changed file checked against `correlation.txt`; all-disabled case halted with a clear report.
  → If skipped: check now; downgrade confidence or stop as appropriate.
- □ **`fix_status` was populated** from Step 5 grep — not left unset.
  → If unset: run Step 5 now; record `"unaddressed"` only after grep returns no results.
- □ **LSP workspace was cleaned up** (`mcp_<site>_lsp_mcp_cleanup_lsp_workspace(workspace_id)` called).
  → If not: call it now before emitting output.

**Analysis quality self-check** — reasoning accuracy review; revise any section that fails.
Each correction is labeled: *(tool re-execution)* requires calling a tool; *(output revision)* rewrites already-loaded information only.

- □ **Profile-diff overlap was explicitly evaluated** and one of the four outcomes (Direct / One-hop / None / Partial) is recorded in the scratchpad — not left implicit or assumed.
  → If implicit: *(tool re-execution)* compare the top-3 positive-delta profile functions against FBC-modified functions via `mcp_<site>_lsp_mcp_get_lsp_references` if needed; record the outcome.
- □ **At least 2 alternative hypotheses were actively ruled out** in both the scratchpad AND `## Evidence`.
  **Pass condition**: `## Evidence` contains ≥2 named patterns (exact names from `regression-patterns.md`), each with a one-line data-backed exclusion (metric value, profile entry, `correlation.txt` line, or LSP result). Scratchpad-only exclusions without mirroring in the output fail this check.
  → If fewer than 2 with evidence-backed exclusions in `## Evidence`: *(output revision)* revisit the regression patterns table; name two candidates, state which specific evidence excludes each, and add them to `## Evidence`.
- □ **`regression_type` tag is consistent with the dominant evidence**.
  **Pass condition**: `[LOCK-CONTENTION]` → a lock-related function is named from the positive-delta profile (not just the diff); `[MEMORY-BOUND]` → a cache-miss counter, NUMA allocation, or false-sharing signal is cited; `[TLB-BOUND]` → a TLB-flush function appears in the positive-delta profile. If only the diff is the basis and profile data exists, the tag fails.
  → If inconsistent: *(output revision)* correct the tag and update the Verdict and JSON accordingly.
- □ **`## Impact Mechanism` has all three parts** in order: *Test case* → *Measured facts* → *Causal inference* (or only inference for static-only, prefixed with "Static analysis predicts…").
  → If a part is missing: *(output revision)* add it — the *Test case* sentence is mandatory even when the connection seems obvious.
- □ **`## Evidence` contains the three required elements**: (a) metric delta quoted verbatim, (b) top 3 `correlation.txt` lines, (c) classification-supporting environment fact.
  → If any element is absent: *(tool re-execution)* read the data source now and insert it.
- □ **Fix strategy addresses the profiled hot spot**.
  **Pass condition**: the patched function appears in the positive-delta profile OR is stated as ≤1 callgraph hop from the top positive-delta entry with the hop explicitly cited. If the function only appears in the FBC diff but not in the profile, that must be stated explicitly.
  → If not justified: *(output revision)* explain why the fix targets a function not directly in the profile, or reconsider the fix target.
- □ **Confidence cap was applied last**: `[STATIC-ONLY]` → cap at Low; `[RESULT-FOUND]` without perf profile → cap at Medium.
  **Pass condition**: if `data_source_tag == [STATIC-ONLY]` and `confidence != "Low"`, it fails automatically.
  → If exceeding cap: *(output revision)* lower confidence now and update the Verdict Confidence row.
- □ **Every causal claim cites the evidence tier**; every code snippet is quoted verbatim with `file.c:function()`; every inference uses *"likely"* / *"appears to"* / *"based on the diff"*.
  → If bare causation or paraphrased diffs exist: *(output revision)* rewrite with explicit tier language and verbatim quotes.

Phase 5 sends the consolidated email (RCA + patch).

## Post-analysis domain knowledge update

**Auto — run this immediately after the Phase 5 email is sent, in the same turn, before offering
Phase 6/7/8 next steps. Do NOT wait for the user to ask for a domain-knowledge summary; this is
not a user-triggered phase.** Capture concrete, analysis-verified domain facts so they accumulate
in the repo. Do NOT produce a `## Analysis Reflection` section in the email (self-reflection
criteria are handled by Phase 8 subagent review instead).

1. Write new domain facts directly to the target domain file now.
2. For a **missing suite**: create `domain/suites/<suite>.md`, then add the Suite Index row
   to `domain-reference.md`.
3. For a **new subsystem pattern**: append the row or subsection to the target file.
4. Write only what the analysis data confirmed (perf-stat values, commit hash, source line).
   Do not add speculative entries.
5. After writing all files, commit immediately using `lkp-git-commit` SKILL.md:
   `lkp-auditperf: update domain/<target> from <fbc_hash[:10]> analysis`
   Suite file + subsystem update + router row can go in one commit.

If no new domain facts: state `no domain updates this run` and skip.

**Mandatory `## Session Summary`** — emit this table in chat immediately after the domain-update
step above (whether or not any domain facts were written), so the user can see at a glance which
of this run's automatic housekeeping steps actually fired instead of having to ask. Do not omit
rows; use `➖ none this run` for anything that did not apply:

```
## Session Summary

| Step | Status |
|---|---|
| Confidence modifiers applied | {base tier} → {final tier} via {modifier tokens, or "none"} |
| In-task self-tuning | ✅ {one-line description + file/commit} — or ➖ none this run |
| Domain knowledge update | ✅ {file(s) updated + commit hash} — or ➖ no domain updates this run |
| Patch / Optimization proposal | ✅ delivered to {user_email} (cc lkp@intel.com) |
```

Immediately follow the table with **one single consolidated next-steps message** — never split
`validate`/`e2e`/`review` across separate messages or turns:

> "Say `validate` (Phase 6 — compile-verify the patch, then commit to an internal LKP branch),
> `e2e` (Phase 7 — generate a test fixture), or `review` (Phase 8 — fresh-context quality review
> evaluating evidence chain, alternative hypotheses, and prediction calibration without anchoring
> bias). All three are independent and optional — say nothing further if none are needed."

```
# rca_email_body =
# ### Bisection Verification Summary
#
# | Verification | Status | Confidence |
# |---|---|---|
# | **Statistical Regression** | ✅ Confirmed / ⚠️ Uncertain | {confidence} |
# | **Root Cause Analysis** | ✅ Identified / ⚠️ Partial | {confidence} |
#
# {one-line explanation of the regression}
#
# ---
#
# {## Summary section}
#
# {## Verdict 6-row table}
#
# {## Impact Mechanism, ## Causal Chain, ## Evidence, ## Prediction vs Measurement, ## Fix Strategy, ## Community Awareness}
```

If `user_email` is empty: run `git config user.email` in a terminal to resolve it.
If still empty (e.g. git config not set on this host), ask the user: *"What email address should I send the report to?"*
Carry the resolved value as `user_email`.

Immediately proceed to Phase 5 — no confirmation required.
