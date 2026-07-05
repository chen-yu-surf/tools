# Emerald Rapids (emr) Platform Reference

> Covers: Intel Xeon 5th gen Scalable (Emerald Rapids), CPUID `06-cf-02`.
> EMR is a die-shrink/SKU refresh of Sapphire Rapids: identical cache geometry,
> same ISA feature set, higher max core count, no GDS, SNC-4 is the default
> BIOS mode on LKP tboxes.

---

## Cache and Topology

| Property | Value |
|---|---|
| Max cores/socket | 64 |
| L1-D | 48 KB |
| L2 (private) | 2 MB |
| L3/LLC per core | 1.875 MB |
| DDR | DDR5-4800, 8 ch/socket |
| UPI links | 4 × 16 GT/s |
| NUMA modes | SNC-4 (default on LKP tboxes), SNC-2 |
| Hyper-Threading | Yes |
| AVX-512 | Yes (no frequency license) |
| AMX | Yes (TMUL: INT8, BF16) |
| TDX | Yes |
| GDS mitigation | **No** (GDS affects SPR D0 only) |
| Memory controllers | 4 per socket |

---

## Differences from SPR

| Aspect | SPR | EMR |
|---|---|---|
| Max cores/socket | 60 | 64 |
| GDS mitigation overhead | D0 stepping only | Not present |
| Default BIOS NUMA mode | Quadrant | SNC-4 |
| LKP tbox default `nr_node` | 2 (Quadrant) | 4 (SNC-2 from 2-socket + SNC-2) |

**SNC note**: EMR tboxes in LKP commonly show `nr_node: 4` on a 2-socket system because
SNC-2 is the default BIOS mode, producing 2 NUMA sub-nodes per socket. Cross-SNC-domain
allocations incur ~1.5× latency penalty. Read the actual host file to confirm.

---

## Key Characteristics and Regression Patterns

All patterns from [spr.md](spr.md) apply to EMR identically, **except**:

- **No GDS mitigation**: the D0-stepping GDS regression pattern does not apply.
- **SNC-4 default amplifies NUMA locality regressions**: FBCs that ignore `numa_node_id()`
  placement will round-robin across 4 SNC domains on a 2-socket EMR, causing 1.5–2×
  latency for half of accesses. The effect is more pronounced than on SPR (which defaults
  to Quadrant, a single NUMA node per socket).
- **NUMA-node-count explosion**: `nr_node = 4` on 2S EMR means per-NUMA-node data
  structures consume 2× more memory than on SPR. Watch for OOM or slab cache thrashing
  on FBCs that add new per-node allocations.

All other patterns (scalability cliff, TLB shootdown, AMX XSTATE, HWP MSR storm, DSA,
TDX, CXL misplacement) are identical — see [spr.md](spr.md).
