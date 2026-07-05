# Sapphire Rapids (spr) Platform Reference

> Covers: Intel Xeon 4th gen Scalable (Sapphire Rapids), CPUID `06-8f-05` (D0),
> `06-8f-08` (E3/E4). Primary server platform in LKP.

---

## Cache and Topology

| Property | Value |
|---|---|
| Max cores/socket | 60 |
| L1-D | 48 KB |
| L2 (private) | 2 MB |
| L3/LLC per core | 1.875 MB |
| DDR | DDR5-4800, 8 ch/socket |
| UPI links | 4 × 16 GT/s |
| NUMA modes | SNC-2, SNC-4, Quadrant (default) |
| Hyper-Threading | Yes |
| AVX-512 | Yes (no frequency license — Golden Cove core) |
| AMX | Yes (TMUL: INT8, BF16) |
| TDX | Yes (host-mode capable) |
| GDS mitigation | D0 stepping only (`06-8f-05`) |
| Memory controllers | 4 per socket |

---

## Key Characteristics

- **eIBRS + hardware BHI_DIS**: no software BHB clearing needed; Retpoline and BHI
  overhead are negligible.
- **AVX-512 without frequency penalty**: Golden Cove eliminates the license downgrade
  present on Skylake-SP/Cascade Lake. AVX-512 runs at full turbo frequency.
- **AMX XSTATE (~8 KB)**: `XSAVES`/`XRSTORS` with AMX tile context costs ~200 more
  cycles. Scheduler-heavy benchmarks (hackbench, schbench) are sensitive when AMX-using
  tasks are co-scheduled.
- **Dominant LKP test platform**: most regression and improvement reports from the LKP
  mailing list originate from spr tboxes. Cross-reference with icl (lower CPU count) to
  separate scalability regressions from correctness regressions.

---

## Platform-Specific Regression Patterns

### NUMA Scalability Cliff at ~224 CPUs

- FBCs that add a global lock, shared atomic counter, or per-mm/per-sb serialisation point
  show **super-linear regression** at this CPU count, invisible on icl (64 CPUs).
- Detection: compare result roots from icl vs. spr — regression worsens with CPU count.
- Fix: per-CPU batching, lock-free RCU, per-node counters.

### TLB Shootdown IPI Storm

- `flush_tlb_mm()` sends IPIs to all ~224 logical CPUs; a single flush serialises hundreds
  of concurrent threads.
- Signal: `flush_tlb_others` / `smp_call_function_many` in positive-delta stacks;
  `perf-stat.dTLB-load-misses` flat but throughput regresses; IPI rate in `interrupts.*` rises.
- Fix: `flush_tlb_page()` for single-page; `tlbbatch` for ranges; lazy `tlb_flush_pending`.

### AMX XSTATE Context-Switch Overhead

- AMX tile state saved/restored on every context switch once a task has used AMX.
- Signal: `fpu__restore_sig` / `copy_xregs_to_user` in positive-delta stacks;
  `perf-stat.context-switches` up; hackbench/schbench regresses.
- Fix: `kernel_fpu_begin/end()` to bound kernel AMX use; `TILE_RELEASE` before preemption;
  avoid AMX within interrupt handlers.

### SST / HWP MSR Write Storm

- FBCs that add `cpufreq_update_policy()` or modify EPP in hot paths trigger per-core
  `HWP_REQUEST` MSR writes; at ~224 CPUs these serialise on the MSR bus.
- Signal: `native_write_msr` spikes; `intel_pstate_*` hot; degradation scales with CPU count.
- Fix: batch policy updates; avoid per-request EPP changes in fast paths.

### GDS Mitigation Overhead — D0 Stepping Only

- On D0 stepping (`06-8f-05`), `VERW` is inserted on task switch when AVX/AMX gather
  instructions were used.
- Signal: slight throughput regression with AVX-512 gather workloads; absent on E3/E4
  steppings (`06-8f-08`) and on emr.
- Fix: none required in kernel; platform microcode issue.

### Intel DSA / IDXD Regression

- FBCs that change `dmaengine_get_unmap_data()` / `idxd_wq_submit_descriptor()` regress
  memory-copy bandwidth in DSA-enabled jobs.
- Signal: `uncore_imc.UNC_M_CAS_COUNT.WR` increases with flat throughput;
  `drivers/dma/idxd/` functions in positive-delta stacks.

### TDX VM-Exit Overhead

- FBCs touching SEPT page table management (`arch/x86/virt/vmx/tdx/`), `tdx_mem_*`,
  or SEAMCALL dispatch increase VM-entry/exit latency.
- TDX adds ~5–10% guest VM-exit overhead vs. non-TDX VMX.
- Signal: guest benchmarks (`kvm-unit-tests`, `pts/iozone`) regress; host perf-profile
  shows `tdx_*` or `seamcall` functions hot.

### CXL Memory Misplacement

- On SPR systems with CXL Type-3 memory, FBCs that remove explicit `nid` placement may
  land hot data on the CXL NUMA node (2–3× DRAM latency).
- Signal: `[MEMORY-BOUND]`; high `MEM_LOAD_RETIRED.L3_MISS` but flat `cache-misses` on
  local LLC; regression absent on non-CXL tboxes.
- Fix: `alloc_pages_node(numa_node_id(), ...)` to prefer local DDR5 node.
