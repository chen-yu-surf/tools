# auditperf Domain Reference — Router

> Entry point for all domain knowledge. Read at Phase 3a start.
> Do NOT reproduce tables from sub-files verbatim in output.
>
> **How to use:**
> 1. **Detect the suite** from `job.yaml` (`suite:` or `test:` field). Load the matching file
>    from the Suite Index below.
> 2. **Detect the primary subsystem(s)** from changed file paths in `correlation.txt` or the FBC
>    diff. Load the matching file(s) from the Subsystem Index below — cap at the **2 files with
>    the most changed-file-path matches**; if more subsystems match, note the rest as
>    `(subsystem file skipped — low match count)` instead of loading all of them.
> 3. **Load conditionally** — do not load both of these by default:
>    - [domain/metrics.md](domain/metrics.md): skip if hot-path function names already give an
>      unambiguous classification (e.g. `native_queued_spin_lock_slowpath` → `[LOCK-CONTENTION]`,
>      `flush_tlb_others` → `[TLB-BOUND]`); load only when perf-stat counters must be interpreted
>      without an unambiguous function-name signal.
>    - [domain/kconfig-confounds.md](domain/kconfig-confounds.md): skip in `bisect-driven` mode —
>      the bisect infrastructure holds `.config` fixed between parent and FBC by construction, so
>      kconfig confounds cannot explain the delta there. Load it in `result-search`/`static-only`
>      modes (compared result roots may have unrelated kconfig differences), or whenever
>      `correlation.txt` shows a debug/instrumentation config difference between compared runs.
> 4. At Phase 4 Step 4, load [regression-patterns.md](regression-patterns.md) for the 8
>    regression patterns and fix strategies.
>
> Files under `domain/` are independently maintained — add new suites or subsystems by creating
> a new file; do not edit this router.

---

## Suite Index

| Suite / stressor prefix | Reference file |
|---|---|
| `will-it-scale` | [domain/suites/will-it-scale.md](domain/suites/will-it-scale.md) |
| `stress-ng` | [domain/suites/stress-ng.md](domain/suites/stress-ng.md) |
| `hackbench` | [domain/suites/hackbench.md](domain/suites/hackbench.md) |
| `fio`, `iozone` | [domain/suites/fio.md](domain/suites/fio.md) |
| `lmbench` | [domain/suites/lmbench.md](domain/suites/lmbench.md) |
| `netperf`, `iperf3` | [domain/suites/netperf.md](domain/suites/netperf.md) |
| `pts`, `performance` (phoronix) | [domain/suites/pts.md](domain/suites/pts.md) |
| `unixbench` | [domain/suites/unixbench.md](domain/suites/unixbench.md) |
| `sysbench` | [domain/suites/sysbench.md](domain/suites/sysbench.md) |
| `schbench` | [domain/suites/schbench.md](domain/suites/schbench.md) |
| `vm-scalability` | [domain/suites/vm-scalability.md](domain/suites/vm-scalability.md) |
| `stream`, `tinymembench` | [domain/suites/stream.md](domain/suites/stream.md) |
| `tbench` | [domain/suites/tbench.md](domain/suites/tbench.md) |

If the suite is not listed: skip the suite file; use subsystem file(s) and perf-profile hot-function
names as the sole starting hypothesis.

---

## Subsystem Index

Detect the primary subsystem from the changed file paths in `correlation.txt`. Load all matching
files when the FBC spans multiple subsystems.

| Changed file path prefix | Subsystem | Reference file |
|---|---|---|
| `mm/`, `arch/x86/mm/`, `include/linux/mm*.h`, `include/linux/page*.h`, `include/linux/gfp*.h`, `include/linux/slab*.h` | Memory management | [domain/subsystems/mm.md](domain/subsystems/mm.md) |
| `kernel/sched/`, `include/linux/sched*.h` | CPU scheduler | [domain/subsystems/sched.md](domain/subsystems/sched.md) |
| `fs/`, `include/linux/fs*.h`, `include/linux/dcache.h` | VFS | [domain/subsystems/vfs.md](domain/subsystems/vfs.md) |
| `block/`, `include/linux/blk*.h`, `drivers/nvme/`, `include/linux/nvme*.h` | Block layer / NVMe | [domain/subsystems/storage.md](domain/subsystems/storage.md) |
| `kernel/locking/`, `kernel/futex/`, `include/linux/spinlock*.h`, `include/linux/rwsem.h`, `include/linux/mutex.h` | Locking / synchronization | [domain/subsystems/locking.md](domain/subsystems/locking.md) |
| `net/`, `include/net/`, `include/linux/net*.h`, `include/linux/tcp.h`, `drivers/net/` | Networking | [domain/subsystems/net.md](domain/subsystems/net.md) |
| `kernel/fork.c`, `fs/exec.c`, `include/linux/sched/task.h`, `include/linux/mm_types.h` | Fork / exec | [domain/subsystems/fork.md](domain/subsystems/fork.md) |
| `io_uring/`, `include/linux/io_uring*.h`, `include/uapi/linux/io_uring.h` | io_uring | [domain/subsystems/io_uring.md](domain/subsystems/io_uring.md) |
| `kernel/cgroup/`, `mm/memcontrol.c`, `include/linux/cgroup*.h`, `include/linux/memcontrol.h`, `kernel/sched/psi.c`, `include/linux/psi*.h`, `block/blk-cgroup.c` | cgroup / memcg / PSI | [domain/subsystems/cgroup.md](domain/subsystems/cgroup.md) |

If the changed paths do not match any entry: fall back to hot-function names from the loaded suite
file to infer the subsystem, then load the nearest subsystem file.

---

## Platform Index

Detect the tbox platform from the `tbox` field in job.yaml or the result path. Load when
the tbox code matches or when the diff touches `arch/x86/`, `drivers/platform/x86/`,
`drivers/cpufreq/`, `drivers/acpi/`, or `drivers/idle/`.

LKP tbox names follow `{site}-{code}-{config}`. Topology suffixes: `-d##` single-socket,
`-2sp##` 2-socket server, `-4sp##` 4-socket server, `-2ap##` E-core server (SRF/CWF).

| Code | Microarchitecture | Xeon Brand | Client Core | CPUID (Family-Model-Stepping) |
|---|---|---|---|---|
| `nhm` | Nehalem / Westmere | Xeon 5500/5600 | Core i7 1st gen | `06-1a-*` / `06-2c-*` |
| `ivb` | Ivy Bridge | Xeon E5 v2 | Core 3rd gen | `06-3e-*` |
| `hsw` | Haswell | Xeon E5 v3 | Core 4th gen | `06-3c-*` / `06-3f-*` |
| `skl` | Skylake | Xeon Scalable 1st gen | Core 6th gen | `06-55-*` (SP) / `06-5e-*` (DT) |
| `kbl` | Kaby Lake | — | Core 7th gen | `06-9e-*` |
| `cfl` | Coffee Lake | — | Core 8th/9th gen | `06-9e-*` |
| `cml` | Comet Lake | — | Core 10th gen | `06-a5-*` / `06-a6-*` |
| `wsx` | Whitley platform | Ice Lake-SP / Cooper Lake | — | platform name |
| `csl` | Cascade Lake | Xeon Scalable 2nd gen | — | `06-55-07` |
| `cpl` | Cooper Lake | Xeon Scalable 3rd gen | — | `06-55-0b` |
| `icl` | Ice Lake-SP | Xeon 3rd gen Scalable | Core 10th gen (laptop) | `06-6a-06` |
| `spr` | Sapphire Rapids | Xeon 4th gen Scalable | — | `06-8f-05` (D0), `06-8f-08` (E3/E4) |
| `emr` | Emerald Rapids | Xeon 5th gen Scalable | — | `06-cf-02` |
| `gnr` | Granite Rapids | Xeon 6 P-core | — | `06-ad-01` |
| `srf` | Sierra Forest | Xeon 6 E-core | — | `06-af-03` |
| `cwf` | Clearwater Forest | Xeon 6 E-core (next gen) | — | `06-dd-01` |
| `rpl` | Raptor Lake | — | Core 13th/14th gen | `06-b7-*` / `06-ba-*` |
| `ptl` | Panther Lake | — | Core Ultra Series 3 | `06-cc-02` |

**SNC detection**: if `nr_node` in the tbox host file exceeds the socket count, Sub-NUMA
Clustering is active. Read the actual host file — do not assume topology from the tbox name.

**Load order**: always load [domain/platforms/ia-common.md](domain/platforms/ia-common.md)
(cross-platform PMU events, mitigations, hot-path functions, NUMA modes, HT/SMT), then
load the matching platform file:

| Platform codes | Platform-specific file |
|---|---|
| `nhm`, `ivb`, `hsw`, `wsx` | [domain/platforms/nhm-hsw.md](domain/platforms/nhm-hsw.md) |
| `skl` | [domain/platforms/skl.md](domain/platforms/skl.md) |
| `csl` | [domain/platforms/csl.md](domain/platforms/csl.md) |
| `cpl` | [domain/platforms/cpl.md](domain/platforms/cpl.md) |
| `kbl`, `cfl`, `cml`, `rpl`, `ptl` | [domain/platforms/client-legacy.md](domain/platforms/client-legacy.md) (mitigation/ISA profile only; no server NUMA patterns) |
| `icl` | [domain/platforms/icl.md](domain/platforms/icl.md) |
| `spr` | [domain/platforms/spr.md](domain/platforms/spr.md) |
| `emr` | [domain/platforms/emr.md](domain/platforms/emr.md) |
| `gnr` | [domain/platforms/gnr.md](domain/platforms/gnr.md) |
| `srf` | [domain/platforms/srf.md](domain/platforms/srf.md) |
| `cwf` | [domain/platforms/cwf.md](domain/platforms/cwf.md) |

---

## Generic Reference

| Content | File |
|---|---|
| Metric polarity + hardware counter classification | [domain/metrics.md](domain/metrics.md) |
| Kconfig / debug-instrumentation confounds (LOCKDEP, KASAN, FTRACE, PREEMPT_RT, mitigations=off, ...) | [domain/kconfig-confounds.md](domain/kconfig-confounds.md) |
| 8 regression patterns + fix strategies | [regression-patterns.md](regression-patterns.md) |


