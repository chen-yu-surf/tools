#!/bin/bash

echo 1 > /sys/kernel/debug/sched/llc_aggr_tolerance

pepc pstates config --governor performance
pepc pstates config --turbo off
pepc cstates config --disable C1E
pepc cstates config --disable C6

echo 1 > /proc/sys/kernel/numa_balancing
echo 0 > /proc/sys/kernel/sched_schedstats

echo 0 > /sys/kernel/debug/sched/llc_enabled
./run-mmtests.sh --no-monitor --config config-schbench bs-sb
sleep 5
sync

echo 1 > /sys/kernel/debug/sched/llc_enabled
./run-mmtests.sh --no-monitor --config config-schbench sc-sb
