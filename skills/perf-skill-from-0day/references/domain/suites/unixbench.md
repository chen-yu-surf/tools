# unixbench Suite Reference

> Loaded when the result's `suite:` or test prefix is `unixbench`.

## Related subsystem files

- [../subsystems/fork.md](../subsystems/fork.md) — spawn, fork, exec paths

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `spawn` | `kernel/fork.c` | `do_fork`, `copy_mm`, `dup_mmap` | fork |
| `fork` | `kernel/fork.c` | `do_fork`, `copy_process` | fork |
| `exec` | `fs/exec.c` + `kernel/fork.c` | `do_execveat_common`, `load_elf_binary` | fork + vfs |
| `pipe` | `fs/pipe.c` + `kernel/sched/` | `pipe_write`, `pipe_read`, `try_to_wake_up` | sched + locking |
| `syscall` | `arch/x86/entry/` | `entry_SYSCALL_64` | — |

## Suite Characteristics

- unixbench reports a score (higher = better) normalised against a reference system.
  Regression = negative `perf_change`.
- `spawn` is the most commonly regressed stressor; it calls `fork()` + `wait()` in a tight loop.
  Any added per-process or per-mm initialisation overhead in `copy_process` or `dup_mmap` directly
  slows spawn.
- `exec` additionally invokes `do_execveat_common`; check `fs/exec.c` and `arch/x86/` for ABI or
  vDSO changes that add per-exec overhead.
- `pipe` measures wakeup latency via ping-pong over a pipe; similar to hackbench but
  single-threaded — regression here usually means `try_to_wake_up` or `pipe_write` overhead.
