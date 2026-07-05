# Cooper Lake (cpl) Platform Reference

> Covers: Intel Xeon Scalable 3rd gen (Cooper Lake), CPUID `06-55-0b`.
> Same core/cache geometry as Skylake-SP/Cascade Lake but adds BFloat16 (BF16)
> support and is deployed almost exclusively in 4-socket LKP configurations
> (`lkp-cpl-4sp*`).

---

## Cache and Topology

| Property | Value |
|---|---|
| Max cores/socket | 28 |
| L1-D | 32 KB |
| L2 (private) | 1 MB |
| L3/LLC per core | 1.375 MB |
| DDR | DDR4-3200, 6 ch/socket |
| UPI links | 3 × 10.4 GT/s |
| NUMA modes | SNC-2 |
| Hyper-Threading | Yes |
| AVX-512 | Yes, **with BF16 extension** (VNNI + BF16 for AI/ML workloads) |
| AMX | No |
| TSX | **Removed** — CPL has no TSX support at all (disabled in silicon, not just microcode) |

---

## Differences from CSL

| Aspect | CSL | CPL |
|---|---|---|
| DDR speed | DDR4-2933 | DDR4-3200 |
| TSX | Disabled by microcode (still present in silicon) | Not present in silicon |
| AVX-512 BF16 | No | Yes |
| Typical socket count | 1–2 | **4** (dominant LKP deployment) |

All other characteristics (AVX-512 frequency license, KPTI, Retpoline, Retbleed,
SNC-2 NUMA mode) are identical to [csl.md](csl.md) and [skl.md](skl.md).

---

## Platform-Specific Regression Patterns

Patterns from [skl.md](skl.md) that still apply:

- **AVX-512 Frequency License** — same ~200–400 MHz downgrade profile.
- **KPTI + Retpoline + Retbleed Cost Stack** — same mitigation overhead.
- **SNC-2 Cross-Domain Allocation** — same as skl/csl.

**Does NOT apply**: TSX Lock Fallback — CPL has no TSX in silicon, so no lock-fallback
regression pattern is possible here. If lock contention is observed, it is a genuine
lock-contention regression, not a TSX artifact.

### 4-Socket UPI Bottleneck (CPL-defining pattern)

- `lkp-cpl-4sp2` is a 4-socket configuration; cross-socket UPI bandwidth is the primary
  constraint at this scale (3 UPI links per socket, shared across 3 remote sockets in a
  4S topology — less headroom per remote socket than in a 2S system).
- FBCs that increase remote-socket memory traffic show throughput regression that is
  disproportionately worse on cpl 4S than on skl/csl 2S for the same code change.
- Signal: perf-profile shows `__alloc_pages` hot stacks on remote-node allocation
  functions; regression scales with the number of remote sockets accessed.
- Fix: `alloc_pages_node(numa_node_id(), ...)` for placement-sensitive paths; minimise
  cross-socket data sharing; consider per-socket data replication for read-mostly
  structures accessed by all 4 sockets.
