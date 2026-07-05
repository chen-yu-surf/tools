# Phase 3 — Gather Evidence

`tmp_dir` was populated in Phase 1. Do NOT call `extract_bisect_report` again.

Use the smallest slice: prefer `mcp_shz_lkp_mcp_grep_extracted_data`; use
`mcp_shz_lkp_mcp_read_extracted_data` only for small files or when full content is required.

## Step 0 — Static prediction *(runs before any bisect data is read)*

> Purpose: commit to an independent mechanism prediction from the diff alone before observing
> bisect evidence. Discrepancies between prediction and data are diagnostic signals — they expose
> scale amplification, exposing-commit patterns, or deeper root causes not visible in the FBC diff.

1. Call `mcp_shz_git_mcp_get_linux_commit(fbc_hash)` — fetch the full unified diff **here**, so
   Phase 4 Step 1 can skip the re-fetch. Record all changed file paths.

2. Apply **phase3-commit-only.md Steps 3a–3d** (hot-path impact, structural change analysis,
   code-flow reasoning, `hw_tag` classification) on the diff alone:
   - No LSP in this step — diff + LLM reasoning only.
   - No domain files yet (they load in Step 3b below).
   - Use the structural change table (3b) and numbered inference chain format (3c) from
     phase3-commit-only.md verbatim — do not repeat those tables here.

3. Record `static_prediction` as a single structured string:
   ```
   static_prediction = "{direction} | {mechanism_1_sentence} | hw_tag={predicted_hw_tag} | scale_condition={condition_or_none}"
   ```
   Examples:
   - `"regression | mutex added inside per-allocation fast path | hw_tag=[LOCK-CONTENTION] | scale_condition=high thread count"`
   - `"improvement | redundant lock eliminated on read-mostly path | hw_tag=[LOCK-CONTENTION] | scale_condition=multi-socket"`
   - `"neutral/ambiguous | refactor only — no structural hot-path change visible | hw_tag=general | scale_condition=none"`

4. **Do NOT let `static_prediction` influence how you read or weight the bisect evidence** in
   Steps 3a–5. Read bisect data independently. The comparison happens in Phase 4
   `## Prediction vs Measurement`.

---

## 3b — Test suite context (run first — sets debug_mode and suite name)

Read `{result_root}/job.yaml` via `mcp_shz_lkp_mcp_read_external_file`. Extract:
- Test suite name and stressor/workload (e.g. `stress-ng --bigheap`)
- `debug_mode` value — **must be read first**; if `0` or absent, skip all calltrace
  investigation in 3a steps 2 and the Perf-profile section entirely
- Key job parameters relevant to the regression
- If absent: note gap; assume `debug_mode: 0` and proceed without calltrace data.

Then load domain files using the suite name from job.yaml — read [domain-reference.md](domain-reference.md) for routing and its conditional-load rules for metrics.md/kconfig-confounds.md:
1. The **suite file** matching `job.yaml`'s `suite:` / `test:` field (from the Suite Index).
2. The **subsystem file(s)** matching the FBC's changed file paths (from the Subsystem Index).
3. [domain/metrics.md](domain/metrics.md) — only if step 3a-5's hot-path function names don't
   already give an unambiguous classification.
4. [domain/kconfig-confounds.md](domain/kconfig-confounds.md) — skip by default in this
   (bisect-driven) mode; load only if `correlation.txt` shows a debug/instrumentation config
   difference between the FBC and parent runs.

If the suite is unknown, skip step 1 and use the subsystem file(s) plus perf-profile hot-function
names as the starting hypothesis.

**Test case → kernel path connection (mandatory)**: using the suite file's test-case table and
the FBC's changed file paths, explicitly confirm or deny that the test case exercises the changed
code path. Record `test_case_description` covering three fields:
```
test_case_description = {
  what:     "{test suite}/{test case} — what it does in 1 sentence (workload type, parameters)",
  syscalls: "primary syscall(s) or kernel entry points it invokes",
  path:     "kernel subsystem/functions exercised that are relevant to the FBC"
}
```
Examples (stress-ng):
```
test_case_description = {
  what:     "stress-ng/session — creates and tears down POSIX sessions via setsid(2) with 192 worker processes for 60s",
  syscalls: "setsid(2), fork(2), wait(2)",
  path:     "kernel/sched/ CFS task-group paths: list_add_leaf_cfs_rq, tg_unthrottle_up, tg_throttle_down — triggered on every task enqueue/dequeue under cgroup scheduling"
}
```
Examples (non-stressor):
```
test_case_description = {
  what:     "iperf3/tcp — measures TCP throughput between two endpoints with 8 parallel streams",
  syscalls: "sendmsg(2), recvmsg(2), epoll_wait(2)",
  path:     "net/tcp: tcp_sendmsg, tcp_write_xmit — hot path for every sent segment"
}
```

If the test case does NOT exercise the FBC's changed subsystem: flag `stressor_mismatch = true`
and carry it into Phase 4 as a cross-subsystem mismatch signal. Do not assert the FBC caused
the regression without confirming the connection.

## 3a — Performance metrics (read in parallel — all are independent)

**0. `mcp_shz_lkp_mcp_read_extracted_data(tmp_dir, "correlation.txt")`** — commit message, changed
file list, and compilation status per file. Keep in context for Phase 4.
- `|- y` → `obj-y` in Makefile, unconditionally compiled (no CONFIG gate)
- `|- CONFIG_XXX=y` → gated and **enabled** in `.config`
- `|- miss CONFIG_XXX` → gated and **disabled** → file not compiled → FBC cannot regress through this path
- `CC kernel/path/file.o` → build log confirms the `.o` was produced
- **If absent**: derive pkg path from `result_root` (`/result/…/<kconfig>/<compiler>/<fbc>/0/` →
  `/pkg/linux/<kconfig>/<compiler>/<fbc>/`) and use `mcp_shz_lkp_mcp_read_external_file` on
  `<pkg_path>/.config` + `mcp_shz_lkp_mcp_search_external_file` on `<pkg_path>/kbuild.log` for
  `CC <file>.o`

**1.** `mcp_shz_lkp_mcp_grep_extracted_data(tmp_dir, "email-body.txt", <metric_from_perf_change>)` —
summary regression table

**2.** Calltrace data — use in order of completeness:
- `mcp_shz_lkp_mcp_read_extracted_data(tmp_dir, "perf_profile_fbc.txt")` — top-30 calltrace entries
  by CPU% for the FBC run, sorted descending. **This is the most complete source**: it comes from
  `{result_root}/0/perf-profile.json` which has ALL calltraces, not only the top-delta entries the
  email shows. Only present when `debug_mode: 1` in job.yaml.
- `mcp_shz_lkp_mcp_read_extracted_data(tmp_dir, "perf_profile.txt")` — calltrace rows extracted from
  the email body (the comparison delta view: parent vs FBC). Complementary to the above.
- If both are absent: check `job.yaml` for `debug_mode`.
  **`debug_mode: 0` (or absent) → no perf profiling was configured; calltrace data does not
  exist anywhere. Skip calltrace steps and fall back to the loaded suite and subsystem file
  priors immediately.
  `debug_mode: 1` → calltrace data should exist; investigate further if still absent.

**3.** FBC vs parent delta — `email-body.txt` **is** the `lkp compare` output produced during
bisect; it already contains the full delta table. Read it:
   `mcp_shz_lkp_mcp_grep_extracted_data(tmp_dir, "email-body.txt", <stats_field>)`.
   The columns are `[parent ±std%]  [delta%]  [fbc ±std%]  <field>` — `fbc` is the
   first-bad commit, `parent` is the baseline.
   If you also need absolute `mean_a`/`mean_b` values not shown in the email (older email
   format), then call `mcp_shz_lkp_mcp_compare_lkp_results(["-f", "<stats_field>",
   "<parent_result_root>", "<fbc_result_root>"])` as a supplement.
   **Note**: the `.xz` file in `tmp_dir` is the bisect execution log (pass/fail history),
   not a compare table. There are no raw `perf-profile.*` or `perf-stat.*` files under
   result roots — all statistics live in `matrix.json.gz` and are already summarised in
   the email body.

**4. Secondary metric confirmation** — grep `email-body.txt` for the suite name
   (`mcp_shz_lkp_mcp_grep_extracted_data(tmp_dir, "email-body.txt", <suite_name>)`)
   to tally all reported metrics from the same run. Tag:
- ≥ 2 metrics show `|delta| > 5%` in the **same direction** → `[MULTI-METRIC CONFIRMED]`
- Only the primary metric shows significant regression; correlated metrics < 5% → `[SINGLE-METRIC]`
- Metrics move in **opposite directions** → `[INCONSISTENT]` — likely workload redistribution rather
  than a regression; explain in `## Regression Mechanism`

Do this tally mechanically instead of eyeballing the grep output — pipe it in and read the
`metric_tag=` line directly:
```bash
.agents/skills/lkp-auditperf/scripts/classify-metric-tag <grep_output_file_or_->
```
If the script returns `metric_tag=[INCONSISTENT]`, check each flagged metric against
[domain/metrics.md](domain/metrics.md)'s Metric Polarity table before accepting it at face value —
a lower-is-better metric (e.g. `involuntary_context_switches`) moving opposite to a higher-is-better
primary metric is a polarity artifact, not workload redistribution; only re-tag as genuinely
`[INCONSISTENT]` if the *polarity-normalized* directions still disagree.

If absent: set `metric_tag = [SINGLE-METRIC]` and continue.
Carry this tag forward to Phase 4 where it modifies the final Verdict confidence.

**5. Hardware counter classification** — read `perf_stat.txt` from `tmp_dir` (extracted from the
email body by `extract_bisect_report`; contains `perf-stat.*` rows in the same
`[parent ±std%]  [delta]  [fbc ±std%]  perf-stat.<counter>` format as `perf_profile.txt`).
If `perf_stat.txt` is absent from the manifest (older deployment or no perf-stat data in email),
fall back to `mcp_shz_lkp_mcp_compare_lkp_results(["-f", "perf-stat", "<parent_result_root>",
"<fbc_result_root>"])`.
Use the Hardware Counter Classification table from [domain/metrics.md](domain/metrics.md) to assign `[MEMORY-BOUND]`,
`[TLB-BOUND]`, or `[LOCK-CONTENTION]`. When hot-path function names from step 2 are unambiguous
(e.g. `native_queued_spin_lock_slowpath` → `[LOCK-CONTENTION]`; `flush_tlb_others` →
`[TLB-BOUND]`), those names **override** the perf-stat aggregate. Carry the tag into Phase 4 as
a pre-classification hint.

If only **software** counters are present (`cpu-clock`, `task-clock`, `context-switches`,
`page-faults`, `minor-faults`) with no hardware PMU data (`cache-misses`, `ipc`,
`dTLB-load-misses`): infer `hw_tag` from the FBC diff mechanism and perf-sched deltas (e.g. a
percpu allocation change on a multi-socket machine → `[MEMORY-BOUND] (inferred from mechanism)`;
locking removal → `[LOCK-CONTENTION] (inferred from mechanism)`). Note the inference as uncertain
in the Phase 4 Verdict Confidence cell. Do not set `hw_tag = "none"` when a clear mechanism exists.

## Perf-profile format

Format: `[parent ±std%]  [delta]  [fbc ±std%]  perf-profile.calltrace.cycles-pp.<call_chain>`

- Record top 5 positive-delta stacks (regression bottlenecks) and top 2 negative-delta stacks
  (workload shift); mark `std% > 30%` as `[HIGH VARIANCE]`
- **Parse the full call chain** (suffix after `cycles-pp.`, dot-separated, leaf → outermost —
  e.g. `vfs_write.ksys_write.do_syscall_64.entry_SYSCALL_64_after_hwframe` has the leaf `vfs_write`
  first and the syscall-entry frame last):
  - Complete if it **ends with** `syscall_entry_from_user_mode`, `entry_SYSCALL_64` (or
    `entry_SYSCALL_64_after_hwframe`), or `do_syscall_64`
  - Otherwise flag `[CHAIN TRUNCATED]` — Phase 4 Step 2 extends it via LSP

  Classify all rows in one pass instead of checking each chain by eye — read the `status=` field
  per `chain=` line directly:
  ```bash
  .agents/skills/lkp-auditperf/scripts/check-chain-completeness <perf_profile_file_or_->
  ```
- If absent: check `debug_mode` in `job.yaml` first (see step 2 note). If `debug_mode: 0`,
  fall back to the loaded suite and subsystem file priors immediately without further investigation.
- `role=fbc` = FBC data; `role=parent_bad`/`role=parent_good` = parent baseline

## Checkpoint

Output before continuing:

```
Phase 3 ✓
  test:        {suite}/{stressor}
  metric:      {metric_key}: {parent_value} → {fbc_value} ({delta})
  metric_tag:  {metric_tag}
  hw_tag:      {hw_tag}
```
(metric_tag ∈ `[MULTI-METRIC CONFIRMED]` · `[SINGLE-METRIC]` · `[INCONSISTENT]`)
(hw_tag ∈ `[MEMORY-BOUND]` · `[TLB-BOUND]` · `[LOCK-CONTENTION]` · `"none"`)

## Pre-flight checklist — verify before proceeding to Phase 4

Binary preconditions: if any fails, apply the stated correction now before advancing.

- □ **`static_prediction` was committed to before reading any bisect data** — Step 0 must run before Step 3a. Verify the prediction in your context was not influenced by profile data you already saw.
  → If contaminated: discard it; re-read the diff alone and re-emit a fresh prediction now, labeled `[re-predicted — treat as informational]`.
- □ **`correlation.txt` was read** (or the `.config` + `kbuild.log` fallback was used).
  → If absent and fallback was not attempted: attempt the fallback now. If still unavailable, record the gap as `[correlation.txt absent — coverage gate limited to diff analysis]` and carry it into Phase 4 `## Evidence`.
- □ **`test_case_description` has all three fields** (`what`, `syscalls`, `path`) — none are placeholders (`"TBD"`) or empty strings.
  → If incomplete: re-read `job.yaml` and the suite file; fill in the missing fields before continuing.
- □ **`hw_tag` is one of the four valid values** — not left as `"none"` when the FBC diff contains a clear structural change (new lock acquisition, added TLB flush, struct layout change in hot path).
  → If `"none"` but a mechanism is evident: upgrade to the appropriate tag and annotate as `(inferred from diff mechanism)`.
- □ **`metric_tag` is one of** `[MULTI-METRIC CONFIRMED]` / `[SINGLE-METRIC]` / `[INCONSISTENT]` — not unset.
  → If unset: default to `[SINGLE-METRIC]` and carry that tag into Phase 4 Verdict Confidence.
