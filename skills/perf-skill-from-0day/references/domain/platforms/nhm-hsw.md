# Nehalem / Ivy Bridge / Haswell (nhm / ivb / hsw / wsx) Platform Reference

> Covers: Nehalem/Westmere (`06-1a-*`/`06-2c-*`), Ivy Bridge-EP (`06-3e-*`),
> Haswell-EP (`06-3c-*`/`06-3f-*`). Pre-AVX-512, pre-UPI (QPI era), largely
> retired from active LKP testing but still present for long-tail regression
> bisects on very old baselines.

---

## Cache and Topology

| Platform | Cores/socket (max) | L1-D | L2 (private) | L3/LLC per core | DDR | Interconnect | NUMA modes |
|---|---|---|---|---|---|---|---|
| Nehalem / Westmere (nhm) | 8 | 32 KB | 256 KB | 2–3 MB shared | DDR3 | QPI 2×6.4 GT/s | UMA |
| Ivy Bridge-EP (ivb) | 12 | 32 KB | 256 KB | 2.5 MB | DDR3-1600 | QPI 2×8.0 GT/s | UMA / Hemisphere |
| Haswell-EP (hsw) | 18 | 32 KB | 256 KB | 2.5 MB | DDR4-2133 | QPI 2×9.6 GT/s | UMA / Hemisphere |

`wsx` (Whitley platform codename) refers to the platform generation spanning Cascade Lake
and Ice Lake-SP boards; treat as csl or icl depending on the actual CPUID reported.

---

## Key Characteristics

- **No AVX-512**: these cores predate AVX-512 entirely; no frequency-license regressions
  are possible on this generation.
- **Pre-eIBRS**: Retpoline is the only Spectre v2 mitigation; `__x86_indirect_thunk_*` is
  hot in any workload with significant indirect calls.
- **KPTI active**: CR3 switch on every syscall entry/exit (no PCID support on nhm/ivb;
  PCID present but KPTI still costly on hsw). FBCs that add syscalls amplify regression
  proportionally to syscall rate.
- **Retbleed mitigation**: `IBPB` on function-return path adds ~20% overhead to
  interrupt/syscall-heavy benchmarks — the largest mitigation overhead of any generation.
- **No TSX on nhm/ivb**: TSX was introduced with Haswell; `hsw` is TAA-affected (TSX
  disabled by microcode), `nhm`/`ivb` were never TSX-capable.
- **Very low CPU count (≤18 cores/socket)**: scalability regressions that are invisible
  here will explode on spr/gnr. Rarely useful as a scalability baseline given the gap.

---

## Platform-Specific Regression Patterns

### KPTI + Retpoline + Retbleed Cost Stack

- These three mitigations stack on nhm/ivb/hsw, producing the largest per-syscall overhead
  of any IA generation in LKP. FBCs that add new syscalls or increase interrupt frequency
  show a regression multiplied by all three costs simultaneously.
- Signal: `entry_SYSCALL_64` dominates cycles; regression disproportionately large here
  vs. icl/spr for the same FBC.
- Fix: reduce syscall rate; avoid indirect calls in hot paths; no change to mitigation code
  itself — this is expected baseline overhead for the generation.

### TSX Lock Fallback (hsw only, within this file)

- Code using `HLE`/`RTM` transactional memory serialises through a spinlock after the
  microcode TSX disable.
- Signal: `native_queued_spin_lock_slowpath` hot; `[LOCK-CONTENTION]`; no TSX functions
  visible in the profile.
- Fix: identify which lock operations were transactional; consider per-CPU counters or
  finer-grained locks for the serialised sections.
