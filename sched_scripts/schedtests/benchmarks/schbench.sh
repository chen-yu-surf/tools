#!/bin/bash
#####################
#schbench config
#####################
#: "${schbench_job_list:="1 2 4 8"}"
: "${schbench_job_list:="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28"}"
: "${schbench_iterations:=10}"
: "${schbench_run_time:=100}"

#####################
#schbench parameters
#####################
schbench_work_mode="normal"
#schbench_worker_threads=$(($(nproc) / 4))
schbench_worker_nr="1 2 4 8 16 31"

# schbench has to be reverted back to
# commit 2eef44790a4e ("schbench: record the
# execution time in the matrix multiplication mode")
schbench_old_pattern="99.0000th"
schbench_pattern="99.0th"
schbench_pattern2="Latency percentiles (usec) runtime $schbench_run_time (s)"
schbench_sleep_time=30
schbench_log_path=$test_path/logs/schbench

run_schbench_pre()
{
	schbench -m 1 -t 1 -r 1 &> /dev/null
	if [ $? -ne 0 ]; then
		echo "[schedtests]: schbench not found or version not compatible"
		echo "schbench usage:"
		echo "        -m (--message-threads): number of message threads (def: 2)"
		echo "        -t (--threads): worker threads per message thread (def: 16)"
		echo "        -r (--runtime): How long to run before exiting (seconds, def: 30)"
		echo "        -a (--auto): grow thread count until latencies hurt (def: off)"
		echo "        -p (--pipe): transfer size bytes to simulate a pipe test (def: 0)"
		echo "        -R (--rps): requests per second mode (count, def: 0)"
		exit 1
	fi
	for job in $schbench_job_list; do
		for wm in $schbench_work_mode; do
			for thrd in $schbench_worker_nr; do
				mkdir -p $schbench_log_path/$wm/$job-mthreads-$thrd-workers/$run_name
			done
		done
	done
}

run_schbench_post()
{
	for job in $schbench_job_list; do
		for wm in $schbench_work_mode; do
			for thrd in $schbench_worker_nr; do
				log_file=$schbench_log_path/$wm/$job-mthreads-$thrd-workers/$run_name/schbench.log
				if grep -q $schbench_old_pattern $log_file; then
					schbench_pattern=$schbench_old_pattern
				fi
				cat $log_file | grep -e "$schbench_pattern2" -e "$schbench_pattern" | grep -A 1 "$schbench_pattern2" | grep \
					"$schbench_pattern" | awk '{print $3}' > \
					$schbench_log_path/$wm/$job-mthreads-$thrd-workers/$run_name.log
			done
		done
	done
}

run_schbench_single()
{
	local job=$1
	local wm=$2
	local iter=$3
	local thrd=$4

	#perf record -q -ag --realtime=1 -m 256 --count=1000003 -e cycles:pp -o perf-schbench-$job-$wm-$iter.data -D 10000 -- schbench -m $job -t $schbench_worker_threads -r $schbench_run_time -s 30000 -c 30000
	schbench -m $job -t $thrd -r $schbench_run_time
	#perf report  --children --header -U -g folded,0.5,callee --sort=dso,symbol -i perf-schbench-$job-$wm-$iter.data > perf-profile-schbench-$job-$wm-$iter.log
	#rm -rf perf-schbench-$job-$wm-$iter.data
}

run_schbench_iterations()
{
	local job=$1
	local wm=$2
	local thrd=$3

	#. $test_path/monitor.sh
	for i in $(seq 1 $schbench_iterations); do
		echo "mThread:" $job " - Mode:" $wm "workers:" $thrd " - Iterations:" $i
	#	run_ftrace 10 $schbench_log_path/$wm/mthread-$job/$run_name-ftrace.log &
		#cat /proc/schedstat | grep cpu >> $schbench_log_path/$wm/mthread-$job/$run_name-schedstat_before.log
		run_schbench_single $job $i $wm $thrd &>> $schbench_log_path/$wm/$job-mthreads-$thrd-workers/$run_name/schbench.log
		#echo "mThread:"$job" - Mode:"$wm" - Iterations:"$i >> schbench_process.log
		#sudo scp tbench_process.log chenyu-dev:~/
		
		#cat /proc/schedstat | grep cpu >> $schbench_log_path/$wm/mthread-$job/$run_name-schedstat_after.log
		sleep 10
	done
}

run_schbench()
{
	for job in $schbench_job_list; do
		for wm in $schbench_work_mode; do
			echo "schbench: wait 10 seconds for the next case"
			sleep $schbench_sleep_time
			for thrd in $schbench_worker_nr; do
				run_schbench_iterations $job $wm $thrd
			done
		done
	done
	echo -e "\nschbench testing completed"
}

run_schbench_pre
run_schbench
run_schbench_post
