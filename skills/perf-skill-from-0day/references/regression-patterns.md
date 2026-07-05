# Regression Patterns and Fix Strategies

> Loaded on demand at Phase 4 Step 4. Do not reproduce verbatim in output.

## Regression Patterns

Check each in order. The pre-classified tag from Phase 3a step 5 narrows candidates.

| Pattern | Signal (and tag) | How to confirm via LSP/diff |
|---|---|---|
| **Data structure layout change** | Hot stacks on functions using the struct; other stacks may decrease (workload shift); `[MEMORY-BOUND]` | Check if hot callers dereference the changed field; cacheline alignment and struct size matter |
| **Lock contention increase** (`spinlock`, `rwsem`, `mutex`) | `native_queued_spin_lock_slowpath` in positive-delta chains; `[LOCK-CONTENTION]` | Which lock protects the modified data; did FBC extend the critical section or add new acquisitions? |
| **TLB shootdown overhead** | `flush_tlb_others` / `smp_call_function_many` in positive-delta chains; `[TLB-BOUND]` | FBC widened flush scope (`flush_tlb_page` → `range` or `mm`), or added new `flush_tlb_*` calls; check `arch/x86/mm/tlb.c`, `mm/mmap.c`, `mm/memory.c` |
| **Allocation / page-fault path overhead** | Cycles up in page-fault or alloc chain; `[MEMORY-BOUND]` if new work accesses new structs | New work in alloc fast-path (zeroing, rmap updates, folio lruvec locking) |
| **NUMA locality change** | `[MEMORY-BOUND]`; `__alloc_pages` / NUMA-selection stacks with large delta; worse on multi-socket tboxes | FBC changed per-CPU or per-node allocation policy or placement; compare 1-socket vs. 2-socket result roots if both exist |
| **False sharing** | `[MEMORY-BOUND]` **without** lock contention in perf-profile; cycles spike on a function that holds no lock | FBC added a field adjacent to an existing hot field; `pahole` to verify both fields share a 64-byte cacheline |
| **Cross-subsystem indirect regression** | Hot stacks entirely in subsystem B; FBC diff only touches subsystem A; cross-subsystem mismatch confirmed | Trace A→B dependency (CPU share, memory pressure, IRQ budget, lock order); fix belongs in B or at A→B interface |
| **Exposing commit** | Positive-delta cycles in subsystem FBC did **not** modify | FBC diff touches only `tools/perf/` or `tools/testing/`; kernel path was already suboptimal |
| **Per-CPU counter / atomic overhead** | Hot path shows `this_cpu_add` / `percpu_counter_add`; `[MEMORY-BOUND]` when many CPUs write; not `[LOCK-CONTENTION]` (no lock, but cache-line ping-pong) | FBC added a `percpu_counter_inc()`, `this_cpu_inc()`, or `atomic_inc()` call on a shared counter in a high-frequency path; per-CPU copies cause false sharing under NUMA cross-socket coherency traffic |
| **Seqcount / seqlock writer contention** | Readers loop retrying `read_seqcount_retry()`; positive delta on reader function (not the writer); `[LOCK-CONTENTION]` flavour without `native_queued_spin_lock_slowpath` | FBC added a write to a `seqcount_t`-protected field in a read-dominated hot path, forcing readers to spin and retry |

## Fix Approach by Pattern

| Pattern | Strategy |
|---|---|
| Data structure layout change | Reorder fields for cacheline locality; `____cacheline_aligned_in_smp` for hot shared fields; reduce struct size to avoid cacheline spill |
| Lock contention increase | Narrow the critical section; convert to RCU for read-dominated paths; per-CPU counters to avoid shared-state atomic writes |
| TLB shootdown overhead | `flush_tlb_page()` for single-page invalidations; batch with `arch_tlbbatch_add_mm()` + `arch_tlbbatch_flush()`; avoid flushes for private anonymous mappings no other CPU has mapped |
| Allocation / page-fault overhead | Lazy init (defer until first use); batch; per-CPU caches instead of per-alloc atomic accounting |
| NUMA locality change | `alloc_pages_node(numa_node_id(), ...)` or per-node variables; `____cacheline_aligned_in_smp` on shared structs to prevent cross-node false sharing |
| False sharing | `____cacheline_aligned_in_smp` between independently-written field groups, or `__cacheline_group_begin/end`; verify with `pahole` |
| Cross-subsystem indirect regression | Fix in subsystem B or at A→B interface; tighten IRQ affinity; per-CPU batching; or update test expectation baseline if trade-off is intentional |
| Exposing commit | Fix the pre-existing slow kernel path — the FBC exposed it, not caused it; do NOT patch or revert the exposing commit itself |
| Per-CPU counter / atomic overhead | If truly per-CPU (`this_cpu_inc`): check for false sharing between hot read-fields and the counter field (use `____cacheline_aligned_in_smp` or `__cacheline_group_begin/end`); if shared atomic (`atomic_inc`): convert to per-CPU with a periodic aggregate read; avoid placing the counter in the same cacheline as frequently-read data |
| Seqcount / seqlock writer contention | Move the seqcount write off the hot-reader path (lazy update, deferred write via worker); convert to RCU for read-dominated data; or use a dedicated seqcount per-object instead of a global one to reduce reader retry rate |
