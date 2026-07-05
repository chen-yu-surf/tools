# Phase 3B — Diff + LLM Analysis *(Track B: result-search / static-only)*

> This phase replaces Phase 3A when `analysis_mode ≠ bisect-driven`.
> Read [domain-reference.md](domain-reference.md) routing instructions first, then load
> suite and subsystem files as directed, following its conditional-load rules for
> metrics.md/kconfig-confounds.md — kconfig-confounds.md is more often relevant here than in
> bisect-driven mode, since this mode's compared result roots may have unrelated kconfig
> differences.

`tmp_dir` is not populated in this mode. Do not call `extract_bisect_report`.

---

## Step 1 — Read the full commit diff

Call `mcp_shz_git_mcp_get_linux_commit(fbc_hash)` for the unified diff.

- Record all changed file paths → used for subsystem detection below.
- If fails: stop — cannot proceed without the diff.
- **Merge commit** (subject begins `"Merge branch"`, `"Merge tag"`, or `"Merge remote"`):
  examine parent SHAs; call `mcp_shz_git_mcp_get_linux_commit` on 1–3 merged commits touching
  perf-sensitive paths. Note: *"commit is a merge — true change: {actual_sha}"*.
- **Security / functional fix**: same rules as Phase 4 — do not recommend revert; find
  reduced-overhead mitigation.

## Step 2 — Map to subsystem(s) and load domain files

Using the Subsystem Index in `domain-reference.md`:
1. Map each changed file path to its subsystem; load the corresponding subsystem file(s).
2. If a `search_suite` was provided by the user, load its suite file too.
3. Load [domain/metrics.md](domain/metrics.md) only if hot-path function names (once available)
   don't already give an unambiguous classification; load
   [domain/kconfig-confounds.md](domain/kconfig-confounds.md) when comparing result roots that
   may have different kconfigs.
4. If the commit touches `tools/perf/` or `tools/testing/selftests/` only → mark as
   potential **exposing commit** (same logic as Phase 4 Step 1).

## Step 3 — Static analysis using LLM knowledge + domain files

For each subsystem touched by the diff, apply the following analysis using **both** the loaded
subsystem file and your own knowledge of Linux kernel internals:

### 3a — Identify hot-path impact

For every function changed by the diff:
- Is it called in a tight loop or a frequently-invoked path (syscall, interrupt handler,
  page fault, scheduler tick, network Rx/Tx)?
- Does the change add work proportional to request count (per-allocation, per-fault,
  per-packet, per-wakeup)?
- Does the change add work proportional to CPU count (e.g., `smp_call_function_many`,
  per-CPU iteration, synchronize_rcu)?

Cross-reference against the loaded subsystem file's hot-function table. Tag matching functions
with their regression type.

### 3b — Structural change analysis

Inspect struct/type changes:

| Change type | Performance signal | Tag |
|---|---|---|
| New field added to a struct used in hot loops | Potential cacheline spill | `[MEMORY-BOUND]` risk |
| Field moved / reordered in a hot struct | Cacheline layout change | `[MEMORY-BOUND]` risk |
| New `spinlock_t` / `rwsem` acquisition in hot path | Contention increase | `[LOCK-CONTENTION]` risk |
| Critical section extended (code moved inside lock) | Contention increase | `[LOCK-CONTENTION]` risk |
| New `flush_tlb_*` call or scope widened | TLB shootdown overhead | `[TLB-BOUND]` risk |
| New `synchronize_rcu()` call in write path | RCU stall overhead | `[LOCK-CONTENTION]` risk |
| New per-object / per-page initialisation | Alloc / fault overhead | `[MEMORY-BOUND]` risk |
| New `this_cpu_inc()` / `percpu_counter_inc()` in hot path | Per-CPU cache-line invalidation under NUMA | `[MEMORY-BOUND]` risk — not a lock, but coherency traffic at scale |
| New `write_seqcount_begin()` / `write_seqcount_invalidate()` in read-dominated path | Reader retry overhead | `[LOCK-CONTENTION]` risk — readers spin retrying `read_seqcount_retry()` |

Use `pahole`-style reasoning for struct layout: count the fields before/after the change and
estimate whether the struct crosses a new 64-byte cacheline boundary.

### 3c — Apply LLM code-flow reasoning

For the 2–3 most performance-relevant changed functions, trace the call chain using your own
knowledge (supplemented by LSP if needed):
- What callers invoke this function in a hot path?
- Does the change add or remove synchronisation, memory allocation, or cache pressure?
- Is the change in the fast path (always executed) or the slow path (exceptional case)?
- Would the overhead scale with thread count, CPU count, or data size?

State your reasoning explicitly as a numbered inference chain, e.g.:
```
1. `__alloc_pages` → calls `get_page_from_freelist` on every allocation
2. FBC adds `folio_add_lru()` unconditionally before return
3. `folio_add_lru` acquires `lruvec->lru_lock` (spinlock) per page
4. Under N-thread malloc workloads, this creates O(N) lock contention on a shared lruvec
→ predicted: [LOCK-CONTENTION] regression in malloc-heavy benchmarks
```

### 3d — Classify impact and assign hw_tag

Based on steps 3a–3c, assign:
- `hw_tag`: `[MEMORY-BOUND]` / `[TLB-BOUND]` / `[LOCK-CONTENTION]` / `general`
  — add `(inferred from diff)` suffix since no perf-stat data exists
- `impact_direction`: `regression` / `improvement` / `neutral` / `ambiguous`
- `affected_suites`: list of suites from domain-reference.md Suite Index whose primary subsystem
  matches the diff

If `analysis_mode = result-search`: record `static_prediction` **now**, before Step 4 reads any
result data — using the same format as phase3-evidence.md Step 0 point 3:
```
static_prediction = "{direction} | {mechanism_1_sentence} | hw_tag={predicted_hw_tag} | scale_condition={condition_or_none}"
```
Do NOT read result data before recording this. The formal comparison happens in Phase 4
`## Prediction vs Measurement`. For `static-only` mode: skip — no measurement exists to compare
against; steps 3a–3c are the final analysis.

## Step 4 — Opportunistic result data (result-search mode only)

If `analysis_mode = result-search` and `result_root` was set in Phase 2:
1. `mcp_shz_lkp_mcp_read_external_file(result_root + "/job.yaml")` — extract suite, stressor, kconfig
2. Check for perf profile: `mcp_shz_lkp_mcp_list_external_directory(result_root + "/0/")` —
   look for `perf-profile.json`; if present, read top-10 calltrace entries via
   `mcp_shz_lkp_mcp_read_external_file`
3. Read perf-stat: `mcp_shz_lkp_mcp_compare_lkp_results(["-f", "perf-stat", parent_result_root, result_root])`
4. Apply same Phase 3A analysis logic (steps 3a–5 of `phase3-evidence.md`) on the found data
5. Update `metric_tag`, `hw_tag` from real data (remove `(inferred from diff)` qualifier if
   hot call chain evidence found)

## Step 5 — LSP traversal (when needed)

Use LSP for multi-file diffs or `[CHAIN TRUNCATED]` chains, same rules as Phase 4 Step 2. Use the
`site` session variable (default `shz` — this mode has no `bisect_tag`) as the `<site>` prefix:
```
mcp_<site>_lsp_mcp_init_lsp_workspace(workspace_id=lkp-auditperf-{fbc_hash[:12]},
                               fbc_hash={fbc_hash},
                               build_dir={result_root or None})
```
If `result_root` is null, omit `build_dir`. Fall back to `mcp_shz_git_mcp_grep_repo` if LSP init fails.

---

## §Queue — Queue Comparison Jobs *(Phase 3C, user-triggered)*

> Run only if the user answered "yes" to the job-queuing offer in Phase 2.

Read `.agents/skills/lkp-queue/SKILL.md` and follow its pre-flight and queuing procedure.

**Jobs to queue**:
1. **FBC job**: queue a job for `fbc_hash` on the affected suite(s) from `affected_suites`
2. **Parent job**: queue the same job for the parent commit SHA
   (`mcp_shz_git_mcp_get_linux_commit(fbc_hash)` → `parents[0]`)

**Job parameters**:
- Use the kconfig from an existing result root if available; otherwise use the default kconfig
  for the suite from `jobs/<suite>/*.yaml`
- Enable `debug_mode: 1` to capture perf profiles for the follow-up audit
- Use the same tbox class as any existing result root for the commit

After queuing, tell the user:
```
Queued jobs for {fbc_hash[:12]} and parent {parent_hash[:12]}.
When results are ready, re-run this skill with either result root path or the same SHA —
it will find the new result roots automatically and upgrade to result-search mode.
```

---

## Step 6 — Set metric_tag

If no real metric data exists (`static-only` with no queuing yet):
- `metric_tag = [STATIC-ONLY]` (overrides the normal MULTI-METRIC / SINGLE-METRIC logic)

Output this checkpoint:

```
Phase 3B ✓
  analysis_mode:    {analysis_mode}
  data_source_tag:  {data_source_tag}
  hw_tag:           {hw_tag}
  metric_tag:       {metric_tag}
  impact_direction: {impact_direction}
  affected_suites:  {affected_suites}
  result_root:      {result_root or "none"}
```

Continue automatically to Phase 4.
