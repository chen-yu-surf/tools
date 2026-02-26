#!/bin/bash

logfile="stat_kvmexit.log"

if [ $# -lt 3 ]; then
	echo "Usage: $0 start_time sample_time test_path [log_name]"
	exit 1
fi

start=$1
sample=$2
test_path=$3

if [ ! -z "$4" ] ; then
	logfile=$4
fi

send_ctrl_d() {
	sleep $sample
	pkill -f -SIGINT "bpftrace"
}

sleep $start
send_ctrl_d &

# please refer to arch/x86/include/uapi/asm/vmx.h
bpftrace ${test_path}/kvmexit.bt > $logfile

