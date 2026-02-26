#!/bin/bash

parse_kselftest()
{
	raw_file=$1
	size_pattern="# Verifying TD with extra"
	create_pattern="# Creating VM took"
	destroy_pattern="# Destroying VM took"

	declare -A data

	while IFS= read -r line
	do
		if [[ $line == *"$size_pattern"* ]]; then
			size=${line#*"$size_pattern "}
			size=${size%GB:*}
		fi

		if [[ $line == *"$create_pattern"* ]]; then
			create_time=${line#*"$create_pattern "}
			create_time=${create_time% seconds*}
		fi

		if [[ $line == *"$destroy_pattern"* ]]; then
			destroy_time=${line#*"$destroy_pattern "}
			destroy_time=${destroy_time% seconds*}

			data[$size]="$create_time $destroy_time"
		fi
	done < "$raw_file"

	keys=($(for key in "${!data[@]}"; do echo "$key"; done | sort -n))

	for key in "${keys[@]}"; do
		IFS=' ' read -r -a times <<< "${data[$key]}"
		printf "%-10s\t%-15s\t%-15s\n" "$key" "${times[0]}" "${times[1]}"
	done
}

run_kselftest()
{
	loops=$1
	input_file="tools/testing/selftests/kvm/x86_64/tdx_vm_tests.c"
	backup_file=$input_file".bak"
	temp_file=$input_file".tmp"

	cd $test_path/$KERNEL_SRC
	cp $input_file $backup_file

	printf "%-10s\t%-15s\t%-15s\n" "Size(GB)" "Create Time" "Destroy Time" > $test_path/tdx_vm_kselftest.log
	for ((i=1; i<=loops; i++))
	do
		new_value=$((10 * i))
		cp $backup_file $input_file
		sed "s/uint64_t extra_mem_gb = 10;/uint64_t extra_mem_gb = $new_value;/g" $input_file > $temp_file
		cp $temp_file $input_file
		make TARGETS="kvm" kselftest > $test_path/tdx_vm_kselftest_${new_value}G.log
		parse_kselftest $test_path/tdx_vm_kselftest_${new_value}G.log >> $test_path/tdx_vm_kselftest.log
		echo 3 > /proc/sys/vm/drop_caches
	done

	cp $backup_file $input_file

	rm $temp_file
	rm $backup_file
}
