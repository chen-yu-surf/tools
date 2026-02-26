#!/bin/bash

logfile="flamegraph.svg"

if [ $# -lt 4 ]; then
	echo "Usage: $0 start_time sample_time test_path log_name"
	exit 1
fi

start=$1
sample=$2
test_path=$3
logfile=$4

sleep $start

cd ${test_path}/FlameGraph
perf record -F 99 -a -g -- sleep $sample
perf script | ./stackcollapse-perf.pl > out.perf-folded
./flamegraph.pl out.perf-folded > $logfile
rm -rf out.perf-folded
rm -rf perf.dat
cd -
