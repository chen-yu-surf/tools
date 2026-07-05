# Ice Lake-SP (icl) Platform Reference

> Covers: Intel Xeon 3rd gen Scalable (Ice Lake-SP / ICX), CPUID `06-6a-06`.
> Transitional generation: first eIBRS platform, first 48-KB L1D, first DDR4-3200 8-channel.

---

## Cache and Topology

| Property | Value |
|---|---|
| Max cores/socket | 40 |
| L1-D | 48 KB |
| L2 (private) | 1.25 MB |
| L3/LLC per core | 1.5 MB |
| DDR | DDR4-3200, 8 channels/socket |
| UPI links | 3 × 11.2 GT/s |
| NUMA modes | SNC-2, Hemisphere, Quadrant (default) |
| Hyper-Threading | Yes (80 logical CPUs on 40-core SKU per socket) |
| AVX-512 | Yes (no frequency license — no downgrade on icl) |
| AMX | No |
| TDX | No |

Read the actual host file for `nr_node` to determine the active NUMA mode (Quadrant = 1 node/socket; SNC-2 = 2 nodes/socket).

---

## Key Characteristics

- **First eIBRS platform**: Retpoline is replaced by hardware IBRS for kernel→kernel
  indirect calls. `__x86_indirect_thunk_*` hot stacks absent unless microcode is old.
  `IBPB` on context switch still costs ~2–4 µs.
- **BHI overhead**: ICL lacks hardware `BHI_DIS_S`, so the kernel applies BHB-clearing
  sequences on syscall entry. FBCs that increase syscall rate will show slightly more
  overhead on icl than on spr+.
- **No AVX-512 frequency license**: Unlike skl/csl, AVX-512 does not cause a frequency
  downgrade on icl. A regression present on skl/csl but absent on icl for an AVX-512
  workload confirms a frequency-license artifact on the older platforms.
- **Moderate CPU count (64–80 CPUs)**: scalability regressions may be latent here and
  explode on spr/emr (224+ CPUs). Use icl results as a lower-bound reference when
  comparing against spr.

---

## Platform-Specific Regression Patterns

### BHI Mitigation Overhead Amplification

- FBCs that increase syscall rate regress slightly more on icl than on spr+ because icl
  uses software BHB-clearing on entry (spr+ uses hardware `BHI_DIS_S`).
- Signal: `entry_SYSCALL_64` cycle delta is larger on icl than on spr for the same FBC.
- Fix: reduce syscall rate in the hot path; BHI overhead is fixed per syscall on icl.

### SNC-2 Cross-Domain Allocation

- When SNC-2 is active (`nr_node = 4` on 2S tbox), allocations that ignore `numa_node_id()`
  placement will alternate between the two SNC domains, adding ~50% memory latency for
  remote-domain accesses.
- Signal: `[MEMORY-BOUND]`; `alloc_pages` hot stacks; regression worse on SNC tboxes than
  on Quadrant-mode tboxes with the same CPU count.
- Fix: `alloc_pages_node(numa_node_id(), ...)` for placement-sensitive allocations.

### Scalability Cliff Preview

- icl (64 CPUs) is the last generation where per-socket CPU count is low enough that
  global-atomic and coarse-lock regressions may not surface. If a FBC regresses on spr
  but not on icl, compare icl (64 CPUs) vs. spr (224 CPUs) to confirm the scalability cliff.
