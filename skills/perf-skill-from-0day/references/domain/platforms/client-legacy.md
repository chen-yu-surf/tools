# Client-Only Legacy Platforms — kbl / cfl / cml / rpl / ptl

> Covers: Kaby Lake (`06-9e-*`), Coffee Lake (`06-9e-*`), Comet Lake
> (`06-a5-*`/`06-a6-*`), Raptor Lake (`06-b7-*`/`06-ba-*`), Panther Lake (`06-cc-02`).
> All single-socket desktop/laptop platforms in LKP (`lkp-*-d##`, `igk-*-d##`).
> **No server NUMA patterns apply** — no UPI/QPI, no SNC, no multi-socket topology.
> Use this file only for the mitigation/ISA profile; do not apply any
> scalability-cliff or NUMA regression pattern from other platform files.

---

## Platform Summary

| Code | Microarchitecture | Cores (typical LKP tbox) | AVX-512 | Notes |
|---|---|---|---|---|
| `kbl` | Kaby Lake | 4 | No | Retpoline + KPTI + Retbleed full stack |
| `cfl` | Coffee Lake | 4–8 | No | Same mitigation profile as kbl |
| `cml` | Comet Lake | 6–10 | No | Same mitigation profile as kbl/cfl |
| `rpl` | Raptor Lake | P-core + E-core hybrid | No (client) | eIBRS present; hybrid scheduling (`sched_ext`/ITMT) |
| `ptl` | Panther Lake | P-core + E-core hybrid | No (client) | eIBRS + hardware BHI_DIS; newest client mitigation baseline |

---

## Key Characteristics

- **Single-socket only**: no NUMA topology, no UPI/QPI interconnect, no SNC. Any
  regression pattern involving NUMA locality, cross-socket traffic, or SNC domains from
  other platform files does **not** apply here.
- **kbl/cfl/cml (pre-eIBRS)**: Retpoline, KPTI, and Retbleed mitigations are all active,
  same overhead profile as `skl` (see [skl.md](skl.md) mitigation sections) but without
  any AVX-512 frequency license (these cores don't support AVX-512).
- **rpl/ptl (hybrid P-core/E-core, eIBRS)**: use ia-common.md eIBRS entry; Retpoline
  overhead is negligible. Scheduling regressions on these platforms are more likely to
  involve P-core/E-core task placement (`sched_ext`, Intel Thread Director / ITMT) than
  classic NUMA locality — a different mechanism from server-platform regressions.
- **Low core count (4–24 cores)**: no scalability-cliff patterns are reachable on these
  platforms; do not use them as a scalability baseline.

---

## Platform-Specific Regression Patterns

### KPTI + Retpoline + Retbleed Stack (kbl/cfl/cml)

- Same mechanism as [skl.md](skl.md) — FBCs that add syscalls or interrupts show
  amplified regression from the combined mitigation overhead.
- Signal: `entry_SYSCALL_64` / `__x86_indirect_thunk_*` dominate cycles.
- Fix: reduce syscall rate; avoid indirect calls in hot paths.

### Hybrid P-core/E-core Scheduling Regression (rpl/ptl)

- FBCs that change scheduler task-placement logic can regress hybrid-core platforms
  differently from a homogeneous-core server platform: a task incorrectly pinned to an
  E-core when it should run on a P-core shows throughput regression with **no** cache-miss
  or lock-contention signal — the CPU itself is simply slower per cycle.
- Signal: regression present on rpl/ptl but absent on any single-core-type platform
  (skl, spr, gnr, srf); perf-profile shows normal-looking hot functions but with lower
  IPC than expected for that function on a P-core.
- Fix: verify `sched_ext` / Intel Thread Director hints are preserved; check for changes
  to `arch_asym_cpu_priority()` or ITMT-related scheduler code.
