# stress-ng Suite Reference

> Loaded when the result's `suite:` or test prefix is `stress-ng`.

## Related subsystem files

- [../subsystems/mm.md](../subsystems/mm.md) — --bigheap, --mmap, --malloc
- [../subsystems/fork.md](../subsystems/fork.md) — --pthread, --fork, --clone
- [../subsystems/sched.md](../subsystems/sched.md) — --session, --yield, --context-switch, --sched
- [../subsystems/net.md](../subsystems/net.md) — --sigurg
- [../subsystems/cgroup.md](../subsystems/cgroup.md) — --switch --switch-method mq (msg_msg SLAB_ACCOUNT allocation hits the memcg kmem-charge hot path on every send/receive)

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `--bigheap` | `mm/` anonymous pages | `do_anonymous_page`, `__handle_mm_fault`, `alloc_pages` | mm |
| `--mmap` | `mm/mmap.c` | `do_mmap`, `handle_mm_fault`, `mmap_write_lock` | mm |
| `--malloc` | `mm/` slab | `kmem_cache_alloc`, `__slab_alloc`, `slab_alloc_node` | mm |
| `--pthread` | `kernel/fork.c` | `copy_process`, `clone_thread`, `dup_mm` | fork |
| `--fork` | `kernel/fork.c` | `do_fork`, `copy_mm`, `dup_mmap` | fork |
| `--clone` | `kernel/fork.c` | `copy_process`, `copy_mm` | fork |
| `--session` | `kernel/sched/` CFS task-group + `kernel/sys.c` setsid | `sched_fork`, `enqueue_task_fair`, `list_add_leaf_cfs_rq`, `tg_unthrottle_up`; setsid creates new process group → triggers cgroup/task-group scheduler paths | sched |
| `--yield` | `kernel/sched/fair.c` | `yield_task_fair`, `update_curr`, `pick_next_task_fair` | sched |
| `--context-switch` | `kernel/sched/core.c` | `__schedule`, `context_switch`, `finish_task_switch` | sched |
| `--sched` | `kernel/sched/` | `sched_setscheduler`, `__sched_setscheduler` | sched |
| `--memthrash` | `mm/` folio migration / THP shrinker | `migrate_folio_move`, `deferred_split_folio`, `task_numa_fault` (on multi-node hosts) | mm |
| `--sigurg` | `net/ipv4/tcp_input.c` TCP receive admission | `tcp_data_queue`, `tcp_try_rmem_schedule`, `tcp_can_ingest`, `tcp_prune_queue` | net |
| `--switch --switch-method mq` | `ipc/mqueue.c` POSIX mqueue send/receive → `ipc/msgutil.c:alloc_msg()` (SLAB_ACCOUNT `msg_msg` cache) → memcg kmem-charge hook | `do_mq_timedsend`, `do_mq_timedreceive`, `alloc_msg`, `__memcg_slab_post_alloc_hook`, `current_obj_cgroup` | cgroup |

## Suite Characteristics

- Runs each stressor for a fixed duration and reports `bogo-ops/s`; higher = better.
- `--bigheap` repeatedly extends the heap via `brk()`; the key hot path is
  `do_anonymous_page` on demand faults, not `do_mmap`.
- `--malloc` uses glibc malloc which calls `brk()` or `mmap()` for large allocations; distinguish
  slab-path (small allocs) from mmap-path (large allocs) using the perf-profile call chain.
- `--pthread` creates and joins threads rapidly; the hot path is `clone()` → `copy_process()`;
  check `dup_mm` and `copy_thread_tls` for per-thread overhead added by the FBC.
- Many stress-ng stressors share an mm-intensive hot path; if the specific stressor is not in the
  table above, check the perf-profile chain and load the nearest subsystem file.
- `--memthrash` on multi-node NUMA hosts drives folio migration (NUMA balancing / compaction)
- `--sigurg` sends TCP out-of-band (`MSG_OOB`) data over loopback socket pairs to trigger
  `SIGURG` signal delivery; the send/recv loop pushes RPC-sized bursts through
  `tcp_data_queue()`'s per-segment admission check (`tcp_can_ingest()`) on every incoming skb —
  confirmed via `026dfef287c0` analysis (2026-07): `ops_per_sec` is sensitive to spurious
  admission rejects/retransmits on this path, not just raw send/receive throughput.
  through `mm/migrate.c`; a fix restoring THP deferred-split-queue tracking across migration
  (commit `a2e0c0668a3486f9`) improved `ops_per_sec` +31.83% by letting the shrinker reclaim
  underused THPs again — see `../subsystems/mm.md` "Deferred-split queue tracking loss across
  migration" pattern.
