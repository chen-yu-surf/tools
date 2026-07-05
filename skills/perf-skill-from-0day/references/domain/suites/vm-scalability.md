# vm-scalability Suite Reference

> Loaded when the result's `suite:` or test prefix is `vm-scalability`.

## Related subsystem files

- [../subsystems/mm.md](../subsystems/mm.md) — anonymous faults, mmap, TLB, NUMA
- [../subsystems/locking.md](../subsystems/locking.md) — mmap_lock contention, per-VMA lock

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `anon-mmap-sequential` | `mm/mmap.c` + `mm/memory.c` | `do_mmap`, `do_anonymous_page`, `__handle_mm_fault` | mm |
| `anon-mmap-random` | `mm/memory.c` | `do_anonymous_page`, `__alloc_pages`, `zap_pte_range` | mm |
| `file-mmap-sequential` | `mm/filemap.c` + VFS | `filemap_get_pages`, `do_page_cache_ra` | mm + vfs |
| `anon-cow` | `mm/memory.c` | `do_wp_page`, `copy_page_range`, `__alloc_pages` | mm |
| `tmpfs-mmap-seq` | `mm/shmem.c` + `mm/memory.c` | `shmem_getpage_gfp`, `do_anonymous_page` | mm |
| `userfaultfd` | `mm/userfaultfd.c` | `userfaultfd_ctx_read`, `handle_userfault` | mm |

## Suite Characteristics

- Reports `ops_per_second` (higher = better) per stressor per CPU count; regression = negative
  `perf_change`.
- Designed to **scale across CPU counts** (1 → N); the regression is typically visible on
  high thread counts but not at low thread counts. Check the `nr_task` field in `job.yaml`.
- `anon-mmap-sequential`: `mmap()` + sequential access; bottleneck is
  `do_anonymous_page` (page-fault path) at high thread counts. FBC changes that add per-fault
  overhead or extend `mmap_lock` hold time are directly measurable.
- `anon-cow`: COW page-fault-intensive; any FBC that adds per-page work to `do_wp_page`
  (e.g. new rmap operations, extra accounting) regresses this stressor.
- `file-mmap-sequential`: page cache read via mmap; bottleneck is `filemap_get_pages` and
  `__page_cache_alloc`; sensitive to page reclaim pressure at high memory usage.
- **mmap_lock vs. per-VMA lock**: since kernel 6.6, anonymous page faults can use per-VMA
  `vm_lock` (rwsem) instead of the process-wide `mmap_lock`. FBC changes to VMA metadata that
  force `mmap_write_lock()` instead of `vma_start_write()` directly increase lock contention
  here. Check `vma_start_read` / `lock_vma_under_rcu` in perf-profile.
- `[MEMORY-BOUND]` is the most common hw_tag; `[LOCK-CONTENTION]` appears when mmap_lock or
  per-VMA lock becomes the bottleneck at high CPU counts.
- Compare results across different `nr_task` values: a flat-line degradation suggests per-fault
  overhead; a degradation that worsens with thread count suggests lock contention.
