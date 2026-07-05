# IA Common — Cross-Platform Knowledge

> Loaded for every IA platform alongside the specific platform file.
> Routing is handled by domain-reference.md — do not load this file directly.
> Covers: x86 hot-path functions, Intel PMU events, NUMA topology modes,
> security mitigations, and HT/SMT behaviour.
> Do not reproduce these tables verbatim in output.

---

## x86-Specific Hot-Path Functions

These functions appear frequently in LKP perf-profiles on IA platforms. Use them as
starting hypotheses when the diff touches the corresponding kernel paths.

| Function | Subsystem | Regression type | Common cause |
|---|---|---|---|
| `native_queued_spin_lock_slowpath` | Locking | `[LOCK-CONTENTION]` | Spinlock contention under SMT; IPC stays HIGH (spinners burn cycles) |
| `retpoline` / `__x86_indirect_thunk_*` | Spectre v2 mitigation | general | eIBRS absent (pre-ICL); see Mitigations table |
| `__switch_to` / `__schedule` | Context switch | general | FBC increases context-switch rate |
| `native_write_msr` / `wrmsr` | MSR write | general | IBPB/IBRS toggle, HWP_REQUEST writes, power management |
| `flush_tlb_others` / `smp_call_function_many` | TLB shootdown | `[TLB-BOUND]` | IPI flood on large-socket systems (224+ CPUs) |
| `x86_pmu_disable` / `intel_pmu_*` | PMU | general | PMU interrupt overhead on heavily contended workloads |
| `mwait_idle` / `intel_idle` | CPU idle | improvement or regression | Deeper C-states: lower latency when idle, but re-entry cost regresses burst workloads |
| `intel_pstate_*` / `cpufreq_*` | P-state / freq scaling | general | HWP/EPP changes; `native_write_msr` spike if freq requested per-task |
| `apic_timer_interrupt` | Timer | general | High apic timer rate; FBC that reduces `nohz` efficiency |
| `do_syscall_64` | Syscall entry | general | KPTI CR3 switch cost on older platforms (pre-CSL without PCID) |
| `entry_SYSCALL_64` / `__do_sys_*` | Syscall overhead | general | eIBRS / Retpoline transition cost per syscall on affected platforms |
| `__intel_pmu_pebs_event_*` | PEBS | general | PEBS buffer drain overhead; increases with high PEBS event rate |
| `arch_irq_work_raise` / `perf_ibs_*` | NMI / perf | general | NMI-based profiling overhead; can inflate cycle counts in profiled binaries |

---

## Intel PMU Events

LKP `perf-stat.*` metrics map directly to Intel PMU event names.

### Core PMU (Intel Architectural + Model-Specific)

| perf-stat key | Intel event | Tag | Interpretation |
|---|---|---|---|
| `perf-stat.cache-misses` | `LONGEST_LAT_CACHE.MISS` | `[MEMORY-BOUND]` | LLC miss → DRAM access |
| `perf-stat.ipc` (derived) | `INST_RETIRED.ANY` / `CPU_CLK_UNHALTED.THREAD` | `[MEMORY-BOUND]` if < 1.0 | IPC < 1.0 = memory stalls; IPC > 3.0 = compute-bound |
| `perf-stat.dTLB-load-misses` | `DTLB_LOAD_MISSES.MISS_CAUSES_A_WALK` | `[TLB-BOUND]` | L1-DTLB miss + page walk; spike = TLB shootdown or working-set growth |
| `perf-stat.iTLB-load-misses` | `ITLB_MISSES.MISS_CAUSES_A_WALK` | `[TLB-BOUND]` | I-TLB miss; relevant for code-size or huge-iTLB regressions |
| `perf-stat.branch-misses` | `BR_MISP_RETIRED.ALL_BRANCHES` | general | Branch misprediction; relevant for BHI mitigation overhead |
| `perf-stat.stalled-cycles-frontend` | `IDQ_UOPS_NOT_DELIVERED.CORE` | frontend-bound | i-cache/i-TLB/branch-misprediction stalls |
| `perf-stat.stalled-cycles-backend` | `CYCLE_ACTIVITY.STALLS_TOTAL` | `[MEMORY-BOUND]` | Memory/execution stalls |
| `perf-stat.cpu-migrations` | `cpu-migrations` (SW event) | general | Task migrating across CPUs; NUMA locality loss |

### Model-Specific Events (ICL / SPR / EMR / GNR)

Appear as raw PMU events in `perf-stat` output on ICL+ tboxes:

| Event | Meaning | Regression hint |
|---|---|---|
| `MEM_LOAD_RETIRED.L3_MISS` | Per-thread DRAM access rate | Core `[MEMORY-BOUND]` confirmation |
| `CYCLE_ACTIVITY.STALLS_MEM_ANY` | Cycles stalled on any memory level | Confirms memory bottleneck |
| `CYCLE_ACTIVITY.STALLS_L1D_MISS` | Cycles stalled on L1D miss | Near-memory hotspot (slab/struct layout) |
| `MEM_INST_RETIRED.ALL_LOADS` | Total load instructions retired | Compute MPKI = `L3_MISS` / `ALL_LOADS` × 1000 |
| `OFFCORE_REQUESTS.ALL_REQUESTS` | All off-core requests (L3 miss + DDIO) | Network / I/O buffer memory pressure |
| `INT_MISC.CLEAR_RESTEER_CYCLES` | Machine clears (self-modifying code, FP assist) | JIT/BPF paths; `__bpf_prog_run` hot |
| `UOPS_DISPATCHED.THREAD` | µop dispatch rate per thread | Execution efficiency; drops under memory stalls |

### Uncore / IMC Events (SPR / EMR / GNR)

Appear as `uncore_imc_*` when uncore PMU is enabled:

| Event | Meaning | Regression hint |
|---|---|---|
| `uncore_imc.UNC_M_CAS_COUNT.RD` | DRAM read bandwidth per IMC | Cross with `cache-misses` to calibrate MPKI at system level |
| `uncore_imc.UNC_M_CAS_COUNT.WR` | DRAM write bandwidth | Write-heavy alloc / zeroing paths |
| `uncore_cha.UNC_CHA_LLC_LOOKUP.ANY` | LLC lookup count | LLC efficiency: `cache-misses` / LLC_LOOKUP |
| `uncore_cha.UNC_CHA_XSNP_RESP.*` | Cross-socket snoop responses | Remote-socket traffic; NUMA locality regression |
| `uncore_upi.UNC_UPI_TxL_FLITS.*` | UPI transmit flits | Cross-socket data movement; bottleneck on 4S systems |

---

## NUMA Topology Modes

The active mode is inferred from the host file: if `nr_node > socket_count`, SNC is active.
Read the actual host file — do not guess topology from the tbox name alone.

| Mode | `nr_node / socket` | Description | Performance characteristic |
|---|---|---|---|
| **UMA** (flat) | 1 | Single contiguous address space; all LLC and MCs equidistant | Simple; good for small socket count; no NUMA tuning needed |
| **Hemisphere** | 2 (ICL) | Socket split into 2 halves; local LLC slices + MC per half | ~5–10% lower latency vs UMA; no OS topology change |
| **Quadrant** | 1 (ICL/SPR default without SNC) | 4 quadrants; local MC routing; still one NUMA node per socket | ~10% lower latency; transparent to kernel NUMA policy |
| **SNC-2** | 2 per socket | 2 NUMA sub-nodes per socket; OS NUMA-aware | ~15–20% lower local latency; remote-node penalty ~50% more |
| **SNC-4** | 4 per socket (SPR/EMR/GNR) | 4 NUMA sub-nodes per socket | Best for NUMA-aware code; remote penalty up to 2× |

**Cross-SNC regression patterns (applicable to any SNC-enabled tbox):**

- **Round-robin allocation across SNC domains**: `alloc_pages()` without
  `alloc_pages_node(numa_node_id(), ...)` distributes pages across all SNC domains,
  doubling memory latency for half of accesses. FBCs that remove explicit `nid` placement
  or switch to system-wide freelists regress heavily on SNC tboxes.
- **NUMA-node-count explosion**: A 2-socket EMR with SNC-2 has `nr_node = 4`. Per-NUMA-node
  data structures (e.g. per-node slab caches, `DEFINE_PER_CPU_NUMA_FLAGS`) consume 2× more
  memory than on non-SNC tboxes — can cause OOM or slab cache thrashing.
- **UPI bottleneck (4-socket systems)**: FBCs that increase remote-socket memory traffic on
  4S tboxes (`lkp-cpl-4sp2`, `lkp-gnr-4sp2`) appear as rising
  `uncore_upi.UNC_UPI_TxL_FLITS`; perf-profile shows `__alloc_pages` hot stacks on
  remote-node allocation functions.

---

## Security Mitigations

These are enabled by default. Each adds overhead to specific hot paths. When a FBC touches
a code path listed here, check whether the mitigation amplifies the regression.

| Mitigation | Affected platforms | Kernel mechanism | Hot-path overhead |
|---|---|---|---|
| **KPTI (Meltdown)** | nhm, ivb, hsw, skl, kbl, cfl (pre-CSL) | CR3 switch on every kernel entry/exit | `do_syscall_64` / `entry_SYSCALL_64` spikes; ~5–30% syscall-heavy penalty |
| **Retpoline (Spectre v2)** | nhm–csl (pre-eIBRS) | Indirect calls replaced with retpoline trampolines | `__x86_indirect_thunk_*` hot stacks; ~5–15% compute overhead |
| **eIBRS (Enhanced IBRS)** | icl, spr, emr, gnr, srf, cwf, rpl, ptl | IBRS enforced by hardware; no retpoline for kernel→kernel | Negligible vs retpoline; `IBPB` on context switch still ~2–4 µs |
| **STIBP** | All SMT (HT-enabled) platforms | Blocks cross-thread branch prediction between siblings | Per-context-switch overhead; significant at high task-switch rates |
| **MDS (VERW / MD_CLEAR)** | nhm–skl (MDS-affected) | `VERW` on kernel→userspace returns | 1–5% on modern CPUs; higher on nhm/ivb/hsw/skl |
| **Retbleed** | nhm, ivb, hsw, skl, kbl | `IBPB` on function return; CALL depth management | ~20% syscall/interrupt regression on hsw/skl; heavy on microbenchmarks |
| **BHI / eIBRS-BHI** | skl–icl (eIBRS without hardware BHI_DIS) | `BHI_DIS_S` MSR or BHB clearing on syscall entry | Added cost per syscall on icl; negligible on spr+ (hardware BHI_DIS) |
| **GDS (Gather Data Sampling)** | spr D0 stepping | `VERW` on task switch when AVX/AMX gather active | Overhead when AVX-512 gather instructions used in workload context |
| **RFDS (Register File Data Sampling)** | srf, cwf, and Atom E-cores | `VERW` on every kernel→user return | ~1 cycle per return; amplified by high interrupt/syscall frequency |
| **TSX / TAA** | hsw, skl, csl, cpl (TSX-capable) | TSX disabled by microcode update | Code using `HLE`/`RTM` falls back to lock path; `[LOCK-CONTENTION]` regressions |

**Mitigation tbox correlation for RCA:**
- Regressions on `nhm`/`ivb`/`hsw`/`skl` that resemble syscall overhead: always check
  Retpoline + KPTI as a cost multiplier — they amplify any FBC that increases syscall count.
- Regressions on `spr`/`emr` with AVX-512 workloads: check GDS/VERW overhead on D0 stepping.
- Regressions on `srf`/`cwf`: RFDS `VERW` amplifies FBCs that increase syscall/interrupt rate.
- Regression present on `skl`/`csl` but absent on `icl`/`spr` for the same FBC: Retpoline
  amplification is the likely cause — not a true kernel regression.

---

## Hyper-Threading (SMT)

- Enabled by default on all P-core platforms (skl through gnr, rpl, ptl).
- Absent on E-core-only platforms (srf, cwf).
- **Perf-profile effect**: lock contention appears doubled under HT — two siblings on the
  same physical core compete for the lock; IPC per logical CPU is lower under full load.
- **Kernel paths**: `sched_smt_*`, `topology_sibling_cpumask`, `per_cpu_smt_*`.
- **Regression signal**: FBC that widens a critical section will regress more on HT-enabled
  tboxes than on HT-off or E-core tboxes; confirm by comparing `nr_cpu` / `nr_physical_cpu`
  ratio from cpuinfo.

### MWAIT / C-States (intel_idle driver)

- Deep C-states (C6, C6P) enabled by default on all server platforms.
- `intel_idle` driver manages C-state policy; deeper C-states reduce power but add wakeup
  latency (~50–300 µs for C6 vs. ~1 µs for C1).
- **Regression signal**: FBC that adds a new `schedule()` call in a burst-idle loop can
  push CPUs into deeper C-states between bursts, increasing tail latency.
- **Improvement signal**: FBC that eliminates polling loops allows CPUs to reach C6,
  reducing active power with no throughput cost.
- **Monitor key**: `cpufreq.turbostat.*` and `cpufreq.freq_*` in compare output.
  `perf-stat.cpu-clock` growth without matching throughput increase → idle-time growth.
