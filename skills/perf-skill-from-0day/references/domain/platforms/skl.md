# Skylake-SP (skl) Platform Reference

> Covers: Intel Xeon Scalable 1st gen (Purley platform), CPUID `06-55-*` (SP variant).
> First Xeon Scalable generation: first AVX-512, first UPI, first Sub-NUMA Clustering.
> Also the first generation subject to the AVX-512 frequency license.

---

## Cache and Topology

| Property | Value |
|---|---|
| Max cores/socket | 28 |
| L1-D | 32 KB |
| L2 (private) | 1 MB |
| L3/LLC per core | 1.375 MB |
| DDR | DDR4-2666, 6 ch/socket |
| UPI links | 3 × 10.4 GT/s |
| NUMA modes | SNC-2, Quadrant |
| Hyper-Threading | Yes |
| AVX-512 | Yes (**with** frequency license — first generation) |
| AMX | No |
| TSX | Yes, but disabled by TAA microcode mitigation |

---

## Key Characteristics

- **First AVX-512 generation**: introduces the AVX-512 frequency license — using AVX-512
  instructions (especially heavy ones like FMA) triggers a ~200–400 MHz core frequency
  downgrade ("license 2") that persists for a period after the last AVX-512 instruction.
- **Pre-eIBRS**: Retpoline is the Spectre v2 mitigation. `__x86_indirect_thunk_*` hot in
  workloads with significant indirect calls.
- **KPTI active**: CR3 switch on every syscall entry/exit.
- **Retbleed mitigation**: `IBPB` on function-return path; heavy overhead on
  syscall/interrupt-dominated benchmarks.
- **TSX/TAA**: TSX disabled by microcode update; `HLE`/`RTM` code falls back to a
  spinlock path.
- **First UPI + SNC**: 3 UPI links replace QPI; SNC-2 introduced as a BIOS NUMA option
  alongside Quadrant mode.
- **Low CPU count (28 cores/56 threads per socket)**: scalability regressions largely
  invisible here; use as a baseline to confirm a regression is CPU-count-dependent when
  comparing against spr/gnr.

---

## Platform-Specific Regression Patterns

### AVX-512 Frequency License (skl-defining pattern)

- Signal: throughput regression present on skl (and csl) but absent or much smaller on
  icl/spr for the same AVX-512-heavy FBC; no cache-miss or lock-contention growth;
  regression delta matches the frequency downgrade (~10–15% throughput impact).
- Fix: avoid calling AVX-512 routines in latency-critical paths on skl/csl; or accept as
  expected platform-specific behaviour since the penalty disappears on icl+ (Golden Cove).

### KPTI + Retpoline + Retbleed Cost Stack

- FBCs that add syscalls or interrupts show amplified regression from the combined
  mitigation overhead.
- Signal: `entry_SYSCALL_64` / `__x86_indirect_thunk_*` dominate cycles; regression
  disproportionately larger than on icl/spr for the same FBC.
- Fix: reduce syscall rate; avoid indirect calls in hot paths.

### TSX Lock Fallback

- Code using `HLE`/`RTM` now serialises through a spinlock after the microcode TSX disable.
- Signal: `native_queued_spin_lock_slowpath` hot; `[LOCK-CONTENTION]`; no TSX functions
  visible.
- Fix: identify which lock operations were transactional; consider finer-grained locking.

### SNC-2 Cross-Domain Allocation (first-generation SNC)

- When SNC-2 is active, allocations ignoring `numa_node_id()` placement alternate across
  the two SNC domains on the socket.
- Signal: `[MEMORY-BOUND]`; `alloc_pages` hot stacks; regression worse on SNC tboxes than
  on Quadrant-mode tboxes with the same CPU count.
- Fix: `alloc_pages_node(numa_node_id(), ...)` for placement-sensitive allocations.
