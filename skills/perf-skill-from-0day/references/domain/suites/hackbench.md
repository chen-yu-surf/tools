# hackbench Suite Reference

> Loaded when the result's `suite:` or test prefix is `hackbench`.

## Related subsystem files

- [../subsystems/sched.md](../subsystems/sched.md) — wakeup latency, CFS load balancing
- [../subsystems/locking.md](../subsystems/locking.md) — pipe / socket send-side locks

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `hackbench` (pipes) | `kernel/sched/` + pipes | `__schedule`, `try_to_wake_up`, `pipe_write` | sched + locking |
| `hackbench -s` (sockets) | `kernel/sched/` + net | `__schedule`, `try_to_wake_up`, `tcp_sendmsg` | sched + net |

## Suite Characteristics

- Creates groups of sender/receiver threads communicating over pipes (default) or UNIX sockets.
  Reports **time** to complete N rounds — lower = better; regression = positive `perf_change`.
- Primary bottleneck is wakeup latency (`try_to_wake_up`, `select_task_rq_fair`). A regression
  in `__schedule` or CFS group scheduling (`sched_entity`, `cfs_rq`) is the most common root cause.
- `pipe_write` is the IPC side; check `fs/pipe.c` for pipe-buffer limit or wakeup changes.
- hackbench is sensitive to scheduler affinity and NUMA topology. On multi-socket machines,
  `[MEMORY-BOUND]` from cross-node wakeups can appear even for a scheduler-only FBC.
- The result metric is `hackbench.time` or `hackbench.throughput`; check polarity from
  [../metrics.md](../metrics.md).
