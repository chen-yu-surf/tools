# lmbench Suite Reference

> Loaded when the result's `suite:` or test prefix is `lmbench`.

## Related subsystem files

- [../subsystems/mm.md](../subsystems/mm.md) — page faults, TLB, memory hierarchy

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `lat_mem_rd` | `arch/x86/mm/` + memory hierarchy | `__do_page_fault`, memory hierarchy latency | mm |
| `lat_proc` | `kernel/fork.c` | `do_fork`, `copy_mm` | fork |
| `lat_syscall` | `arch/x86/entry/` | `entry_SYSCALL_64`, `do_syscall_64` | — |
| `lat_pipe` | `fs/pipe.c` + `kernel/sched/` | `pipe_write`, `try_to_wake_up` | sched + locking |
| `bw_pipe` (`PIPE.bandwidth`) | `fs/pipe.c` | `anon_pipe_write`, `anon_pipe_read`, contend on `pipe->mutex` | vfs |
| `bw_mem` | `mm/` + cache hierarchy | `copy_user_generic`, `clear_page` | mm |

## Suite Characteristics

- lmbench reports **latency** (ns or µs) — lower = better; regression = positive `perf_change`.
- `lat_mem_rd` walks a pointer chain through increasing array sizes to measure memory hierarchy
  (L1/L2/L3/DRAM) latency. A regression here usually means:
  - New per-page or per-cacheline overhead (extra write in alloc or fault path touching data pages)
  - NUMA placement change causing remote DRAM accesses
  - TLB pressure from a wider flush scope
- `lat_mem_rd` regressions are **extremely sensitive to false sharing**: adding a field to a struct
  that strands a hot field onto the next cacheline shows up immediately as a latency step.
- For `lat_syscall`, check `arch/x86/entry/` and any new overhead added to `do_syscall_64` or
  the seccomp/ftrace paths.
- `bw_pipe` (`lmbench3.PIPE.bandwidth.MB/sec`) drives many parallel writer/reader thread pairs
  each looping `write(2)`/`read(2)` on a private pipe; both sides serialize on the same
  per-pipe `pipe->mutex`, so mutex hold time directly gates throughput. Confirmed by `212ed884a1ae`
  (+25.86% from shortening the critical section) — see [../subsystems/vfs.md](../subsystems/vfs.md).
