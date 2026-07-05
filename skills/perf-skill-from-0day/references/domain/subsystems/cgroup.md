# cgroup Subsystem Reference

> Loaded when the FBC diff touches `kernel/cgroup/`, `mm/memcontrol.c`,
> `include/linux/cgroup*.h`, `include/linux/memcontrol.h`, `kernel/sched/psi.c`,
> `include/linux/psi*.h`, or `block/blk-cgroup.c`.
>
> Relevant whenever the test runs inside a container/cgroup (check `job.yaml` for
> `docker`/`container`/`cgroup` fields) or the FBC changes cgroup v1/v2 accounting paths that
> run on every process regardless of whether the workload itself is containerized.

---

## Hot-Path Functions → Regression Type

| Function (or prefix) | Regression type | Tag | Where to look in the diff |
|---|---|---|---|
| `page_counter_try_charge` / `try_charge` / `mem_cgroup_charge` | memcg charge/uncharge overhead | `[LOCK-CONTENTION]` if `page_counter` atomic contended; `[MEMORY-BOUND]` if layout | `mm/memcontrol.c`; new charge sites or `page_counter` struct changes |
| `cgroup_rstat_flush` / `cgroup_rstat_flush_locked` | rstat flush storm | `[LOCK-CONTENTION]` | `kernel/cgroup/rstat.c`; new per-CPU stat sources feeding the flush |
| `psi_task_change` / `psi_group_change` | PSI accounting overhead | `[LOCK-CONTENTION]` | `kernel/sched/psi.c`; new state transitions calling into PSI on a hot scheduling path |
| `cpuacct_charge` / `cpuusage_read` | cpu.stat accounting overhead | — | Legacy cgroup v1 CPU accounting; per-CPU counter changes |
| `mem_cgroup_iter` / `mem_cgroup_wb_stats` | Reclaim/writeback stat overhead | `[MEMORY-BOUND]` | `mm/memcontrol.c`, `mm/vmscan.c`; new per-cgroup iteration in reclaim path |

---

## Regression Patterns Specific to cgroup

### memcg Charge Path Contention (`[LOCK-CONTENTION]`)

- FBC adds a new `mem_cgroup_charge()`/`try_charge()` call on a hot allocation path, or the
  `page_counter` for memory/memsw is now contended by more concurrent charging threads (common in
  container-density workloads with many tasks sharing one cgroup's memory controller).
- Confirm: `page_counter_try_charge` or `try_charge` hot in positive-delta stacks; regression
  scales with the number of concurrently-charging threads/containers, not with per-thread work.
  This is the memcg equivalent of the general `[LOCK-CONTENTION]` signature — flat hardware
  counters, throughput regression from atomic contention on the shared `page_counter`.
- Fix: batch charges (charge multiple pages at once via `mem_cgroup_charge_skmem`-style batching);
  avoid charging in a loop where a single batched charge would do; consider per-CPU charge caches
  if the kernel version supports them.

### rstat Flush Storm (`[LOCK-CONTENTION]`)

- FBC adds a new per-CPU statistic that must be aggregated by `cgroup_rstat_flush()`, or increases
  the frequency of flush calls (e.g. a new `stat_show`-style read path that flushes on every read).
  With many cgroups (container-dense hosts), flush cost scales with cgroup tree depth × CPU count.
- Confirm: `cgroup_rstat_flush_locked` hot in positive-delta stacks; regression only visible on
  hosts with many cgroups/containers, absent on a bare-metal (no-container) run of the same FBC —
  this cgroup-count sensitivity is the signature that distinguishes it from a generic locking bug.
- Fix: avoid flushing on every stat read if a cached/rate-limited value is acceptable; batch new
  per-CPU counters into the existing rstat flush rather than adding a second flush path.

### PSI Accounting Overhead (`[LOCK-CONTENTION]`)

- FBC adds a new scheduler state transition that triggers `psi_task_change()`/`psi_group_change()`
  on a hot path (e.g. a new blocking point, a new runnable-state transition). PSI is per-cgroup and
  the overhead is proportional to the number of nested cgroup levels the task belongs to (PSI
  propagates up the cgroup hierarchy).
- Confirm: `psi_group_change` hot in positive-delta stacks; regression worse on tasks nested deep
  in the cgroup hierarchy than on tasks at the root — depth-proportional cost is the signature.
- Fix: avoid adding new PSI-tracked state transitions to already-hot scheduling paths; check
  whether `psi_disabled`/boot param `psi=0` changes the regression magnitude to confirm PSI is the
  mechanism before proposing a fix.

### Per-Node objcg Indirection (`[MEMORY-BOUND]`)

- FBC relocates a per-memcg RCU pointer (e.g. `memcg->objcg`) into a `struct mem_cgroup_per_node`
  array (`memcg->nodeinfo[nid]->objcg`), adding a `numa_node_id()` call plus a second pointer
  dereference to a hot accessor used on every kmem charge (`current_obj_cgroup()`,
  `__get_obj_cgroup_from_memcg()`). Purpose is usually to prepare for node-scoped locking (e.g.
  LRU-lock scoping for a future reparenting change), not a bug in itself — but the accessor
  refactor adds real per-call overhead to the *charge* path even when node granularity is only
  needed by a separate, less-hot path (reparenting/offlining).
- Confirm: `perf-stat.i.ipc` drops sharply (spinners show HIGH ipc, so this is the opposite
  signature of `[LOCK-CONTENTION]`) while `perf-stat.i.cpi` and `cache-miss-rate%` both rise, with
  no new spinlock/mutex/atomic and no `flush_tlb_*` calls in the diff; regression is largest on
  workloads with an extremely high per-second charge rate (e.g. every syscall allocates
  `__GFP_ACCOUNT`/`SLAB_ACCOUNT` kernel memory) on multi-node NUMA hosts.
  Confirmed case: commit `01b9da291c49` ("mm: memcontrol: convert objcg to be per-memcg per-node
  type") regressed `stress-ng.switch.ops_per_sec` (`--switch-method mq`) by -65.92% on a 2-node
  Sapphire Rapids host — `ipc` 0.566→0.221, `cpi` 1.84→5.36, `cache-miss-rate%` 1.09%→1.82%; every
  `mq_send()` allocates from the `SLAB_ACCOUNT` `msg_msg` cache (`ipc/msgutil.c:alloc_msg()`),
  hitting `__memcg_slab_post_alloc_hook()` → `current_obj_cgroup()` on every call.
- Fix: check whether the hot accessor's fast path (e.g. a per-task cached objcg pointer) already
  bypasses the per-node lookup in the common case, and whether any node-indexing work
  (`numa_node_id()`, array indirection) is computed unconditionally in the function prologue even
  when the fast path doesn't need it — moving such computation to only the call sites that
  actually dereference the per-node field removes avoidable overhead without reverting the
  per-node design.

### Container Overhead as a Confound (not a bug)

- When the test runs inside a container, part of any regression may be explained by cgroup
  accounting/PSI/namespace overhead that is constant regardless of the FBC — i.e. the same
  regression percentage would appear for *any* FBC that adds similar-weight work, because the
  container tax is a fixed multiplier, not something the FBC introduced.
- Before attributing a regression to the FBC's logic, check whether the same job also has a
  bare-metal (non-container) variant in the result set; if the regression only appears in the
  containerized run and is proportional to the number of active cgroups, treat cgroup accounting
  overhead as a competing hypothesis alongside the FBC's own logic change.

---

## Key Files and Entry Points

| File | Purpose |
|---|---|
| `mm/memcontrol.c` | memcg charge/uncharge (`try_charge`, `mem_cgroup_charge`), reclaim stats |
| `kernel/cgroup/rstat.c` | Per-CPU stat aggregation (`cgroup_rstat_flush`, `cgroup_rstat_flush_locked`) |
| `kernel/sched/psi.c` | Pressure Stall Information (`psi_task_change`, `psi_group_change`) |
| `kernel/cgroup/cgroup.c` | Core cgroup v2 hierarchy management |
| `block/blk-cgroup.c` | Block I/O cgroup accounting (`blkcg`) |
| `include/linux/memcontrol.h` | `mem_cgroup` / `page_counter` struct layout |
