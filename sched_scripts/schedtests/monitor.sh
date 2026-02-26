#!/bin/bash

run_ftrace()
{
	local sleep_time=$1
	local ftrace_file=$2

	sleep $sleep_time
	echo > /sys/kernel/debug/tracing/trace
	sleep $sleep_time
	cat /sys/kernel/debug/tracing/trace >> $ftrace_file
}
