#!/bin/bash

rela_path=`dirname $0`
test_path=`cd "$rela_path" && pwd`
nrcpu=`nproc --all`
install=0

install_onednn()
{
	if [ -d oneDNN ]; then
		return 1
	fi

	export http_proxy='http://child-prc.intel.com:913';
	export https_proxy='http://child-prc.intel.com:913';
	# apt install cmake
	git clone https://github.com/oneapi-src/oneDNN.git;
	cd oneDNN;
	export DNNL_CPU_RUNTIME=OMP;
	mkdir -p build && cd build;
	cmake ONEDNN_VERBOSE=ON -DCMAKE_BUILD_TYPE=Debug ..;
	make -j$nrcpu;
	cp tests/benchdnn/benchdnn /usr/bin/
	cd ..
}

run_onednn()
{
	CFG_PATH=$test_path/oneDNN/build/tests/benchdnn/inputs/matmul
	# benchdnn --matmul --batch=oneDNN/build/tests/benchdnn/inputs/matmul/perf_matmul_training
	#benchdnn --matmul --batch=$CFG_PATH/perf_matmul_training > $test_path/PREFIX-training.log;
	#sync;
	#benchdnn --matmul --batch=$CFG_PATH/perf_matmul_inference_lb > $test_path/PREFIX-inference-lb.log;
	#sync;
	#benchdnn --matmul --batch=$CFG_PATH/perf_matmul_inference_batched > $test_path/PREFIX-inference-batched.log
	#sync;
	#export OMP_PROC_BIND=true;export OMP_PLACES="{1}";export OMP_NUM_THREADS=1; ONEDNN_VERBOSE=all time benchdnn --matmul --repeats-per-prb=5 -v6 \
	# --ctx-init=1 --ctx-exe=1 --stag=ab --wtag=ab --dtag=ab 1024x4096:4096x1000_n"Alexnet_train:FWD,ip3*1"
	benchdnn --matmul --repeats-per-prb=50 --stag=ab --wtag=ab --dtag=ab 1024x4096:4096x1000_n"Alexnet_train:FWD,ip3*1" > $test_path/PREFIX-matmul.log
	sync;
}

get_total_time() {
	grep -oP 'total: \K[\d.]+(?=s;)' "$1"
}

get_tests_passed() {
	awk -F'[ :]' '/tests:/ { tests=$2 } /passed:/ { passed=$2 } END { print tests, passed }' "$1"
}

calculate_percentage_difference() {
	awk -v a="$1" -v b="$2" 'BEGIN { diff = ((b - a) / a) * 100; printf "%.2f\n", (diff >= 0 ? diff : -diff) }'
}

compare_dnn() {

	log_file_a=$1
	log_file_b=$2

	if [[ ! -e $log_file_a ]] || [[ ! -e $log_file_b ]]; then
		return
	fi

	total_time_a=$(get_total_time "$log_file_a")
	total_time_b=$(get_total_time "$log_file_b")
	tests_passed_a=($(get_tests_passed "$log_file_a"))
	tests_a=${tests_passed_a[0]}
	passed_a=${tests_passed_a[1]}
	tests_passed_b=($(get_tests_passed "$log_file_b"))
	tests_b=${tests_passed_b[0]}
	passed_b=${tests_passed_b[1]}

	if [ "$tests_a" == "$passed_a" ] && [ "$tests_b" == "$passed_b" ]; then
		percentage_difference=$(calculate_percentage_difference "$total_time_a" "$total_time_b")

		label_a=$(basename $log_file_a)
		label_a="${label_a%.*}"

		label_b=$(basename $log_file_b)
		label_b="${label_b%.*}"

		if (( $(echo "$total_time_b > $total_time_a" | bc -l) )); then
			prefix="-"
		else
			prefix="+"
		fi

		printf "%-20s%-30s%-20s\n" " " "$label_a" "$label_b"
		printf "%-20s%-30s%-5s (%s%.2f%%)\n" "Total time" "$total_time_a" "$total_time_b" "$prefix" "$percentage_difference"
	fi

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	if [ "$install" = "1" ]; then
		install_onednn
	else
		run_onednn
	fi
fi
