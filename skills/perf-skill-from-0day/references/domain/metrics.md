# auditperf — Generic Metrics Reference

> Loaded at Phase 3a start alongside the suite and subsystem files.
> Contains metric polarity and hardware counter classification tables.
> Do not reproduce these tables verbatim in output.

---

## Metric Polarity

| Metric name pattern | Higher = better | Regression signal |
|---|---|---|
| `*ops*`, `*throughput*`, `*bandwidth*`, `per_{thread,process}_ops` | ✓ | Negative `perf_change` (e.g. `-45%`) |
| `*latency*`, `*lat*`, `*_time`, `*ms`, `*usec`, `*ns` | ✗ (lower = better) | Positive `perf_change` (e.g. `+30%`) |
| `*involuntary_context_switches*` | ✗ (lower = better — forced preemption) | Positive `perf_change` |
| `*voluntary_context_switches*`, `*minor_page_faults*`, `*cpu_migrations*` | Ambiguous — workload/mechanism-dependent, not a universal good/bad direction | Interpret via the diff mechanism, not sign alone (e.g. more minor faults from THP splitting is a benign side effect, not a regression) |
| `perf-profile.calltrace.cycles-pp.*` | N/A | Positive delta = FBC consumes more CPU cycles in that call stack |

`perf_change` is relative to parent (baseline). `-60%` on a throughput metric = throughput dropped 60%.

**Secondary-metric tally caveat (Phase 3a Step 4)**: `classify-metric-tag`'s mechanical
`[INCONSISTENT]` tag only compares raw signs across reported metrics — it does not know which
direction is "good" for each metric. Before accepting `[INCONSISTENT]` at face value, check each
flagged metric against this table: a lower-is-better metric moving in the opposite raw sign from
a higher-is-better primary metric (e.g. `involuntary_context_switches` falling while `ops_per_sec`
rises) is a **polarity artifact**, not workload redistribution — both are consistent with the same
improvement. Only metrics whose *effective* (polarity-normalized) direction disagrees indicate
true `[INCONSISTENT]`/workload-redistribution. Confirmed example: commit `a2e0c0668a3486f9`
(`stress-ng.memthrash`) — mechanical tag `[INCONSISTENT]` from `involuntary_context_switches`
-42% vs. `ops`/`ops_per_sec` +35%/+32%, correctly reinterpreted as effectively
`[MULTI-METRIC CONFIRMED]` once polarity was applied.

---

## Hardware Counter Classification

Derived from `perf-stat.*` in the compare file. Pre-classifies regression type before reading the
diff. Hot-path function names (from the loaded subsystem file) override this when they are
unambiguous.

| Counter delta | Tag | Phase 4 pattern hints |
|---|---|---|
| `perf-stat.cache-misses`, `cache-miss-rate%`, or `MPKI` strongly positive | `[MEMORY-BOUND]` | Struct layout, NUMA locality, false sharing |
| `perf-stat.ipc` strongly negative | `[MEMORY-BOUND]` (corroborating) | CPU stalling on load latency — NOT lock contention (spinners have HIGH IPC) |
| `perf-stat.dTLB-load-misses` or `iTLB-load-misses` strongly positive | `[TLB-BOUND]` | TLB shootdown overhead |
| All hardware counters flat, throughput regresses | `[LOCK-CONTENTION]` | Lock contention increase |

If only **software** counters are present (`cpu-clock`, `task-clock`, `context-switches`,
`page-faults`, `minor-faults`) with no hardware PMU data: infer `hw_tag` from the FBC diff
mechanism and perf-sched deltas. Note the inference as uncertain in the Phase 4 Verdict Confidence
cell. Do not set `hw_tag = "none"` when a clear mechanism exists.
