# sysbench Suite Reference

> Loaded when the result's `suite:` or test prefix is `sysbench`.

## Related subsystem files

Load based on the sub-test variant (see table below):

- [../subsystems/locking.md](../subsystems/locking.md) — sysbench-mutex, sysbench-threads
- [../subsystems/mm.md](../subsystems/mm.md) — sysbench-memory
- [../subsystems/vfs.md](../subsystems/vfs.md) — sysbench-fileio

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `sysbench-cpu` | User-space CPU; entry/exit overhead | `entry_SYSCALL_64`, `do_syscall_64` | — |
| `sysbench-memory` | `mm/` page faults + TLB | `do_anonymous_page`, `__handle_mm_fault` | mm |
| `sysbench-mutex` | `kernel/futex/` | `futex_wait`, `futex_wake`, `get_futex_key` | locking |
| `sysbench-threads` | `kernel/futex/` + `kernel/sched/` | `futex_wait_setup`, `try_to_wake_up` | locking + sched |
| `sysbench-fileio` | VFS page cache + block layer | `vfs_read`, `vfs_write`, `generic_file_read_iter` | vfs |

## Suite Characteristics

- Reports `events/sec` or `MiB/sec` (higher = better); regression = negative `perf_change`.
- **sysbench-cpu**: tight loop computing prime numbers; not sensitive to kernel changes unless
  scheduler overhead or syscall entry cost increases.
- **sysbench-memory**: large memory region read/write; bottleneck is TLB miss rate and NUMA
  placement. FBC changes that widen TLB flush scope or change page allocation policy regress this.
  Confirm with `[TLB-BOUND]` or `[MEMORY-BOUND]` hw_tag.
- **sysbench-mutex**: N threads competing for a single mutex (implemented via futex). Classic
  `[LOCK-CONTENTION]` benchmark; directly measures futex hot path cost.
  FBC changes to `kernel/futex/`, futex hash table size, or `rwsem` layout show up immediately.
- **sysbench-threads**: threads competing on mutexes; wakeup latency + futex overhead.
  More sensitive to `try_to_wake_up` / `select_task_rq_fair` cost than sysbench-mutex alone.
- **sysbench-fileio**: mixed random/sequential file I/O; check `job.yaml` for `--file-test-mode`
  (seqrd/seqwr/rndrd/rndwr). Block device vs. in-memory filesystem matters.
- sysbench reports percentile latencies as well; check `sysbench.*.p99` metrics — higher = better
  is FALSE for latency metrics (check via [../metrics.md](../metrics.md)).
