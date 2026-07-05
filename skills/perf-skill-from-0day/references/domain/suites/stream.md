# stream Suite Reference

> Loaded when the result's `suite:` or test prefix is `stream` or `tinymembench`.

## Related subsystem files

- [../subsystems/mm.md](../subsystems/mm.md) — NUMA placement, TLB, huge pages

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `stream` (copy/scale/add/triad) | `mm/` huge pages + NUMA placement | `__alloc_pages`, `__do_huge_mem_cgroup_charge`, `move_pages` | mm |
| `tinymembench` | `arch/x86/mm/` + memory hierarchy | Memory hierarchy latency + TLB | mm |

## Suite Characteristics

- Reports memory **bandwidth** in MB/s (higher = better) or latency in ns (lower = better).
  Regression = negative `perf_change` for bandwidth, positive for latency.
- `stream` is primarily a DRAM bandwidth benchmark; it accesses large arrays sequentially.
  **Not** sensitive to kernel scheduling overhead or lock contention, but highly sensitive to:
  - **NUMA placement**: FBC changes to `alloc_pages_node()` policy or `move_pages()` that
    route allocations to the wrong NUMA node; remote DRAM accesses are 2–5× slower.
  - **Huge page availability**: FBC changes to `mm/huge_memory.c` or transparent huge page
    policies that reduce THP coverage → more TLB misses, lower bandwidth.
  - **TLB shootdown scope**: FBC that broadens `flush_tlb_*` calls increases IPI overhead,
    indirectly reducing throughput for concurrent workers.
- `tinymembench` measures pointer-chain and sequential memory access latency at each cache
  level; useful for diagnosing false-sharing or cacheline layout changes (same role as `lmbench
  lat_mem_rd`).
- stream regressions almost always carry a `[MEMORY-BOUND]` or `[TLB-BOUND]` hw_tag.
- When stream regresses but will-it-scale mmap stressors do not, suspect NUMA placement or
  huge-page policy change rather than lock contention.
