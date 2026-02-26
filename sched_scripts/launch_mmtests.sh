#!/bin/bash

[ $# = 0 ] && exit

pepc.standalone pstates config --governor performance
pepc.standalone pstates config --turbo off
pepc.standalone cstates config --disable C6
pepc.standalone cstates config --disable C1E
echo 1 > /proc/sys/kernel/numa_balancing
echo 0 > /proc/sys/kernel/sched_schedstats

loop=$1

min_job=$(($(nproc) / 4))
pairlist="$min_job $(($min_job * 2)) $(($min_job * 3)) $(($min_job * 4)) $(($min_job * 5)) $(($min_job * 6)) $(($min_job * 7)) $(($min_job * 8))"

schedfeat="SIS_FAST"
noschedfeat="NO_SIS_FAST"
# change whatever you want to test
echo ${schedfeat} > /sys/kernel/debug/sched/features

#netperf
for pair in $pairlist; do
	cp netperf-config-mmtests netperf-cfg
	sed -i "s/NETPERF_ITERATIONS=/NETPERF_ITERATIONS=$loop/g" netperf-cfg
	sed -i "s/NR_PAIRS=/NR_PAIRS=$pair/g" netperf-cfg

	./run-mmtests.sh --no-monitor --config netperf-cfg netperf-rr-${pair}pairs-${schedfeat}
done

#hackbench
cp hackbench-config-mmtests hackbench-cfg
./run-mmtests.sh --no-monitor --config hackbench-cfg hackbench-${schedfeat}

echo ${noschedfeat} > /sys/kernel/debug/sched/features
for pair in $pairlist; do
	cp netperf-config-mmtests netperf-cfg
	sed -i "s/NETPERF_ITERATIONS=/NETPERF_ITERATIONS=$loop/g" netperf-cfg
	sed -i "s/NR_PAIRS=/NR_PAIRS=$pair/g" netperf-cfg

	./run-mmtests.sh --no-monitor --config netperf-cfg ${pair}-${noschedfeat}
done

#hackbench
cp hackbench-config-mmtests hackbench-cfg
./run-mmtests.sh --no-monitor --config hackbench-cfg hackbench-${noschedfeat}
