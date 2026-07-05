# mm Subsystem Reference

> Loaded when the FBC diff touches `mm/`, `arch/x86/mm/`, `include/linux/mm*.h`,
> `include/linux/page*.h`, `include/linux/gfp*.h`, `include/linux/slab*.h`,
> `lib/maple_tree.c`, or `include/linux/maple_tree.h`.

---

## Hot-Path Functions → Regression Type

When a function appears with a **large positive delta** in the perf-profile, infer the regression
type. Function names marked with a tag directly override the perf-stat hardware counter
classification.

| Function (or prefix) | Regression type | Tag | Where to look in the diff |
|---|---|---|---|
| `smp_call_function_many` / `flush_tlb_others` | IPI / TLB shootdown | `[TLB-BOUND]` | TLB flush scope widened; new `flush_tlb_*` calls added |
| `do_anonymous_page` / `__handle_mm_fault` | Page fault overhead | (check perf-stat) | `mm/memory.c`; new per-fault work (rmap, LRU, accounting) |
| `__alloc_pages` / `rmqueue` / `get_page_from_freelist` | Page allocator overhead | (check perf-stat) | `mm/page_alloc.c`; new per-page bookkeeping or watermark checks |
| `folio_add_lru` / `lru_add_drain` | LRU overhead | — | `mm/swap.c`; LRU list manipulation added to alloc path |
| `migrate_folio_move` / `deferred_split_folio` | THP deferred-split queue tracking | `[MEMORY-BOUND]` | `mm/migrate.c`; a src→dst folio transform (migration) must forward `_deferred_list` membership or underused THPs silently escape the shrinker |
| `__kmem_cache_alloc_node` / `slab_alloc_node` | Slab allocator overhead | — | `mm/slub.c`; new fields initialised per allocation |
| `mmap_read_lock` / `mmap_write_lock` | mmap_lock contention | `[LOCK-CONTENTION]` | New code paths calling `mmap_read/write_lock()` in hot path |
| `vma_start_read` / `lock_vma_under_rcu` | Per-VMA lock overhead | `[LOCK-CONTENTION]` | `mm/memory.c`; added since kernel 6.6 — per-VMA rwsem for page-fault path |
| `mtree_load` / `vma_find` / `vma_iter_next_range` | Maple tree VMA lookup overhead | `[MEMORY-BOUND]` | `lib/maple_tree.c`; since kernel 6.1, VMAs stored in maple tree; new traversal cost |
| `thp_get_unmapped_area` / `alloc_transhuge_page` | mTHP allocation overhead | (check perf-stat) | `mm/huge_memory.c`; since kernel 6.8+ mTHP; allocation per order-N folio; FBC that widens mTHP eligibility or adds per-order accounting regresses this path |
| `anon_vma_chain_link` / `__anon_vma_interval_tree_insert` | anon_vma overhead | `[LOCK-CONTENTION]` | `mm/rmap.c`; since kernel 6.10 anon_vma scalability improvements; FBC that reverts or bypasses these can re-introduce contention |
| `filemap_map_pages` / `do_fault_around` | mmap fault-around / readahead interaction | `[MEMORY-BOUND]` | `mm/filemap.c`; FBC that reduces `f_ra.mmap_miss` credit rate can cause `mmap_miss > MMAP_LOTSAMISS (100)` cliff — see readahead cliff pattern below |

## Regression Patterns Specific to mm

**TLB shootdown** (`[TLB-BOUND]`):
- FBC widened flush scope from `flush_tlb_page()` → `flush_tlb_range()` or `flush_tlb_mm()`.
- New call added in a hot path (e.g. `do_mmap`, `unmap_vmas`).
- Fix: use `flush_tlb_page()` for single-page; `arch_tlbbatch_add_mm()` + `arch_tlbbatch_flush()`
  for batching; avoid flushes for private anonymous mappings no other CPU has mapped.

**Page fault overhead** (`[MEMORY-BOUND]` or general):
- New per-fault work in `do_anonymous_page` or `handle_mm_fault` (extra accounting, rmap insert,
  LRU promotion).
- Fix: lazy init (defer until first use); batch; per-CPU caches instead of per-alloc atomics.

**Struct layout / false sharing** (`[MEMORY-BOUND]`):
- FBC added a new field to a struct used in hot loops, pushing a frequently-read field to the
  next cacheline.
- Confirm with `pahole -C <struct> vmlinux` — check that the two fields fit in the same 64-byte
  cacheline.
- Fix: reorder fields; `____cacheline_aligned_in_smp`; `__cacheline_group_begin/end`.

**NUMA locality change** (`[MEMORY-BOUND]`):
- FBC changed per-CPU or per-node allocation policy, causing remote DRAM accesses.
- Check `alloc_pages_node()` vs. `alloc_pages()` changes; verify on multi-socket result roots.
- Fix: `alloc_pages_node(numa_node_id(), ...)` or per-node variables.

**Slab overhead**:
- New per-allocation field initialisation in `kmem_cache_alloc` hot path.
- Fix: initialise lazily or move to object constructor.

**Deferred-split queue tracking loss across migration** (`[MEMORY-BOUND]`, THP shrinker):
- A src→dst object-transform function (e.g. `migrate_folio_move()`) unqueues the source from a
  per-object tracking list (`_deferred_list`, the THP shrinker's underused-THP queue) as a side
  effect of the transform, but never re-queues the destination — so tracked folios silently
  escape the shrinker after every migration, letting underused THPs accumulate unreclaimed and
  raising memory pressure.
- Confirm: diff adds a conditional `deferred_split_folio(dst, ...)` call guarded by a
  pre-transform snapshot of the source's `list_empty(&src->_deferred_list)` /
  `folio_test_partially_mapped(src)` state (state must be captured **before** the unqueue, since
  it happens inside the transform).
- Confirmed example: commit `a2e0c0668a3486f9` ("mm: migrate: requeue destination folio on
  deferred split queue") — fixed exactly this gap in `mm/migrate.c:migrate_folio_move()`;
  measured perf-stat.i deltas on a 2-node NUMA host: cache-misses -63%, MPKI -62%,
  cpu-migrations -81%, major-faults -74%, minor-faults +229% (more, cheaper local faults
  replacing fewer, more expensive migration-driven ones); `stress-ng.memthrash.ops_per_sec`
  +31.83%. No other in-tree `deferred_split_folio()`/`move_to_new_folio()` call site shared the
  gap at time of analysis (the other two `deferred_split_folio()` callers operate on a single
  folio, not a src/dst pair; hugetlb's `move_to_new_folio()` caller doesn't use `_deferred_list`
  at all).
- Fix: generalize as — any function that transforms/replaces an object while it holds
  membership on a size-class or type-specific tracking list must explicitly propagate that
  membership (and any state needed to re-derive it) to the new object, captured before the
  transform removes it from the source.

**Maple tree VMA overhead** (`[MEMORY-BOUND]`, kernel ≥ 6.1):
- FBC changed maple tree node layout or added a new per-VMA walk in a hot path (`handle_mm_fault`,
  `mmap_region`, `find_vma`).
- Confirm: `mtree_load` / `mas_walk` / `vma_iter_next_range` in positive-delta stacks.
- Fix: batch VMA lookups; avoid full tree traversal for single-VMA operations; use `vma_find()`
  (O(log n) maple tree lookup) instead of a linear walk.

**Per-VMA lock contention** (`[LOCK-CONTENTION]`, kernel ≥ 6.6):
- FBC forces upgrade from `vma_start_read()` (per-VMA shared lock) to `mmap_write_lock()` (mm-wide
  exclusive lock) for page-fault paths, eliminating the per-VMA lock's parallelism benefit.
- Confirm: `mmap_write_lock` replaces `vma_start_read` in positive-delta stacks; regression visible
  at high thread counts on vm-scalability or will-it-scale mmap stressors.
- Fix: ensure VMA metadata written by the FBC is protected by the per-VMA `vm_lock` (not the global
  `mmap_lock`) so page-fault paths remain parallel.

**Folio API migration overhead** (kernel ≥ 5.16):
- FBC converted `struct page`-based paths to folio-based paths, adding new `folio_*` accounting
  calls (e.g. `folio_add_lru_vma`, `folio_mark_accessed`) per page fault or cache hit.
- Confirm: new `folio_*` functions in positive-delta stacks alongside `do_anonymous_page`.
- Fix: batch folio operations; use folio-sized chunks to amortise per-page overhead.

**mTHP (multi-size THP) overhead** (kernel ≥ 6.8; rapidly expanding in 6.10–6.13):
- mTHP enables huge pages at intermediate orders (e.g. order-2 to order-7) for anonymous memory,
  shmem (6.11), and swap (6.10+). Allocation overhead was 41% above baseline in early kernels;
  reduced to ~5.5% by kernel 6.13 (commit 4835f747).
  - FBCs that widen mTHP eligibility criteria, add per-folio accounting at allocation time, or
    remove batching optimizations will regress `alloc_transhuge_page` / `thp_get_unmapped_area`.
  - FBCs that split underused THPs (policy introduced in 6.12, commit 81d3ff3c) add overhead
    via `split_huge_page` in reclaim paths for workloads with `THP=always` policy.
- Confirm: `alloc_transhuge_page` / `split_huge_page` in positive-delta stacks;
  check whether regression scales with mTHP order or with page-fault rate.
- Fix: amortise per-order accounting; verify that new eligibility checks are O(1); defer
  THP splitting to reclaim pressure rather than proactively splitting on every access.

**anon_vma scalability regression** (kernel ≥ 6.10):
- Kernel 6.10 improved `anon_vma` scalability (commit 737019cf) to reduce contention in
  `anon_vma_chain_link` / `__anon_vma_interval_tree_insert` at high fork/COW rates.
  FBCs that add new per-VMA rmap operations, extend anon_vma chain traversal, or increase
  the anon_vma lock hold time can reintroduce contention.
- Confirm: `anon_vma_chain_link` or `page_add_anon_rmap` in positive-delta stacks;
  `[LOCK-CONTENTION]` tag; regression visible on vm-scalability `anon-cow` stressor.
- Fix: check whether the new per-VMA work can be deferred until unmapping; batch rmap
  insertions; avoid holding the anon_vma lock while calling back into the allocator.

**vmalloc lock contention** (kernel ≥ 6.9/6.10):
- Kernel 6.10 reduced vmalloc lock acquisitions (from twice to once per allocation). FBCs
  that add new vmalloc calls in hot paths, or revert this batching, will show `vmap_*` /
  `vmalloc_lock` overhead at high CPU counts.
- Confirm: `__vmalloc_node` / `vmap_pages_range` in positive-delta stacks; `[LOCK-CONTENTION]`
  at high thread counts only (lock is a global mutex).
- Fix: cache vmalloc'd regions across calls; prefer slab/kmalloc for small frequently-allocated
  objects; batch vmalloc allocations in setup paths.

**mmap readahead cliff (MMAP_LOTSAMISS)** (`[MEMORY-BOUND]`, file-backed mmap workloads):
- Constant: `MMAP_LOTSAMISS = 100` (`mm/filemap.c`). When `f_ra.mmap_miss > 100`,
  `do_sync_mmap_readahead()` (line ≈3370) returns immediately with no readahead fired.
- `f_ra.mmap_miss` is incremented in `do_sync_mmap_readahead()` on each sync readahead trigger,
  and decremented in `filemap_map_pages()` (fault-around path) and `do_async_mmap_readahead()`.
  FBCs that reduce the decrement rate in `filemap_map_pages()` cause `mmap_miss` to cross 100
  after far fewer faults, disabling readahead entirely for the file.
- Confirmed by commit `0b9c0aeba938` on `pts/graphics-magick Swirl`: decrement reduced from
  N (one per non-workingset folio in fault-around window) to 1 (faulting address only).
  Result: `major-faults` +5895%, throughput −8.83% on lkp-gnr-2sp3 (Granite Rapids 2S).
- Symptom: large `perf-stat.major-faults` increase (10×+) with unchanged `minor-faults`;
  workload is file-backed mmap with sequential or spatial access pattern.
- Fix direction: restore partial proportional credit (e.g. 1 credit per N surrounding pages,
  capped) so dense fault-around windows keep readahead alive without over-crediting sparse ones.

## Key Files and Entry Points

| File | Purpose |
|---|---|
| `mm/mmap.c` | Virtual address space creation (`do_mmap`, `mmap_write_lock`) |
| `mm/memory.c` | Page fault handling (`handle_mm_fault`, `do_anonymous_page`) |
| `mm/page_alloc.c` | Physical page allocation (`__alloc_pages`, `rmqueue`) |
| `mm/slub.c` | Slab object allocation (`__kmem_cache_alloc_node`) |
| `mm/swap.c` | LRU list management (`folio_add_lru`, `lru_add_drain`) |
| `mm/huge_memory.c` | THP/mTHP allocation (`alloc_transhuge_page`, `split_huge_page`) — mTHP from 6.8+ |
| `mm/rmap.c` | Reverse mapping (`anon_vma_chain_link`, `page_add_anon_rmap`) — scalability improved in 6.10 |
| `mm/vmalloc.c` | vmalloc allocator (`__vmalloc_node`) — lock reduction in 6.10 |
| `arch/x86/mm/tlb.c` | TLB shootdown IPI path (`flush_tlb_others`, `native_flush_tlb_multi`) |
| `include/linux/mm.h` | Core mm types and inline helpers |
| `lib/maple_tree.c` | Maple tree VMA index (`mtree_load`, `mas_walk`) — kernel 6.1+ |
| `mm/memory.c` | Per-VMA lock path (`vma_start_read`, `lock_vma_under_rcu`) — kernel 6.6+ |
