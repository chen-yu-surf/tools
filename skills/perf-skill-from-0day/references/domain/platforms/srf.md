# Sierra Forest (srf) Platform Reference

> Covers: Intel Xeon 6 E-core (Sierra Forest), CPUID `06-af-03`.
> First production Intel Xeon 6 E-core platform in LKP. Key differences from
> P-core platforms: E-core cluster topology, no Hyper-Threading, RFDS mitigation.

---

## Cache and Topology

| Property | Value |
|---|---|
| Max cores/socket | 144 E-cores |
| L1-D | 64 KB per E-core |
| L2 (shared per cluster) | 4 MB per cluster of 4 E-cores |
| L3/LLC | Shared across all clusters on the socket |
| DDR | DDR5 |
| NUMA modes | SNC-2 (≥2 NUMA nodes) |
| Hyper-Threading | **No** |
| AVX-512 | Yes |
| AMX | No |
| RFDS mitigation | **Yes** |
| TDX host | No |

---

## Key Characteristics

- **E-core cluster topology**: 4 E-cores share one 4 MB L2 cluster. Unlike P-core
  platforms where each core has a private L2, false sharing at the cluster boundary
  has ~5-cycle intra-cluster RTT vs. ~20 cycles cross-cluster.
- **No Hyper-Threading**: logical CPU count equals physical core count. SMT amplification
  of lock contention is absent; scalability regressions scale purely with physical cores.
- **RFDS mitigation**: `VERW` on every kernel→user return. FBCs that increase syscall or
  interrupt frequency are amplified by a fixed per-return overhead at all 256+ CPUs.
- **Very high core count**: scales scalability regressions to the same severity as gnr 4S,
  but without multi-socket NUMA complexity.
- **Tile-based NUMA**: NUMA domains correspond to E-core tile groups, not memory
  controllers. Cross-tile latency is much lower than cross-socket P-core NUMA latency.
  A regression that appears NUMA-related may actually be cluster-level false sharing.

---

## Platform-Specific Regression Patterns

### E-core Cluster False Sharing

- FBCs that place a frequently-written field adjacent to a hot read-only field cause
  intra-cluster L2 thrashing even after standard cacheline alignment fixes.
- Signal: `[MEMORY-BOUND]` on srf but **not** on spr; `cache-misses` spike without TLB
  growth; regression scales with `nr_cpu`.
- Fix: verify struct layout with `pahole`; use `__cacheline_group_begin/end` to isolate
  independently-written field groups.

### RFDS Mitigation Amplification

- FBCs that add syscalls or increase kernel→user return rate are amplified by the fixed
  RFDS `VERW` cost. At 256+ CPUs even a small per-return overhead accumulates.
- Signal: regression present on srf but absent or smaller on spr (spr is not RFDS-affected).
- Fix: reduce syscall/interrupt rate in the hot path.

### High-CPU-Count Scalability (No-SMT)

- 256 physical cores without SMT: scalability regressions at this CPU count follow the
  same pattern as gnr, but lock hold time is not SMT-amplified.
- Signal: `native_queued_spin_lock_slowpath` hot; IPC higher than P-core under contention
  (no sibling spinning); regression super-linear with CPU count.
- Fix: per-CPU batching, lock-free RCU, per-node counters.

### Tile-Based NUMA False Positive

- Cross-tile latency on srf is far lower than P-core cross-NUMA latency. A NUMA locality
  fix that resolves a regression on spr may have no effect on srf.
- When cross-referencing spr vs. srf: confirm whether the spr fix relies on high cross-NUMA
  penalty; if so, test srf separately before declaring the fix universal.
