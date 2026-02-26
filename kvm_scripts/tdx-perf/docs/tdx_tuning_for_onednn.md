performance tuning for OneDNN on TDX
=================================
Intel [TDX](https://www.intel.com/content/www/us/en/products/docs/accelerator-engines/trust-domain-extensions.html#:~:text=Intel%C2%AE%20TDX%20is%20Intel's,a%20virtual%20machine%20(VM).) is Intel’s confidential computing technology that provides the data security in the cloud environment. The main usage of TDX is to present the host from accessing the private data in the VM guest. This document descibes the step on how to tune the performance of benchdnn(benchmark provided by OneDNN) on TDX guest. Including how the benchmark is tested,  how to investigate the performance gap, and finally provide the recommended settings for AI workloads.

# Table of Contents

- [Test settings](#settings)
- [performance gaps](#gaps)
- [gap analysis](#analysis)
- [summary](#summary)

# Test settings
The test is to compare the performance difference between a legacy VM and a TD VM. Both TensorFlow and Pytorch leverage OneDNN library for basic operation. Although running full model via TensorFlow, Pytorch would be closer to real production environment, it would be easier to expose any bottleneck by running specific sub-operations such as convolutions/matrix multiply, etc. Choose benchdnn for this purpose, which is provided by OneDNN. Most test settings are derived from the suggestion from "TDX\_Perf\_Reference\_doc\_from\_Intel\_External". To get rid of any run-to-run variance, each vCPU of the VM instance is bind to 1 physical CPU on numa node 0. The cpufreq governor is set to "performance" mode, and turbo boost is disabled. The C-states deeper than C1 are all disabled. The Linux kernel is based on v6.8-rc5, with the basic TDX [patches](https://lore.kernel.org/lkml/cover.1708933498.git.isaku.yamahata@intel.com/) applied.

# Performance gaps
According to initial test, the throughput of training/inference-batched/inference-lb on a TD VM is **18% ~ 125%** lower than that on a legacy VM. 
# Gap analysis
The possible direction to analysis a VM guest performance are illustrated below:
* VM exit evaluation
* perf events/profiling evaluation on the host
* perf events/profiling evaluation on the VM guest
## VM exit evaluation
The overhead of VM exit and VM enter is costly which makes the VM exit one of the key factors that decrease the performance. So the first clue is to figure out the VM exit is the offender. Using the following bpftrace script to capture the VM exit statistics within 10 seconds:
```
tracepoint:kvm:kvm_exit
{
	@reason[args->exit_reason] = count();
}
```

VM exit on legacy VM:
```
@reason[18]: 1                                  EXIT_REASON_VMCALL
@reason[0]: 14                                  EXIT_REASON_EXCEPTION_NMI
@reason[31]: 63                                 EXIT_REASON_MSR_READ
@reason[12]: 146                                EXIT_REASON_HLT
@reason[56]: 182                                EXIT_REASON_APIC_WRITE
@reason[49]: 267                                EXIT_REASON_EPT_MISCONF
@reason[52]: 142929                             EXIT_REASON_PREEMPTION_TIMER
@reason[1]: 143007                              EXIT_REASON_EXTERNAL_INTERRUPT
@reason[32]: 143258                             EXIT_REASON_MSR_WRITE
```

VM exit on TD VM:
```
@reason[48]: 5121                               EXIT_REASON_EPT_VIOLATION
@reason[77]: 137299                             EXIT_REASON_TDCALL
@reason[1]: 271561                              EXIT_REASON_EXTERNAL_INTERRUPT 
```
We can see, the top VM exit reason on a legacy VM is EXIT_REASON_PREEMPTION_TIMER, EXIT_REASON_EXTERNAL_INTERRUPT and EXIT_REASON_MSR_WRITE. While on TD VM, they are EXIT_REASON_TDCALL and EXIT_REASON_EXTERNAL_INTERRUPT. Firstly all these VM exit are caused by timer related operation. The followings are the explaination for each reason:
```
EXIT_REASON_EXTERNAL_INTERRUPT:
timer interrupt, triggered by the host, and triggered by the TD VM
EXIT_REASON_PREEMPTION_TIMER:
timer interrupt, triggered by the legacy VM
EXIT_REASON_MSR_WRITE:
timer arming, triggered by the legacy VM on TSC deadline MSR
EXIT_REASON_TDCALL:
timer arming, triggered by the TD VM via tdcall

```
According to the result, total number of timer interrupt is the same on legacy VM and TD VM:
```
timer interrupt on legacy VM:
EXIT_REASON_EXTERNAL_INTERRUPT + EXIT_REASON_PREEMPTION_TIMER = 285936
timer interrupt on TD VM:
EXIT_REASON_EXTERNAL_INTERRUPT = 271561
```
and so does the timer arming:
```
timer arm on legacy VM:
EXIT_REASON_MSR_WRITE = 143258
timer arm on TD VM:
EXIT_REASON_TDCALL = 137299
```
Although the number of timer interrupt and timer arm is the same, the overhead of dealing with these VM exit is much lower for a legacy VM. This is because the legacy VM uses a fast path for EXIT_REASON_PREEMPTION_TIMER, and the arm of timer via tdcall on TD VM involves the TDX module, which is very expensive.

To get rid of the impact of timer interrupt, the nohz_full is deployed both on the host and the guest, to reduce the timer interrupt. However, according to the test, even the nohz_full has reduced the VM exit a lot, there is still big performance gap between a legacy VM and a TDX VM. This indicates that, the VM exit is not the bottleneck.

To narrow down, further simplify the test case by stressing the matrix multiply operation, and only run it on single CPU:
```
export OMP_PROC_BIND=true;export OMP_PLACES="{4}";export OMP_NUM_THREADS=1; time benchdnn --matmul --repeats-per-prb=1 -v6  --ctx-init=1 --ctx-exe=1 --stag=ab --wtag=ab --dtag=ab 1024x4096:4096x1000_n"Alexnet_train:FWD,ip3*1"
```
## host perf profiling evaluation
Using the following command on the host to capture the perf result on physical CPU5 (the benchdnn is laucnhed on vCPU4, which is bound on physical CPU5):
```
perf record -C 5 -ag sleep 4
```
The perf profile when running legacy VM:
```
39.92%    16.34%  [kernel.kallsyms]  [k] vmx_vcpu_run
35.62%    29.34%  [kernel.kallsyms]  [k] vmx_vmexit
10.34%    10.34%  [kernel.kallsyms]  [k] add_atomic_switch_msr
8.13%      8.13%  [kernel.kallsyms]  [k] kvm_load_host_xsave_state
```
The first two functions are expected, because every vm exit would fall into this code path.  The rests are perf related MSR and pkru_writ/read. And they are inevitable, because the host does not know whether the guest has changed the PMU msr/pkru or not.

The perf profile when running TD VM:
```
34.84%    34.84%  [kernel.kallsyms]  [k] __seamcall_saved_ret
25.78%     2.98%  [kernel.kallsyms]  [k] tdx_vcpu_run
12.17%    12.17%  [kernel.kallsyms]  [k] tdx_restore_host_xsave_state
```
According to the profile, these functions are expected for TD VM exit. It seems that there is no much clue on the host side why performance on the TD vm is lower. Then need to run the perf profile in the VM to see what is the difference.
## VM guest perf profiling evaluation
According to the perf profile result on the VM guest, the performance gap is in the access of the prb buffer in compute_ref_matmul() in OneDNN. To be more specific, the bottlenecks in compute_ref_matmul() are:
```
1.read the prb buffer  
2.pxor instruction.
3.read/write to an auto variable s and w
```
On a legacy VM, the perf annotate result is:
```
20%    auto w = wei[wei_off_f(prb, wei_mb, k, n)] - wei_zp; 
42%    dst += s * w; 
```
while on a TD VM, the perf annotate result is:
```
42%  auto w = wei[wei_off_f(prb, wei_mb, k, n)] - wei_zp; 
              32%  pxor      %xmm1,%xmm1
              inline int64_t wei_off_f(const prb_t *prb, int64_t mb, int64_t k, int64_t n):
                 33.94% mov     0x58(%rax),%rax  ---> read  prb->m
                 33.43% mov     -0x20(%rbp),%rax  ---> read  n
31%   dst += s * w;
```
We can see that, the bottleneck on both legacy VM and TD VM is the memory access. This buffer is allocated as a continuous array, and the compute_ref_matmul() access the whole buffer by every 8 bytes.  The cycles spent on array memory access is higher on TD VM. This indicates that, the bottleneck is the memory access.
## memory access evaluation
One typical factor to impact the memory access is the huge page. Since on the host the THP(Transparent Huge Page) is enabled, the KVM would allocate huge page for a legacy VM by default. However, since TDX is based on a mechanism named guest memfd to allocate pages, it requires that several options are enabled to make huge page work. The first patch is the transparent huge page support for TDX KVM,  which can be found [here](https://lore.kernel.org/lkml/cover.1708933624.git.isaku.yamahata@intel.com/#r). Besides,  the qemu side is required to provide huge page support for TDX, thus this [patch](https://lore.kernel.org/qemu-devel/20231115071519.2864957-4-xiaoyao.li@intel.com/) is also needed. After these two patches applied, with THP both enabled on the host and the VM guest, the benchdnn performance becomes the same between a legacy VM and a TD VM.
# Summary
According to the whole investigation process, the Transparent Huge Page is the key factor to impact memory intensive workload. It is recommended to enable THP for AI workloads. The reason why THP brings benefit might that, it reduce the TLB miss when trying to convert GPA(guest physical address) to HPA(host physical address), thus less EPT walk is needed. Besides, even if TLB is missed, THP reduces the EPT page walk level by 1 (from PTE to PMD). This could largely reduced the overhead of address translating thus improve the performance.

The user in the host can query the following items to check if the VM guest has enabled the THP:
```
cat /sys/kernel/debug/kvm/pages_2m
1422
cat /sys/kernel/debug/kvm/pages_4k
75
```  
