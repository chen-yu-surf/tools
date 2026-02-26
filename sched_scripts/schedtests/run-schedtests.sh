#!/bin/bash
rela_path=`dirname $0`
test_path=`cd "$rela_path" && pwd`

pepc pstates config --governor performance
pepc pstates config --turbo off
pepc cstates config --disable C1E
pepc cstates config --disable C6
echo 1 > /proc/sys/kernel/numa_balancing
echo 0 > /proc/sys/kernel/sched_schedstats

#sleep 10

run_name=`uname -r`
# 25% 50% 75% 100% 125% 150% 175% 200%
min_job=$(($(nproc) / 4))
joblist="$min_job $(($min_job * 2)) $(($min_job * 3)) $(($min_job * 4)) $(($min_job * 5)) $(($min_job * 6)) $(($min_job * 7)) $(($min_job * 8))"
runtime=100
iterations=3

start_hackbench()
{
	hackbench_job_list="1 2 4"
	#hackbench_job_list="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28"
	hackbench_iterations=$iterations
	. $test_path/benchmarks/hackbench.sh
}

start_netperf()
{
	netperf_job_list=$joblist
	netperf_run_time=$runtime
	netperf_iterations=$iterations
	. $test_path/benchmarks/netperf.sh
}

start_tbench()
{
	tbench_job_list=$joblist
	tbench_run_time=$runtime
	tbench_iterations=$iterations
	. $test_path/benchmarks/tbench.sh
}

start_schbench()
{
	schbench_job_list="1 2 4 8"
	#schbench_job_list="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28"
	schbench_run_time=$runtime
	schbench_iterations=$iterations
	. $test_path/benchmarks/schbench.sh
}

if [ -n "$2" ]; then
	run_name=$2
fi

[ $# = 0 ] && {
        start_hackbench
        start_netperf
        start_tbench
        start_schbench
        exit
}

benchmark=$1

if [ -n "$3" ]; then
	joblist=$3
fi


case "$benchmark" in
	'hackbench'	) start_hackbench	;;
	'netperf'	) start_netperf	;;
	'tbench'	) start_tbench	;;
	'schbench'	) start_schbench	;;
esac
