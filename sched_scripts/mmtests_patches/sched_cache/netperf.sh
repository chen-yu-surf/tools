#!/bin/bash

min_job=$(($(nproc) / 4))
pairlist="$min_job $(($min_job * 2)) $(($min_job * 3)) $(($min_job * 4)) $(($min_job * 5)) $(($min_job * 6)) $(($min_job * 7)) $(($min_job * 8))"

pairlist="8"

echo 1 > /sys/kernel/debug/sched/llc_aggr_tolerance
echo 20 > /sys/kernel/debug/sched/llc_imb_pct
echo 50 > /sys/kernel/debug/sched/llc_overload_pct

pepc pstates config --governor performance
pepc pstates config --turbo off
pepc cstates config --disable C2

echo 1 > /proc/sys/kernel/numa_balancing
echo 0 > /proc/sys/kernel/sched_schedstats

####################################################

echo 0 > /sys/kernel/debug/sched/llc_enabled

#netperf
for pair in $pairlist; do
	cp config-netperf-mmtests netperf-cfg
	sed -i "s/NR_PAIRS=/NR_PAIRS=$pair/g" netperf-cfg
	./run-mmtests.sh --no-monitor --config netperf-cfg bs-np-${pair}pairs
	exit
	sleep 5;
	sync;
done

#################################################################

echo 1 > /sys/kernel/debug/sched/llc_enabled

for pair in $pairlist; do
	cp config-netperf netperf-cfg
	sed -i "s/NR_PAIRS=/NR_PAIRS=$pair/g" netperf-cfg
	./run-mmtests.sh --no-monitor --config netperf-cfg sc-np-${pair}pairs
	sleep 5;
	sync;
done
