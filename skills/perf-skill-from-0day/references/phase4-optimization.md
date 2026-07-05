# Phase 4 Step 6 — Optimization Discovery *(improvements only)*

Read this file only when `change_direction == "improvement"`. Skip entirely for regressions —
do not load this file if `change_direction == "regression"`.

**6a — Extract the optimization pattern from the diff:**
1. Identify the before-state: what specific inefficiency existed (e.g. redundant lock acquire on
   every path, uncached repeated computation, non-NUMA-aware allocation, excessive TLB shootdown,
   false-sharing struct layout)?
2. Name the technique applied: use a precise label — one of: `lock-elimination`,
   `lazy-evaluation`, `batching`, `cache-line-layout`, `lockless-atomic`, `NUMA-awareness`,
   `TLB-reduction`, `work-avoidance`, `per-cpu-data`, `read-mostly`, or `other: <description>`
3. Quote the key before/after lines from the diff that embody the pattern (verbatim, with
   `file.c:function()` citations)

**6b — Search for similar code paths:**
1. Construct a `mcp_shz_git_mcp_grep_repo` search for the **pre-optimization code pattern** — the old
   pattern the commit replaced (not the new pattern). Use a grep string that would match similar
   calls, struct accesses, or lock patterns in other files.
2. Filter results to hot-path subsystems in priority order: `kernel/sched/`, `mm/`, `fs/`,
   `net/`, `block/`, then `drivers/` only if top tiers yield fewer than 3 candidates.
3. For each candidate found: call `mcp_shz_git_mcp_read_repo_file` to read a short window (±20 lines)
   around the match to confirm the same inefficiency pattern is present.
4. Rank by hot-path likelihood: prefer functions known to appear in perf profiles of common
   workloads (use domain knowledge); eliminate dead-code or rarely-called paths.
5. Emit exactly **top 3 candidates** (or fewer if fewer than 3 confirmed matches exist):
   `file.c:function()` + one sentence explaining why the same technique applies.

If `mcp_shz_git_mcp_grep_repo` is unavailable: note the gap; list candidates from LLM kernel knowledge
only, labeled `[LLM-knowledge — not grep-confirmed]`.

Return to phase4-rca.md's "Required pre-output scratchpad" after completing 6a/6b.
