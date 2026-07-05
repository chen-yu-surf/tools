# Clearwater Forest (cwf) Platform Reference

> Covers: Intel Xeon 6 E-core next-gen (Clearwater Forest), CPUID `06-dd-01`.
> Next generation of Sierra Forest. Key additions: higher core count, more NUMA nodes,
> TDX host mode enabled by default on LKP tboxes.

---

## Cache and Topology

| Property | Value |
|---|---|
| Max cores/socket | ≥288 E-cores |
| L1-D | 64 KB per E-core |
| L2 (shared per cluster) | per E-core cluster |
| L3/LLC | Shared across all clusters on the socket |
| DDR | DDR5 |
| NUMA modes | ≥4 NUMA nodes (tile-based) |
| Hyper-Threading | **No** |
| AVX-512 | Yes |
| AMX | No |
| RFDS mitigation | **Yes** |
| TDX host | **Yes** (`kvm_intel.tdx=on tdx_host=on` in kernel cmdline) |

---

## Differences from SRF

| Aspect | SRF | CWF |
|---|---|---|
| Max cores/socket | 144 | ≥288 |
| NUMA node count | ≥2 (SNC-2) | ≥4 (tile-based) |
| TDX host mode | No | Yes (always enabled on LKP tboxes) |

---

## Key Characteristics and Regression Patterns

All patterns from [srf.md](srf.md) apply to CWF identically (E-core cluster false sharing,
RFDS amplification, no-SMT scalability, tile-based NUMA false positive), with the following
additions:

- **Higher core count (≥576 CPUs on LKP tboxes)**: scalability regressions are more
  extreme than on srf. Any global lock or shared atomic that escapes detection on srf (256
  CPUs) will be severe on cwf (576 CPUs).
- **More NUMA nodes (≥4)**: per-NUMA-node data structures consume proportionally more
  memory. FBCs that add new per-node allocations risk OOM on cwf before srf.
- **TDX host always active**: VM-exit overhead baseline is higher than non-TDX platforms.
  FBCs touching SEPT page tables (`arch/x86/virt/vmx/tdx/`) or SEAMCALL dispatch paths
  regress guest workloads.
  - Signal: guest benchmarks (`kvm-unit-tests`, `pts/iozone`) regress; host perf-profile
    shows `tdx_*` or `seamcall` functions hot.
