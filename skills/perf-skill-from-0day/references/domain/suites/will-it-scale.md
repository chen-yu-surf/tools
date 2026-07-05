# will-it-scale Suite Reference

> Loaded when the result's `suite:` or test prefix is `will-it-scale`.

## Related subsystem files

Load these alongside this file based on the stressor (see table below):

- [../subsystems/mm.md](../subsystems/mm.md) — mmap1, mmap2, malloc1
- [../subsystems/vfs.md](../subsystems/vfs.md) — open1, open2, read1, write1
- [../subsystems/locking.md](../subsystems/locking.md) — lock1, futex1

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `mmap1` / `mmap2` | `mm/mmap.c` | `do_mmap`, `mmap_write_lock`, `vm_mmap_pgoff` | mm |
| `open1` / `open2` | VFS dcache | `lookup_fast`, `path_openat`, `d_lookup` | vfs |
| `read1` / `write1` | VFS page cache | `vfs_read`, `generic_file_read_iter`, `filemap_get_pages` | vfs |
| `futex1` | `kernel/futex/` | `futex_wait`, `futex_wake`, `get_futex_key` | locking |
| `lock1` | spinlock / rwsem | `_raw_spin_lock`, `rwsem_down_read_slowpath` | locking |
| `malloc1` | `mm/` slab + mmap | `kmem_cache_alloc`, `do_anonymous_page` | mm |

## Suite Characteristics

- Spawns N processes each running the same syscall in a tight loop; reports `per_process_ops`.
  Higher `per_process_ops` = better throughput → regression = negative `perf_change`.
- Scales from 1 to max-CPU threads; regressions often appear only at high thread counts (contention
  threshold). Check whether the regression is present at 1 thread (fundamental overhead) or only at
  N threads (contention).
- `mmap1`/`mmap2` differ in whether the mapping is private or shared — look for `VM_SHARED`-gated
  paths in the diff.
- `lock1` is a pure spinlock benchmark; any `[LOCK-CONTENTION]` signal here is almost certainly
  the root cause.
- `futex1` uses `FUTEX_WAIT`/`FUTEX_WAKE`; check both `kernel/futex/core.c` and any hash-table or
  key-computation changes in the FBC.
