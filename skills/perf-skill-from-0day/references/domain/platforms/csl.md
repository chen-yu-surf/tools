# Cascade Lake (csl) Platform Reference

> Covers: Intel Xeon Scalable 2nd gen, CPUID `06-55-07`.
> Same core/cache geometry as Skylake-SP with higher DDR4 speed and hardware
> mitigations for some Meltdown/MDS variants baked into silicon.

---

## Cache and Topology

| Property | Value |
|---|---|
| Max cores/socket | 28 |
| L1-D | 32 KB |
| L2 (private) | 1 MB |
| L3/LLC per core | 1.375 MB |
| DDR | DDR4-2933, 6 ch/socket |
| UPI links | 3 × 10.4 GT/s |
| NUMA modes | SNC-2, Quadrant |
| Hyper-Threading | Yes |
| AVX-512 | Yes (**with** frequency license, same as skl) |
| AMX | No |
| TSX | Yes, but disabled by TAA microcode mitigation |

---

## Differences from SKL

| Aspect | SKL | CSL |
|---|---|---|
| DDR speed | DDR4-2666 | DDR4-2933 |
| MDS mitigation | Software (VERW added by kernel) | Partially hardware-mitigated in silicon |
| L1TF | Software mitigation required | Hardware-mitigated (RDCL_NO in some CSL SKUs) |

All other characteristics (AVX-512 frequency license, KPTI, Retpoline, Retbleed, TSX/TAA,
SNC-2/Quadrant NUMA modes) are identical to [skl.md](skl.md).

---

## Platform-Specific Regression Patterns

All patterns from [skl.md](skl.md) apply identically to CSL:

- **AVX-512 Frequency License** — same ~200–400 MHz downgrade; a regression present on
  csl but absent on icl/spr for AVX-512-heavy code is a frequency license artifact.
- **KPTI + Retpoline + Retbleed Cost Stack** — same mitigation overhead profile as skl.
- **TSX Lock Fallback** — same as skl; TSX disabled by TAA microcode.
- **SNC-2 Cross-Domain Allocation** — same as skl.

**CSL-specific note**: since MDS and L1TF are partially hardware-mitigated on many CSL
SKUs, a regression that shows extra `VERW`-related overhead on skl but not on csl for the
same FBC is expected and not a kernel bug — check the specific CSL SKU's `RDCL_NO`/`MDS_NO`
CPUID bits before concluding a discrepancy is unexplained.
