# sched Subsystem Reference

> Loaded when the FBC diff touches `kernel/sched/`, `include/linux/sched*.h`,
> or `kernel/stop_machine.c`.

---

## Hot-Path Functions → Regression Type

| Function (or prefix) | Regression type | Tag | Where to look in the diff |
|---|---|---|---|
| `update_curr` / `__update_min_vruntime` | CFS scheduler tick overhead | (check perf-stat) | `kernel/sched/fair.c`; new per-tick accounting overhead |
| `pick_eevdf` / `entity_eligible` | EEVDF task selection overhead (kernel ≥ 6.6; full transition in 6.12) | (check perf-stat) | `kernel/sched/fair.c`; new per-entity eligibility computation |
| `try_to_wake_up` / `select_task_rq_fair` | Wakeup latency | — | `kernel/sched/`; load balancing or affinity changes |
| `__schedule` | General scheduling overhead | (check perf-stat) | `kernel/sched/core.c`; new work in the main schedule() path |
| `__schedule` (SM_IDLE path) | Idle re-entry overhead (kernel ≥ 6.12) | (check perf-stat) | `kernel/sched/core.c`; SM_IDLE fast-path added as a new idle re-entry shortcut; FBC that bypasses or adds checks to this path regresses idle-heavy workloads |
| `load_balance` / `find_busiest_queue` | Load balancer overhead | `[MEMORY-BOUND]` on multi-socket | Cache structure changes that increase cost of scanning runqueues |
| `newidle_balance` | Idle-time load balancing | — | Overly aggressive pull search on large machines |
| `task_group_account_field` / `update_cfs_group` | Cgroup scheduler overhead | (check perf-stat) | `kernel/sched/fair.c`; cgroup hierarchy traversal added per tick |
| `bpf_sched_*` / `scx_*` | sched_ext BPF scheduler overhead (kernel ≥ 6.12) | (check perf-stat) | `kernel/sched/ext.c`; BPF dispatch and enqueue hooks add per-scheduling-event overhead; FBC that adds hook invocations or widens dispatch scope is a candidate |
| `tg_cfs_rq` / `list_add_leaf_cfs_rq` / `tg_unthrottle_up` / `tg_throttle_down` | CFS task-group per-CPU structure access | `[MEMORY-BOUND]` on multi-socket | `kernel/sched/fair.c`; accesses `task_group::cfs_rq` per CPU; converting from heap pointer array to percpu allocation eliminates NUMA cross-socket indirection; used on every CFS enqueue/dequeue for cgroup-enabled kernels |
| `sched_rt_period_rt_rq` / `for_each_sched_rt_entity` | RT task-group bandwidth enforcement | `[MEMORY-BOUND]` on multi-socket | `kernel/sched/rt.c`; accesses `task_group::rt_rq[cpu]` through heap pointer array (pre-percpu-data analogue of CFS pattern); called from RT bandwidth enforcement timer per tick |

## Regression Patterns Specific to sched

**Wakeup latency increase**:
- FBC added new work inside `try_to_wake_up` (affinity check, cgroup accounting, NUMA placement).
- Confirm: positive delta on `try_to_wake_up` and `select_task_rq_fair` in perf-profile.
- Fix: move non-critical work outside the wakeup fast-path; per-CPU caching of affinity decisions.

**CFS tick overhead**:
- FBC added per-tick accounting in `update_curr` or its callees (`update_min_vruntime`,
  `update_cfs_group`).
- Confirm: `update_curr` appears at top of positive-delta stacks.
- Fix: amortise accounting (compute only every N ticks or on demand); avoid per-tick struct writes
  that cause false sharing on the `cfs_rq` struct.

**Load balancer overhead (multi-socket)**:
- FBC changed `sched_group` / `sched_domain` structures used in `load_balance`.
- On multi-socket tboxes only: `[MEMORY-BOUND]` from traversing a larger/dirtier per-CPU tree.
- Confirm by comparing single-socket vs. multi-socket result roots if both exist.

**EEVDF task selection overhead** (kernel ≥ 6.6; fully transitioned in 6.12):
- FBC changed the EEVDF eligibility window (`se->slice`, `se->deadline`) or added new work
  in `pick_eevdf` / `entity_eligible`. EEVDF replaced the CFS `pick_next_entity` vruntime path.
  Kernel 6.12 completed the full EEVDF transition (commits a1c446611, f12e148892), removing the
  last CFS fallback code paths.
- Confirm: `pick_eevdf` or `entity_eligible` in positive-delta stacks; `update_curr` may also
  increase due to deadline recomputation.
- Fix: amortise eligibility computation; avoid per-entity deadline updates in the fast path;
  reduce slice granularity only when necessary.

**SM_IDLE fast-path regression** (kernel ≥ 6.12):
- Kernel 6.12 added an SM_IDLE idle re-entry fast-path in `__schedule()` (commit 3dcac251)
  that avoids the full scheduler path when re-entering idle. FBCs that add new checks or
  work _inside_ this fast-path, or that invalidate the conditions for taking it, force more
  frequent execution of the full `__schedule()` loop.
- Confirm: `__schedule` shows a positive-delta but `pick_eevdf` / `update_curr` do NOT —
  overhead is in the preamble/idle-detection portion; check workloads with high idle fractions.
- Fix: ensure new per-CPU state written by the FBC does not prevent SM_IDLE fast-path entry;
  or move the new check behind the SM_IDLE guard.

**sched_ext BPF scheduler overhead** (kernel ≥ 6.12):
- `sched_ext` (commit 88264981) allows a BPF program to replace the kernel scheduler for
  user-defined scheduling policies. FBCs that add new enqueue/dispatch hook call sites, widen
  the BPF program's invocation scope, or increase per-task BPF map lookups show up as overhead
  in `scx_*` / `bpf_sched_*` functions.
- Confirm: `scx_*` or `bpf_prog_run_*` in positive-delta stacks; regression only when
  `sched_ext` is enabled (`CONFIG_SCHED_CLASS_EXT=y`).
- Fix: narrow the BPF hook invocation scope; batch per-task map updates; verify whether the
  regression is in the BPF program itself (user-space fix) or the kernel dispatch path.

**PREEMPT_LAZY regression** (kernel ≥ 6.13):
- Kernel 6.13 added `PREEMPT_LAZY`, a new preemption model that defers preemption to the next
  idle or cond_resched point (similar to `PREEMPT_VOLUNTARY` but with voluntary yields only
  where explicitly placed). FBCs that add or remove `cond_resched()` calls, or change the
  preemption model selection, alter latency/throughput trade-offs measurably.
- Confirm: regression appears only on kernels with `CONFIG_PREEMPT_LAZY=y`; latency metrics
  (schbench `p99_lat`, lmbench `lat_syscall`) typically increase while throughput stays flat.
- Fix: ensure FBC does not remove `cond_resched()` from long-running loops in kernel paths;
  if preemption model choice is changed, document the latency/throughput trade-off explicitly.

**NUMA pointer-array → percpu improvement (`per-cpu-data` pattern)**:
- FBC converts a `struct foo **per_cpu_ptrs` heap pointer array inside `task_group` (or
  similar per-CPU-indexed struct) to `struct foo __percpu *` via `alloc_percpu()`.
- On multi-socket NUMA (≥ 2 sockets), the old pattern requires two memory loads per access:
  one for the pointer array base (heap-allocated, may be on remote NUMA node) and one for the
  target struct. `per_cpu_ptr()` resolves to a single CPU-local offset, guaranteeing NUMA-local
  access.
- Confirmed by `b8fea7af0e40`: `task_group::cfs_rq` converted from `struct cfs_rq **` to
  `struct cfs_rq __percpu *`. Measured on lkp-srf-2sp3 (Sierra Forest, 2-socket, 192 CPUs):
  `stress-ng.session.ops_per_sec` +67.67%, `cpu-clock` −18% (fewer cycles per op).
- `stress-ng --session` exercises this path via `sched_fork()` → `enqueue_task_fair()` →
  `list_add_leaf_cfs_rq()` for each of 192 concurrent setsid workers.
- **Generalization target**: `task_group::rt_rq **rt_rq` and `task_group::rt_se **rt_se` in
  `kernel/sched/rt.c` still use the old heap pointer array pattern as of this commit.
  `sched_rt_period_rt_rq()` is the primary hot-path candidate for the same conversion.
- Classify as `[MEMORY-BOUND]`; scale condition: multi-socket NUMA, thread count ≥ nr_cpu.
- Confidence degrades when primary metric stddev ≥ 40% (single-run parent baseline).

**PREEMPT_RT regression** (kernel ≥ 6.12):
- Kernel 6.12 officially merged PREEMPT_RT (20+ years in development). On RT kernels, most
  spinlocks become sleeping (`rt_mutex`-backed) locks, increasing context-switch overhead.
  FBCs that add code executed under spinlocks inadvertently extend RT lock hold times.
- Confirm: regression only with `CONFIG_PREEMPT_RT=y`; `rt_mutex_lock` / `rt_spin_lock` in
  positive-delta stacks; RT regression that does not appear on PREEMPT_NONE/VOLUNTARY kernels.
- Fix: move work outside the spinlock critical section; use `raw_spinlock_t` only when
  absolutely necessary (it is not converted to a sleeping lock on RT kernels).

**Cgroup scheduler overhead**:
- FBC added per-tick work in `update_cfs_group` or added a new cgroup hierarchy traversal
  in `task_group_account_field`, scaling with the depth of the cgroup tree.
- Confirm: `update_cfs_group` or `task_group_account_field` positive-delta, especially when
  the test job uses nested cgroups.
- Fix: amortise cgroup accounting; avoid full hierarchy walk per tick; lazy propagation.

## Key Files and Entry Points

| File | Purpose |
|---|---|
| `kernel/sched/core.c` | `__schedule`, `try_to_wake_up`, `sched_fork`, SM_IDLE fast-path (6.12+) |
| `kernel/sched/fair.c` | CFS/EEVDF: `update_curr`, `pick_eevdf`, `entity_eligible`, `enqueue_task_fair`, `select_task_rq_fair` |
| `kernel/sched/ext.c` | sched_ext BPF scheduler: `scx_*` hooks (6.12+) |
| `kernel/sched/topology.c` | `sched_domain` / `sched_group` setup |
| `kernel/sched/smp.c` | `load_balance`, `find_busiest_queue`, `newidle_balance` |
| `include/linux/sched.h` | `task_struct` definition — struct layout changes hit every scheduler path |
