#!/bin/bash

rela_path=`dirname $0`
test_path=`cd "$rela_path" && pwd`
nrcpu=`nproc --all`
install=0

install_amx()
{
	if [ -d amx ]; then
		return 1
	fi

	export http_proxy='http://child-prc.intel.com:913';
	export https_proxy='http://child-prc.intel.com:913';
	git clone https://github.com/chen-yu-surf/tools.git amx;
	cd amx;
	gcc -O3 -march=native -fno-strict-aliasing amx-test.c -o amx-test -lpthread
	cp amx-test /usr/bin/
	cd -
}

run_amx()
{
	amx-test -d $duration -t $nr_thread -s $bufsize -i 1 > $test_path/PREFIX-amx.log;
	sync;
}

score_amx() {
	grep 'Throughput' $test_path/PREFIX-amx.log | awk -F': ' '{sum += $2} END {print sum}'
}

cal_amx() {
	awk -v a="$1" -v b="$2" 'BEGIN { diff = ((b - a) / a) * 100; printf "%.2f\n", (diff >= 0 ? diff : -diff) }'
}

compare_amx() {

	log_file_a=$1
	log_file_b=$2

	if [[ ! -e $log_file_a ]] || [[ ! -e $log_file_b ]]; then
		return	
	fi

	total_a=$(score_amx "$log_file_a")
	total_b=$(score_amx "$log_file_b")

	percentage_difference=$(cal_amx "$total_a" "$total_b")

	label_a=$(basename $log_file_a)
	label_a="${label_a%.*}"

	label_b=$(basename $log_file_b)
	label_b="${label_b%.*}"

	if (( $(echo "$total_b > $total_a" | bc -l) )); then
		prefix="-"
	else
		prefix="+"
	fi

	printf "%-20s%-30s%-20s\n" " " "$label_a" "$label_b"
	printf "%-20s%-30s%-5s (%s%.2f%%)\n" "Throughput" "$total_a" "$total_b" "$prefix" "$percentage_difference"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	if [ "$install" = "1" ]; then
		install_amx
	else
		run_amx
	fi
fi
