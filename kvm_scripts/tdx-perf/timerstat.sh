#!/bin/bash

logfile="stat_timer.log"

if [ $# -lt 2 ]; then
	echo "Usage: $0 start_time sample_time [log_name]"
	exit 1
fi

if [ ! -z "$3" ] ; then
	logfile=$3
fi

start=$1
sample=$2


send_ctrl_d() {
	sleep $sample
	pkill -f -SIGINT "bpftrace"
}

sleep $start
send_ctrl_d &

bpftrace timer.bt > $logfile
tmp_logfile="tmp_log"

while IFS= read -r line
do
	if [[ $line == *'['*']'* ]]; then
		hex_addr=$(echo $line | grep -oP '\[\K[^]]*')
		real_hex_addr=${hex_addr#0x}
		kernel_symbol=$(grep $real_hex_addr /proc/kallsyms | awk '{print $3}')
		new_line=${line/\[$hex_addr\]/\[$kernel_symbol\]}
		echo $new_line >> $tmp_logfile
	fi
done < $logfile

mv $tmp_logfile $logfile
