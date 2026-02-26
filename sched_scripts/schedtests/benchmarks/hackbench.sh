#!/bin/bash
#####################
#hackbench config
#####################
#: "${hackbench_job_list:="1 2 4 8"}"
: "${hackbench_job_list:="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28"}"
: "${hackbench_iterations:=10}"

#####################
#hackbench parameters
#####################
#hackbench_work_type="process threads"
#hackbench_ipc_mode="pipe socket"
hackbench_work_type="threads"
hackbench_ipc_mode="pipe"
hackbench_work_loops=1000000
hackbench_data_size=100
hackbench_max_num_fds=$(($(nproc) / 8))
hackbench_num_fds="2 4 8 16 20"
hackbench_pattern_cmd="grep Time"
hackbench_sleep_time=2
hackbench_log_path=$test_path/logs/hackbench

run_hackbench_pre()
{
	hackbench -g 1 --process --pipe -l 1 -s 1 &> /dev/null
	if [ $? -ne 0 ]; then
		echo "[schedtests]: hackbench not found or version not compatible"
		echo "Usage: hackbench [-p|--pipe] [-s|--datasize <bytes>] [-l|--loops <num loops>]"
		echo "                 [-g|--groups <num groups] [-f|--fds <num fds>]"
		echo "                 [-T|--threads] [-P|--process] [--help]"
		exit 1
	fi

	# ${A##* } - remove longest leading, keep only the last word)
	last_job=${hackbench_job_list##* }
	tasks=$((last_job * $hackbench_max_num_fds))
	org_open_files=`ulimit -n`
	# increase open file number
	ulimit -n $((tasks + $(nproc) + $org_open_files))

	for job in $hackbench_job_list; do
		for wt in $hackbench_work_type; do
			for im in $hackbench_ipc_mode; do
				for fd in $hackbench_num_fds; do
					mkdir -p $hackbench_log_path/$wt-$im-$fd/$job-groups/$run_name
				done
			done
		done
	done
}

run_hackbench_post()
{
	for job in $hackbench_job_list; do
		for wt in $hackbench_work_type; do
			for im in $hackbench_ipc_mode; do
				for fd in $hackbench_num_fds; do
					log_file=$hackbench_log_path/$wt-$im-$fd/$job-groups/$run_name/hackbench.log
					cat $log_file | $hackbench_pattern_cmd | awk '{print $2}' > \
						$hackbench_log_path/$wt-$im-$fd/$job-groups/$run_name.log
				done
			done
		done
	done

}
run_hackbench_single()
{
	local job=$1
	local wt=$2
	local im=$3
	local iter=$4
	local fd=$5
	if [ $im == "pipe" ]; then
		#perf record -q -ag --realtime=1 -m 256 --count=1000003 -e cycles:pp -o perf-hackbench-$job-$wt-$im-$iter.data -D 10000 -- hackbench -g $job --$wt --$im -l $hackbench_work_loops -s $hackbench_data_size -f $hackbench_num_fds
		hackbench -g $job --$wt --$im -l $hackbench_work_loops -s $hackbench_data_size -f $fd
	elif [ $im == "sockets" ]; then
		#perf record -q -ag --realtime=1 -m 256 --count=1000003 -e cycles:pp -o perf-hackbench-$job-$wt-$im-$iter.data -D 10000 -- hackbench -g $job --$wt -l $hackbench_work_loops -s $hackbench_data_size -f $hackbench_num_fds
		hackbench -g $job --$wt -l $hackbench_work_loops -s $hackbench_data_size -f $fd
	else
		echo "hackbench: wrong IPC mode!"
	fi
	#perf report  --children --header -U -g folded,0.5,callee --sort=dso,symbol -i perf-hackbench-$job-$wt-$im-$iter.data > perf-profile-hackbench-$job-$wt-$im-$iter.log
	#rm -rf perf-hackbench-$job-$wt-$im-$iter.data
}

run_hackbench_iterations()
{
	local job=$1
	local wt=$2
	local im=$3
	local fd=$4

	#. $test_path/monitor.sh
	for i in $(seq 1 $hackbench_iterations); do
		echo "Group:" $job " - Type:" $wt " - Mode:" $im " - Iterations:" $i
	#	run_ftrace 4 $hackbench_log_path/$wt-$im/group-$job/$run_name-ftrace.log &
		#dmesg -c
		#cat /proc/schedstat | grep cpu >> $hackbench_log_path/$wt-$im/group-$job/$run_name-schedstat_before.log
		#cat /proc/version
		#dmesg -c | awk '(NR>1)' | awk -F ']' '{ print $2 }' >> $hackbench_log_path/$wt-$im/group-$job/$run_name-sis_nr_before.log
		run_hackbench_single $job $wt $im $i $fd >> $hackbench_log_path/$wt-$im-$fd/$job-groups/$run_name/hackbench.log
		#echo "Group:"$job" - Type:"$wt" - Mode:"$im" - Iterations:"$i >> hackbench_process.log
		#sudo scp hackbench_process.log chenyu-dev:~/
		#cat /proc/schedstat | grep cpu >> $hackbench_log_path/$wt-$im/group-$job/$run_name-schedstat_after.log
		#cat /proc/version
		#dmesg -c | awk '(NR>1)' | awk -F ']' '{ print $2 }' >> $hackbench_log_path/$wt-$im/group-$job/$run_name-sis_nr_after.log
		sleep 1
		sync
	done
}

run_hackbench()
{
	for job in $hackbench_job_list; do
		for wt in $hackbench_work_type; do
			for im in $hackbench_ipc_mode; do
				for fd in $hackbench_num_fds; do
					echo "hackbench: wait 10 seconds for the next case"
					sleep $hackbench_sleep_time
					sync
					run_hackbench_iterations $job $wt $im $fd
				done
			done
		done
	done
	echo -e "\nhackbench testing completed"
}

run_hackbench_pre
run_hackbench
run_hackbench_post
