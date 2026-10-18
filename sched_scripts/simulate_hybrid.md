# Simulating an AMD hybrid system to reproduce the cache-aware-scheduling vs asym-packing regression

## Goal

Reproduce, on the symmetric **AMD Ryzen 9 8945HX** development box, the regression fixed by
`sched-cache-honor-asym-packing-over-cache-aware-scheduling-o.md`
(upstream: <https://lore.kernel.org/all/221f8b0345328c4b26b65daff4d3eec56a32b06d.1790617047.git.tim.c.chen@linux.intel.com/>).

The bug was reported on an **AMD Ryzen AI HX 370** (a real hybrid part) running a cache-intensive
Clang full-LTO link:

- Little cores run much slower: **3.3 GHz vs 5.1 GHz**.
- Little-core LLC has half the L3: **8 MB vs 16 MB**.

Cache-aware scheduling co-locates all threads of a process onto **one** LLC *regardless of CPU
priority*. When that LLC is the little one, you pay twice (slow clock + small cache). Asym-packing
wants the task on the **highest-priority** CPU and should win here, but doesn't — until the patch
reorders the checks.

To reproduce on a symmetric box we must manufacture the same asymmetry between the two existing
CCX/LLCs.

---

## The machine (as investigated 2026-10-01)

- CPU: `AMD Ryzen 9 8945HX` (family 25, model 97, Zen4), 16 cores / 32 threads, **single socket, single NUMA node**.
- **Two L3 instances (two LLCs), 32 MB each**:
  - **LLC0** = CPUs `0-7,16-23`
  - **LLC1** = CPUs `8-15,24-31`
  - (SMT siblings: cpu0 & cpu16 share a core; cpu8 & cpu24; etc.)
- cpufreq driver: **`amd-pstate-epp`** (active mode), prefcore **enabled**, `boost=1`.
- `nominal_freq=2501 MHz`, `nominal_perf=76`, `highest_perf (numerator)=166` → `cpuinfo_max_freq≈5462 MHz`.
- Features present: `cat_l3`, `cdp_l3`, `mba`, `cqm_llc`, `cppc`, `rdt_a` (so AMD QoS / resctrl L3 CAT is available).

### Firmware already gives a clean priority split

`amd_pstate_prefcore_ranking` per CPU (from CPPC CAP1 highest_perf field):

```
LLC0 (cpu0-7,16-23): 206..236   (e.g. cpu0=236, cpu4=211, cpu7=226)
LLC1 (cpu8-15,24-31): 166..201  (e.g. cpu8=181, cpu12=166, cpu15=201)
```

So **LLC0 strictly outranks LLC1** already (min big = 206 > max little = 201). That is the
"preferred core" binning. This drives `arch_asym_cpu_priority()` and hence asym-packing — the
priority asymmetry is *already present in hardware*.

### Two important gotchas

1. **The running kernel `7.0.0-34-generic` has NO `CONFIG_SCHED_CACHE`** and no ITMT sysctl file —
   it cannot exhibit the bug. The **source tree** (`/home/chenyu/src/linux_cas_fix`) **is** configured
   with `CONFIG_SCHED_CACHE=y`. **You must build & boot this tree.**
2. **The honor-asym-packing fix is NOT applied in this tree** (verified: `can_migrate_llc_task()` has
   no `sched_asym()` check). So this tree is the **buggy baseline** — ideal for reproducing. Apply the
   `.md` patch afterwards to confirm the fix.

---

## Three asymmetries to manufacture

| Asymmetry | Mechanism | Status | Action |
|---|---|---|---|
| **Scheduler priority** (asym-packing prefers big LLC) | `arch_asym_cpu_priority()` ← amd-pstate `prefcore_ranking`; `SD_ASYM_PACKING` via ITMT on the PKG domain | Already present (206-236 vs 166-201) | amplified by the patch below for a clean/deterministic split |
| **Real frequency gap** | amd-pstate `perf.highest_perf`; `max_freq = nominal_freq·highest_perf/nominal_perf` | Symmetric (both 5.46 GHz) | **cpufreq driver hack** (below) |
| **Real cache gap** | AMD QoS / resctrl **L3 CAT** (`cat_l3`) restricting LLC1's ways | Available, unconfigured | **resctrl runtime step** (below) |

---

## Relevant kernel mechanics (verified in-tree)

- **ITMT / asym-packing**: `arch/x86/kernel/smpboot.c` — `x86_sched_itmt_flags()` returns
  `SD_ASYM_PACKING` when `sysctl_sched_itmt_enabled`. Applied at SMT/cluster/**PKG** levels
  (`SDTL_INIT(tl_pkg_mask, x86_sched_itmt_flags, PKG)`). The **PKG** domain spans the whole socket
  (both LLCs) → that is where cross-LLC cache balancing meets asym-packing.
- **ITMT auto-enables on boot**: `arch/x86/kernel/itmt.c:sched_set_itmt_support()` sets
  `sysctl_sched_itmt_enabled = 1` and creates the debugfs knob at
  **`/sys/kernel/debug/x86/sched_itmt_enabled`** (not procfs). amd-pstate calls it
  (`drivers/cpufreq/amd-pstate.c:1709`).
- **Per-CPU priority**: `arch_asym_cpu_priority(cpu)` → `per_cpu(sched_core_priority, cpu)`, set by
  `sched_set_itmt_core_prio(prefcore_ranking, cpu)` from amd-pstate (`amd_pstate_init_prefcore`).
- **Frequency knob**: `perf_to_freq(perf, nominal_freq, perf.highest_perf)` = `nominal_freq·highest_perf/nominal_perf`.
  `freq_to_perf()` clamps to `perf.highest_perf`, so lowering `highest_perf` caps the achievable freq.
  `perf.highest_perf` (frequency) is **separate** from `cpudata->prefcore_ranking` (asym priority) in
  `union perf_cached` — the firmware packs the ranking into the CPPC highest_perf field, but the
  driver splits them. Lowering `highest_perf` → lower freq; lowering `prefcore_ranking` → lower asym prio.

### Cache-aware scheduling capacity logic (from `kernel/sched/fair.c`)

- `exceed_llc_capacity()` (fair.c ~1486) compares the task group's NUMA **footprint** (pages·PAGE_SIZE)
  against `sd->llc_bytes` = **physical** L3 size in bytes (from cacheinfo `ci->size`, via
  `get_effective_llc_bytes()` in topology.c, scaled by span). **Requires `CONFIG_NUMA_BALANCING`** and
  accumulated footprint. On this **single-node** box the `sched_numa_balancing` branch is inert →
  `exceed_llc_capacity()` returns false and the footprint never accumulates.
- `invalid_llc_nr()` (fair.c ~1534) compares `nr_running_avg·cpu_smt_num_threads` against
  `per_cpu(sd_llc_size, cpu)` = **number of CPUs** in the LLC.
- `can_migrate_llc_task()` (fair.c ~10838), `llc_balance()` (~12036), `alb_break_llc()` (~10885),
  `need_active_balance()` (~13458) are the functions the fix touches.

**Consequence**: `exceed_llc_capacity()` reads the real 32 MB and is inert here, and it does **not**
account for CAT. So cache-aware scheduling stays unaware of the CAT restriction and will aggregate the
process onto one LLC; if that is the little LLC, performance tanks (slow freq + tiny cache). That is
exactly the trap. The asym-packing fix pulls threads back to the big LLC.

---

## The cpufreq driver hack (APPLIED)

Patched `drivers/cpufreq/amd-pstate.c`. Parameter-gated, **off by default** (no effect unless enabled).
Both init paths route through the wrapper (`amd_pstate_init_perf` callers at `:1124` passive and
`:1950` EPP), so it works in `amd-pstate-epp` active mode.

### Edit 1 — knobs (near the other static globals, after `amd_pstate_prefcore`)

```c
/*
 * Fake-hybrid reproduction knobs (debug/testing only).
 *
 * On a symmetric multi-LLC AMD part these let us emulate an AMD hybrid
 * system to reproduce the cache-aware-scheduling vs asym-packing regression:
 * every LLC/CCX other than the boot CPU's is turned into a "little" LLC by
 * capping its highest_perf (which lowers the real max frequency, since
 * max_freq = nominal_freq * highest_perf / nominal_perf) and its ITMT
 * prefcore ranking (which lowers its asym-packing priority).
 *
 * Enable with amd_pstate.amd_pstate_fake_hybrid=1. amd_pstate_little_perf
 * is the capped highest_perf/ranking for the little LLC (e.g. 100 ~= 3.3GHz
 * on a part with nominal_freq=2501MHz, nominal_perf=76). It must stay below
 * the big LLC's prefcore rankings so asym-packing prefers the big LLC.
 */
static int amd_pstate_fake_hybrid;
static int amd_pstate_little_perf = 100;
module_param(amd_pstate_fake_hybrid, int, 0444);
module_param(amd_pstate_little_perf, int, 0444);
```

### Edit 2 — override helper + wrapper hook (replacing the `amd_pstate_init_perf` wrapper)

```c
DEFINE_STATIC_CALL(amd_pstate_init_perf, msr_init_perf);

/*
 * Fake-hybrid override: demote every LLC other than the boot CPU's into a
 * slower, lower-priority "little" LLC. See amd_pstate_fake_hybrid above.
 */
static void amd_pstate_apply_fake_hybrid(struct amd_cpudata *cpudata)
{
	union perf_cached perf;

	if (!amd_pstate_fake_hybrid)
		return;

	/* CCX0 (the boot CPU's LLC) stays "big"; all others become "little". */
	if (per_cpu_llc_id(cpudata->cpu) == per_cpu_llc_id(0))
		return;

	perf = READ_ONCE(cpudata->perf);
	perf.highest_perf   = amd_pstate_little_perf;	/* caps real max frequency */
	perf.max_limit_perf = amd_pstate_little_perf;
	WRITE_ONCE(cpudata->perf, perf);

	/* Lower ITMT ranking so asym-packing deprioritizes the little LLC. */
	WRITE_ONCE(cpudata->prefcore_ranking, amd_pstate_little_perf);

	pr_info_once("amd-pstate: fake-hybrid enabled; demoting little LLC(s) to perf %d\n",
		     amd_pstate_little_perf);
}

static inline int amd_pstate_init_perf(struct amd_cpudata *cpudata)
{
	int ret = static_call(amd_pstate_init_perf)(cpudata);

	if (!ret)
		amd_pstate_apply_fake_hybrid(cpudata);

	return ret;
}
```

Notes:
- `<asm/processor.h>` (for `per_cpu_llc_id`) and `<linux/module.h>` (for `module_param`) are already
  included.
- With `little_perf=100`: LLC1 `max_freq = 2501·100/76 ≈ 3291 MHz` (vs LLC0 5462 MHz) and
  `prefcore_ranking=100` (below the big LLC's 206-236). Even a bigger gap than the real bug (5.1/3.3).
- The EPP path recomputes `max_limit_perf = freq_to_perf(policy->max)` later, but that clamps to the
  capped `highest_perf`, so the cap holds.

**Activate** (after build + boot): add to the kernel command line
```
amd_pstate.amd_pstate_fake_hybrid=1
```
optionally `amd_pstate.amd_pstate_little_perf=<N>` to tune the little-LLC frequency.

---

## The QOS / cache-size step (resctrl L3 CAT) — runtime, not code

Shrink LLC1's usable L3 to emulate "half (or less) the cache" via real AMD QoS enforcement:

```bash
mount -t resctrl resctrl /sys/fs/resctrl          # no "cdp" option — keep schemata simple
cat /sys/fs/resctrl/info/L3/cbm_mask              # e.g. ffff = 16 ways = 32MB
cat /sys/fs/resctrl/schemata                      # e.g. L3:0=ffff;1=ffff
cat /sys/devices/system/cpu/cpu8/cache/index3/id  # which schemata domain id == LLC1

# give LLC1 only 2 of 16 ways (~4MB), LLC0 keeps all 16 (32MB):
echo "L3:0=ffff;1=0003" > /sys/fs/resctrl/schemata
```

Adjust the domain id if cpu8's L3 `id` isn't `1`. This restricts the default (root) group; since
LLC1 cores only touch L3 domain 1, their effective cache collapses while LLC0 stays full.

---

## Reproduce & validate

1. **Build** this tree (`CONFIG_SCHED_CACHE=y`, baseline **without** the fix) with the amd-pstate hack;
   **boot** with `amd_pstate.amd_pstate_fake_hybrid=1`.
2. **Verify**:
   - `cat /sys/kernel/debug/x86/sched_itmt_enabled` → `1`
   - LLC1 `cat /sys/devices/system/cpu/cpu8/cpufreq/cpuinfo_max_freq` ≈ `3291000`; LLC0 cpu0 ≈ `5462711`
   - LLC1 `amd_pstate_prefcore_ranking` = `100`; LLC0 still 206-236
   - resctrl schemata shows LLC1 restricted
3. **Run** a cache-intensive multithreaded workload (the bug used clang full-LTO link; a parallel
   large-working-set benchmark is a fine proxy). Cache-aware scheduling aggregates it onto one LLC;
   when it traps on the little LLC you see the slowdown vs a pre-cache-aware kernel.
4. **Apply the fix** (`sched-cache-honor-asym-packing-over-cache-aware-scheduling-o.md` → `kernel/sched/fair.c`),
   rebuild, rerun → asym-packing pulls threads back to LLC0, slowdown disappears.

---

## Runtime verification (2026-10-02, running kernel 7.3.0-rc2+)

The tree was built and booted (`uname -r` = `7.3.0-rc2+`, `CONFIG_SCHED_CACHE=y`,
driver `amd-pstate-epp`). Confirmed on the live box:

**1. Scheduler priority / asym-packing — ENABLED.**
- `/sys/kernel/debug/x86/sched_itmt_enabled` = `Y`.
- `SD_ASYM_PACKING` present on **both** the `MC` domain (one LLC) and the `PKG` domain
  (spans both LLCs) — dumped via `/sys/kernel/debug/sched/domains/cpu0/domain*/flags`
  after `echo Y > /sys/kernel/debug/sched/verbose` (the `domains/` dir only appears while
  verbose is on).
- `amd_pstate_prefcore_ranking`: LLC0 cpu0=236, cpu4=211, cpu7=226; LLC1 cpu8=181,
  cpu12=166, cpu15=201 → LLC0 strictly outranks LLC1. Firmware split present.

**2. Frequency gap — NOT YET ACTIVE.**
- Debug patch *is* compiled in: `/sys/module/amd_pstate/parameters/amd_pstate_fake_hybrid`
  exists (= `0`) and `amd_pstate_little_perf` = `100`.
- But the kernel cmdline lacks `amd_pstate.amd_pstate_fake_hybrid=1`, so both LLCs are still
  symmetric: cpu0 and cpu8 `cpuinfo_max_freq` both `5462711`, LLC1 ranking still firmware 181
  (not 100). The params are `0444` (read-only) → **must set via cmdline + reboot**, cannot
  toggle at runtime.

**3. Cache gap — APPLIED (runtime).**
- resctrl was unmounted; `info/L3/cbm_mask=ffff` (16 ways, 32 MB total, 2 MB/way),
  `num_closids=16`.
- L3 schemata domain ids: **dom0 = LLC0** (cpu0-7,16-23), **dom1 = LLC1** (cpu8-15,24-31),
  from `cpu8/cache/index3/id=1`.
- Applied `L3:0=ffff;1=00ff` → LLC0 = 16 ways/32 MB, LLC1 = 8 ways/16 MB (half, matching the
  real HX370 ratio). Resctrl config is lost on reboot and must be re-applied each boot.

### Helper script: `fake_hybrid.sh`

Drives the whole reproduction (topology auto-discovered, not hardcoded):

```bash
sudo ./fake_hybrid.sh cmdline     # add fake_hybrid args to /etc/default/grub (backup + update-grub) → REBOOT
sudo ./fake_hybrid.sh uncmdline   # remove them again → REBOOT
sudo ./fake_hybrid.sh cache       # mount resctrl + shrink LLC1's L3 ways (run after every boot)
sudo ./fake_hybrid.sh reset       # restore full L3 to LLC1
sudo ./fake_hybrid.sh verify      # check all three asymmetries
sudo ./fake_hybrid.sh all         # cache + verify (post-reboot one-shot)
```

Tunables via env: `LITTLE_PERF=100`, `LLC1_MASK=00ff` (use `0003` for 2 ways/4 MB).

## Reproducing by TOGGLING cache-aware scheduling at runtime (no rebuild)

The regression can be reproduced **without applying/unapplying the fix patch** — just
flip cache-aware scheduling on/off at runtime and compare. The toggle is a debugfs
file (`kernel/sched/debug.c` registers `llc_balancing/enabled`, which drives
`sysctl_sched_cache_user` + `sched_cache_active_set()`):

```
/sys/kernel/debug/sched/llc_balancing/enabled      # 1 = cache-aware ON, 0 = OFF
```

- **ON (buggy baseline)**: cache-aware scheduling aggregates a process onto its
  *preferred* LLC and `can_migrate_llc_task()` refuses to migrate threads away —
  and that path checks only asym **capacity** (`task_misfits_asym_cpu`, needs
  `SD_ASYM_CPUCAPACITY`, which this box lacks), **not asym-packing priority**. So if
  the preferred LLC is the little one, threads stay trapped there.
- **OFF**: no cache-aware bias → asym-packing pulls threads to the big/high-priority
  LLC0.

### Two things that are REQUIRED for the trap to form

1. **Thread count ≈ one LLC's cores, not more.** With 16 threads a single LLC is
   saturated, `invalid_llc_nr()` disables aggregation, and ON/OFF both just spread
   8/8 → *no regression visible*. Use **8 threads** so the aggregation path stays
   active.
2. **The process must prefer the LITTLE LLC.** The preferred LLC is chosen by
   accumulated occupancy; a workload that forks on cpu0 (LLC0) aggregates on the
   *good* LLC → no penalty. So warm the process up **pinned to LLC1** (a few 10 ms
   epochs) to make LLC1 preferred, then release affinity to all CPUs.

### Scripts

- `cache_hog_ts.c` — time-series workload: runs for a fixed duration and prints
  throughput + LLC thread-split once per second.
- `run_trap.sh` — warms up pinned to LLC1, releases affinity, and runs the trial
  once with cache-aware ON and once OFF (restores the toggle on exit):
  ```bash
  sudo ./run_trap.sh            # defaults: 24 MB, 8 threads, 12 s run, 3 s warmup
  sudo ./run_trap.sh 24 8 12 3  # explicit
  ```
- `run_toggle.sh` — simpler ON/OFF comparison on a plain unpinned run; kept as a
  negative control (without the LLC1 trap it does **not** regress, because the
  process just aggregates on the good LLC0).

### Confirmed result (2026-10-02, 7.3.0-rc2+, buggy baseline, fake_hybrid active)

Both runs warm up at ~157 M/s with all 8 threads on LLC1; at t≈3 s affinity is released:

| cache-aware | threads after release | steady-state throughput |
|---|---|---|
| **ON**  | ~6 of 8 stay on **LLC1** (LLC1:6 / LLC0:2) | **~230 M chases/s** (regression) |
| **OFF** | all 8 migrate to **LLC0** (LLC0:8 / LLC1:0) | **~530 M chases/s** (~2.3× faster) |

## Status / TODO

- [x] Investigated amd-pstate, ITMT, resctrl CAT, and cache-aware capacity logic.
- [x] Applied the parameter-gated cpufreq driver hack to `drivers/cpufreq/amd-pstate.c`.
- [x] Built the kernel from this tree and booted it (debug patch compiled in).
- [x] Verified asym-packing enabled (ITMT + SD_ASYM_PACKING on MC & PKG) and firmware priority split.
- [x] Applied resctrl L3 CAT restriction on LLC1 (`L3:0=ffff;1=00ff`, 16 MB vs 32 MB).
- [x] Wrote `fake_hybrid.sh` to drive/verify the setup.
- [x] Booted with `amd_pstate.amd_pstate_fake_hybrid=1`; frequency gap confirmed (LLC1 ≈ 3291 MHz, ranking 100).
- [x] Reproduced the baseline (buggy) regression by toggling cache-aware scheduling
      (`run_trap.sh`): ON ~230 M/s trapped on LLC1 vs OFF ~530 M/s on LLC0 (~2.3×).
- [ ] Apply the honor-asym-packing patch; rebuild; confirm ON also recovers to LLC0.
