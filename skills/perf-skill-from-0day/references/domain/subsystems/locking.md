# locking Subsystem Reference

> Loaded when the FBC diff touches `kernel/locking/`, `kernel/futex/`,
> `include/linux/spinlock*.h`, `include/linux/rwsem.h`, `include/linux/mutex.h`,
> `include/linux/futex.h`, or any file adding/removing lock acquisitions in a hot path.

---

## Hot-Path Functions → Regression Type

| Function (or prefix) | Regression type | Tag | Where to look in the diff |
|---|---|---|---|
| `native_queued_spin_lock_slowpath` | Spinlock contention | `[LOCK-CONTENTION]` | Any spinlock-protected field or critical section modified by FBC |
| `rwsem_down_read_slowpath` / `rwsem_down_write_slowpath` | rwsem contention | `[LOCK-CONTENTION]` | `rw_semaphore` layout change; new `down_read()` calls in hot path |
| `mmap_read_lock` / `mmap_write_lock` | mmap_lock contention | `[LOCK-CONTENTION]` | New code paths calling `mmap_read/write_lock()` |
| `futex_wait` / `futex_wake` / `get_futex_key` | futex overhead | — | `kernel/futex/`; hash-table or key-computation changes |
| `rcu_read_lock` / `synchronize_rcu` | RCU overhead | — | Spinlock-to-RCU conversion adding grace-period waits |
| `mutex_lock_slowpath` | mutex contention | `[LOCK-CONTENTION]` | New mutex added or critical section extended |
| `rcu_sched_clock_irq` / `note_gp_changes` / dmesg `rcu_sched detected stalls` | RCU stall warning | `[LOCK-CONTENTION]` risk + functional risk | Long `rcu_read_lock()` critical section, missing `cond_resched()`, or preemption/IRQ disabled across a call that can block |

## Regression Patterns Specific to locking

**Spinlock contention** (`[LOCK-CONTENTION]`):
- FBC extended a critical section under an existing spinlock, or added new spinlock acquisitions
  in a hot path.
- Confirm: `native_queued_spin_lock_slowpath` dominant in positive-delta perf stacks.
  All hardware counters flat (spinners burn cycles waiting, maintaining high IPC) while throughput
  regresses — classic contention signature.
- Fix: narrow the critical section; per-CPU data to avoid shared-state writes; seqlock for
  read-dominated paths.

**rwsem contention** (`[LOCK-CONTENTION]`):
- FBC changed `rw_semaphore` layout (adding a field shifts the reader count register) or added
  new `down_read()` calls in a path exercised by many threads simultaneously.
- Confirm: `rwsem_down_read_slowpath` or `rwsem_down_write_slowpath` in positive-delta stacks.
- Fix: convert to RCU for read-dominated paths; per-CPU counters; reduce write-lock hold time.

**RCU overhead**:
- FBC converted a spinlock to RCU, adding `synchronize_rcu()` calls on the write side that cause
  grace-period stalls under high write rates.
- Confirm: `synchronize_rcu` in positive-delta stacks; `rcu_gp_kthread` CPU usage increased.
- Fix: batch updates; use `call_rcu()` (async) instead of `synchronize_rcu()` (synchronous);
  per-CPU shadow variables.

**RCU stall warning** (distinct from RCU overhead above — this is a *correctness/latency-cliff*
pattern, not a steady-state throughput cost):
- FBC lengthens an `rcu_read_lock()`/`rcu_read_lock_sched()` critical section (a loop that grew,
  a new call that can block, or a removed `cond_resched()`), or disables preemption/IRQs across a
  path that now runs long enough to exceed `CONFIG_RCU_CPU_STALL_TIMEOUT` (default 21s, often
  lowered in CI kconfigs).
- Confirm: dmesg/console log contains `rcu_sched self-detected stall on CPU` or
  `rcu_preempt detected stalls on CPUs/tasks`; test throughput shows a step-function cliff
  (not a smooth percentage regression) coinciding with the stall, sometimes followed by a soft
  lockup or watchdog reset. This is a categorically different signature from the gradual
  grace-period-under-load overhead described above — a single long critical section can produce
  the stall even at low load.
- Fix: add `cond_resched()` (or `cond_resched_rcu()`) inside the lengthened loop; shorten the
  critical section by moving allocation/blocking calls outside `rcu_read_lock()`; convert to
  `rcu_read_lock_bh()`/preemptible RCU if the section must call something that can sleep on
  `PREEMPT_RT`. Treat any FBC-introduced stall warning as a correctness bug, not just a perf
  regression — do not propose a revert for the underlying feature if it fixes a real issue;
  narrow the critical section instead.

**futex regression**:
- FBC changed the futex hash table size, key computation (`get_futex_key`), or per-wait overhead.
- Confirm: `get_futex_key` or `futex_wait_setup` in positive-delta stacks.
- Fix: check hash distribution; avoid per-wait memory allocation; reduce key-lookup overhead.

## Key Files and Entry Points

| File | Purpose |
|---|---|
| `kernel/locking/spinlock.c` | Spinlock slow paths |
| `kernel/locking/rwsem.c` | `rwsem_down_read_slowpath`, `rwsem_down_write_slowpath` |
| `kernel/locking/mutex.c` | `mutex_lock_slowpath` |
| `kernel/futex/core.c` | `futex_wait`, `futex_wake`, `get_futex_key` |
| `kernel/rcu/tree.c` | `synchronize_rcu`, `rcu_gp_kthread`, `rcu_sched_clock_irq` (stall detection) |
| `include/linux/rwsem.h` | `rw_semaphore` struct — layout changes affect all rwsem users |
