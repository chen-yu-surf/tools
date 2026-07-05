# auditperf — Kconfig / Debug-Instrumentation Confounds

> Load per domain-reference.md's conditional rule (skipped by default in `bisect-driven` mode,
> where the bisect infrastructure holds `.config` fixed between parent and FBC).
> A regression can be explained by a **kconfig or debug-instrumentation difference** between
> the two compared kernels rather than by the FBC's code logic. Check this table before
> concluding the FBC itself is the cause, especially in `result-search` mode (comparing across
> job configs that may differ) and in `static-only` mode (no baseline to compare against at all).

---

## When this is (and isn't) a live confound

- **`bisect-driven` mode**: the baseline (`b`) and FBC (`a`) are almost always built from the
  **same kconfig file** (single-commit bisect on one job). Debug-instrumentation options are
  therefore usually **constant across both sides** and cannot explain the delta — do not raise
  this as the primary hypothesis here unless the FBC diff itself touches a `Kconfig` file or a
  `Makefile` that changes which debug option is compiled in by default.
- **`result-search` mode**: the matched result roots may come from **different job configs**
  (different kconfig files, different kernel versions with different defaults). Always diff the
  two kconfig files (or at least grep the specific options below) before trusting the comparison.
- **`static-only` mode**: there is no baseline measurement at all — if the FBC's own diff touches
  `Kconfig`, `arch/x86/Kconfig*`, or a `Makefile` that flips a debug default, state explicitly that
  the predicted regression may be a build-config artifact of the target kernel used for testing,
  not the code change itself.

---

## Common Debug/Instrumentation Confounds

| Kconfig option | Effect if enabled | Signature that reveals it |
|---|---|---|
| `CONFIG_LOCKDEP` | Adds significant overhead to every lock acquire/release for dependency-graph tracking | Regression appears uniformly across nearly every lock-touching benchmark, not specific to the FBC's lock; `lock_acquire`/`lock_release` unusually hot in perf-profile even for otherwise-cheap locks |
| `CONFIG_KASAN` (generic or SW tags) | 2-3x general slowdown from shadow-memory checks on every memory access | Regression magnitude far exceeds what the FBC's diff mechanism could plausibly cause; `__asan_load*`/`__asan_store*` or `kasan_check_range` hot in profile |
| `CONFIG_PROVE_LOCKING` | Extends every lock operation with proof-of-correctness bookkeeping (usually bundled with LOCKDEP) | Same signature as LOCKDEP |
| `CONFIG_DEBUG_ATOMIC_SLEEP` | Adds a check on every potential sleep point inside atomic/preempt-disabled sections | Small fixed overhead per scheduling-relevant call; look for `__might_sleep` in profile |
| `CONFIG_DEBUG_PREEMPT` | Extra preempt-count validation on every preempt enable/disable | Small fixed overhead scaling with preempt toggle frequency (scheduler-heavy benchmarks affected most) |
| `CONFIG_FUNCTION_TRACER` / `CONFIG_FTRACE` (with an active tracer) | `mcount`/`fentry` call at every traced function entry | Function-entry overhead that appears on *every* function uniformly, including ones the FBC never touched — the tell-tale sign vs. a targeted regression |
| `CONFIG_SLUB_DEBUG` (with `slub_debug=` boot param active) | Redzone/poison checks on every slab alloc/free | Regression on any allocation-heavy benchmark, disproportionate to the FBC's actual allocation change |
| `CONFIG_PAGE_POISONING` | Poison/check pattern written on every page free/alloc | Similar to SLUB_DEBUG but at the page allocator level |
| `CONFIG_RCU_CPU_STALL_TIMEOUT` (lowered value) | Doesn't add overhead itself, but a low timeout in a CI kconfig makes RCU stall warnings appear (see [subsystems/locking.md](subsystems/locking.md) RCU stall pattern) at a lower load threshold than production kernels | Stall warning reproduces at low load here but wouldn't at a production timeout — check the value before treating the stall as FBC-severity-representative |
| `PREEMPT_RT` vs `PREEMPT_NONE`/`PREEMPT_VOLUNTARY` | Fundamentally different locking primitives (rt-mutex-backed spinlocks) — a regression pattern from `locking.md` derived under `PREEMPT_NONE` assumptions may not transfer | Check `job.yaml` / kconfig for `CONFIG_PREEMPT_RT` before applying a locking pattern's fix technique verbatim |
| `mitigations=off` boot param or `CONFIG_CPU_MITIGATIONS=n` | Removes retpoline/KPTI/MDS mitigation overhead entirely | A regression visible with mitigations on may shrink or vanish with `mitigations=off` — useful to confirm a mitigation-interaction hypothesis from a platform file (see [platforms/ia-common.md](platforms/ia-common.md)) rather than a bug in the FBC |

---

## How to use this table

1. **Check whether the FBC diff itself touches a `Kconfig`/`Makefile` file** — if so, this is not
   just a confound-check, it may be the root cause (state clearly if the FBC changes a debug
   default rather than runtime logic).
2. **In `result-search` mode**, before trusting a compare between two result roots, confirm both
   used the same kconfig (`grep -c` the options above in each `.config`, or check `job.yaml`'s
   `kconfig:` field for a mismatch).
3. **If a debug option is active on both sides equally**, it is not a confound for *this*
   comparison (it adds a constant offset to both `a` and `b`, which cancels out in `perf_change`)
   — only raise it when it differs between the two compared kernels, or when it's the FBC's own
   change.
4. State the check explicitly in the `## Evidence` section even when the answer is "kconfig
   identical between a/b, ruled out" — this is a required negative-result check per the
   fact/inference separation discipline (README §6), not an optional aside.
