# kvm-scripts

A lightweight benchmarking framework primarily aims to do tdx
performance test. It is composed of two parts, the host side
test(kselftest), and the guest side test(benchdnn runs within
the guest). This test framework can be used for multiple usage.
Such as comparing the difference between a normal guest and a tdx
guest, checking if there is any performance regression for every
kernel release, etc.

This tool is inspired by the TDX performance tuning guidance published
at [here](https://www.intel.com/content/www/us/en/developer/articles/technical/trust-domain-extensions-on-4th-gen-xeon-processors.html)
And this tool also follows the guidance of TDX performance tuning
document from Shiny's team.

## Invocation

It is recommended to run the test as root to avoid unexpected issues.

The test framework is composed of two parts, kselftest running
on the host, normal benchmarks running on the guest. Before running
the test, the corresponding benchmarks need to be installed.

## pre-install

### kernel
```
git clone --branch kvm-upstream-next https://github.com/intel/tdx.git tdx-linux
cd tdx-linux
cp $KERNEL_CONFIG .config
make olddefconfig
make all -j240 -s
```

boot the host kernel with kvm_intel.tdx=on

### misc

Several packages need to be installed, which are required by the mmtests.
To make the netperf work, the host needs to install mmtests under /root/git-private.

## test configurations

Every VCPU is pinned to 1 physical logical processor, within 1 numa node.
The cpufreq governor is set to performance on the host.
The cpuidle C-state is limited to lower than/equal to C1 on the host.
The turbo boost is disabled on the host.
network benchmark is using bridge-NAT mode and virtio. Later the passthrough
mode will be covered. The server benchmark is launched on the host, and the
client benchmark is launched on the guest.

## run the test

./launch.sh

## monitor

When launching the test, kvmexit.py can be used to track the kvm exit
event. Please refer to kvmstat.sh.

## Report

The result will be stored in the host's current working directory.

kselftest for tdx vm creation and destruction:

```
Size(GB)        Create Time     Destroy Time
10              210             9
20              403             17
30              629             26
...
```


netperf UDP_RR result between a generic vm and a tdx vm:

```
                                gen                    tdx
                                vm1                    vm1
Min       10    29487.60 (   0.00%)    12498.38 ( -57.61%)
Hmean     10    29534.07 (   0.00%)    12527.03 * -57.58%*
Stddev    10       65.82 (   0.00%)       40.62 (  38.30%)
CoeffVar  10        0.22 (   0.00%)        0.32 ( -45.47%)
Max       10    29580.69 (   0.00%)    12555.82 ( -57.55%)
BHmean-50 10    29580.69 (   0.00%)    12555.82 ( -57.55%)
BHmean-95 10    29580.69 (   0.00%)    12555.82 ( -57.55%)
BHmean-99 10    29580.69 (   0.00%)    12555.82 ( -57.55%)
```

onednn result between a generic vm and a tdx vm:
```
                    gen-training                  tdx-training
Total time          106.49                        140.62 (-32.05%)


                    gen-inference-batched         tdx-inference-batched
Total time          5.85                          13.17 (-125.13%)


                    gen-inference-lb              tdx-inference-lb
Total time          288.71                        342.70 (-18.70%)

```

We can see that, netperf and onednn both perform worse on tdx vm.
