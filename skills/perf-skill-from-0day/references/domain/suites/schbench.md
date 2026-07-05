# schbench Suite Reference

> Loaded when the result's `suite:` or test prefix is `schbench`.

## Related subsystem files

- [../subsystems/sched.md](../subsystems/sched.md) — wakeup latency, task placement
- [../subsystems/locking.md](../subsystems/locking.md) — futex wait/wake path

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `schbench` | `kernel/futex/` + `kernel/sched/` | `futex_wait`, `futex_wake`, `try_to_wake_up`, `select_task_rq_fair` | sched + locking |

## Suite Characteristics

- Measures **scheduler wakeup latency** under realistic messenger-worker workloads.
  Reports percentile latencies: `schbench.50th_p`, `schbench.95th_p`, `schbench.99th_p`,
  `schbench.max_lat_us` — **lower = better**; regression = positive `perf_change`.
- Primary hot path: messenger thread signals worker threads via futex; measures time from
  `futex_wake` to the worker first running.
- Latency breakdown:
  1. `futex_wake` → `try_to_wake_up` (scheduler fast-path)
  2. `select_task_rq_fair` / `find_idlest_cpu` (placement decision)
  3. Context switch + preemption overhead
  4. IPI cost to kick the target CPU
- **Most sensitive to**: scheduler affinity changes, IPI overhead, per-task initialisation
  overhead, and any added work in `try_to_wake_up` or the CFS/EEVDF wakeup fast-path.
- On NUMA machines, cross-node wakeups inflate tail latency (`schbench.99th_p`) even for a
  non-NUMA FBC. Compare single-socket vs. multi-socket result roots when available.
- The `schbench.max_lat_us` metric is the most noisy; rely on `schbench.99th_p` for
  regression signal.
- FBC introducing a new `sched_setattr()` call, cgroup overhead, or a per-wakeup memory
  allocation will show up here before it shows up in throughput benchmarks.
