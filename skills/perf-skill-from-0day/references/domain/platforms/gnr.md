# Granite Rapids (gnr) Platform Reference

> Covers: Intel Xeon 6 P-core (Granite Rapids), CPUID `06-ad-01`.
> Highest per-socket core count in LKP (up to 128 cores / 256 logical CPUs per socket).
> Doubled L3 per core vs. SPR/EMR; DDR5-6400; 4×24 GT/s UPI.

---

## Cache and Topology

| Property | Value |
|---|---|
| Max cores/socket | 128 |
| L1-D | 48 KB |
| L2 (private) | 2 MB |
| L3/LLC per core | 3 MB (2× SPR) |
| DDR | DDR5-6400, 8 ch/socket |
| UPI links | 4 × 24 GT/s (50% more BW than SPR) |
| NUMA modes | SNC-4 |
| Hyper-Threading | Yes (256 logical CPUs per socket at 128-core config) |
| AVX-512 | Yes (no frequency license) |
| AMX | Yes (2nd gen: additional FP16 support) |
| TDX | Yes |

SNC-4 is the active mode on GNR tboxes. Read the actual host file for `nr_node` to determine exact NUMA node count (2 for 2S, 4 for 4S).

---

## Key Characteristics

- **Ultra-high CPU count**: 256–512 logical CPUs expose scalability regressions that are
  invisible on spr (224 CPUs) and icl (64 CPUs). The same FBC may show:
  - No regression on icl
  - Marginal regression on spr
  - Severe regression on gnr
  This pattern always indicates a scalability root cause (lock, atomic, or serialisation).
- **Doubled L3 per core (3 MB)**: larger LLC means the working set of medium-size workloads
  now fits in L3 on gnr but not on spr. Regressions that appear MEMORY-BOUND on spr may be
  obscured on gnr because data is served from L3 instead of DRAM.
- **DDR5-6400 and wider UPI**: raw memory and cross-socket bandwidth is higher than on spr.
  Bandwidth-limited regressions are proportionally less severe here; latency-limited
  regressions (e.g. NUMA round-trip, lock contention) are unchanged.
- **AMX 2nd gen (FP16 tile)**: FP16 AMX instructions available in addition to INT8/BF16.
  XSTATE overhead is the same as SPR (~8 KB AMX tile context).
- **eIBRS + hardware BHI_DIS**: same as spr/emr; Retpoline and BHI overhead negligible.

---

## Platform-Specific Regression Patterns

### Extreme Scalability Cliff (256–512 CPUs)

- Any FBC with a global lock, per-mm/per-sb serialisation, or high-frequency shared atomic
  will show super-linear regression at gnr CPU counts.
- Detection: regression absent on icl/spr but severe on gnr → scalability cliff; compare
  `nr_cpu` vs. regression magnitude across tboxes.
- Fix: per-CPU batching, lock-free RCU, per-node counters, lock order narrowing.

### TLB Shootdown IPI Storm (Worst Case)

- With 512 CPUs (4-socket gnr), `flush_tlb_mm()` issues IPIs to all 512 logical CPUs.
  Serialisation time scales linearly with CPU count.
- Signal: same as spr (see spr-emr.md) but regression magnitude is ~2–3× larger.
- Fix: same TLB batching strategies; check for unnecessary `flush_tlb_mm()` vs.
  `flush_tlb_page()` in the modified code path.

### NUMA UPI Bottleneck (4-Socket gnr)

- `lkp-gnr-4sp2` (512 CPUs, 4 NUMA nodes) exposes cross-socket UPI bandwidth limits.
- FBCs that increase remote-socket memory traffic show rising
  `uncore_upi.UNC_UPI_TxL_FLITS`; perf-profile hot on `__alloc_pages` with remote-node
  allocation functions; `uncore_cha.UNC_CHA_XSNP_RESP` increases.
- Fix: `alloc_pages_node(numa_node_id(), ...)` for placement-sensitive paths;
  per-node data structures to avoid cross-socket coherency traffic.

### L3 Working-Set Masking

- gnr's 3 MB L3 per core (vs. 1.875 MB on spr) can absorb working sets that miss L3 on spr.
- A regression that appears `[MEMORY-BOUND]` on spr but not on gnr: the struct or buffer in
  question fits in gnr's larger L3. This is an improvement on gnr, not a fix; the regression
  on spr is still real and should be addressed.

### AMX XSTATE Context-Switch Overhead

- Same mechanism as spr/emr (see spr-emr.md). AMX FP16 support adds no new XSTATE overhead.
- Scheduler-heavy benchmarks (hackbench, schbench) remain sensitive when AMX-using tasks
  are scheduled alongside non-AMX tasks.
