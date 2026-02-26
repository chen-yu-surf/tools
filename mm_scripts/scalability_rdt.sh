#!/bin/bash

mkdir -p /sys/fs/resctrl/mytest

echo 3f > /sys/fs/resctrl/mytest/cpus
echo $$ > /sys/fs/resctrl/mytest/tasks

rm -rf *.log

stress-ng -C 4 &
STRESS_PID=$!
sleep 2

for ((n=1; n<=40; n+=1)); do
	echo "MB_REGION0:0=$n" > /sys/fs/resctrl/mytest/schemata
	/root/chenyu/Linux/mlc --max_bandwidth > bw_mba_resctrl_$n.log
	all_reads=$(grep 'ALL Reads' bw_mba_resctrl_$n.log | awk -F '[[:space:]]+' '{print $4}')
	echo "$n $all_reads" >> bw_1_40_resctrl_total.log
done
echo "MBA test completed! Results saved to bw_1_40_resctrl_total.log"

current_cbm=$((0x3ff))
target_cbm=$((0x200))
while [ $current_cbm -ge $target_cbm ]; do
    hex_n=$(printf "%x" $current_cbm)

    echo "L3:0=0x${hex_n}" > /sys/fs/resctrl/mytest/schemata
    sleep 1

    if [ -f "/sys/fs/resctrl/mytest/mon_data/mon_L3_00/llc_occupancy" ]; then
        llc=$(cat /sys/fs/resctrl/mytest/mon_data/mon_L3_00/llc_occupancy)
        echo "0x${hex_n} ${llc}" >> cat_1_10_resctrl_total.log
        echo "Configured CBM=0x${hex_n}, LLC occupancy=${llc}"
    else
        echo "0x${hex_n} ERROR: mon_data file not found" >> cat_1_10_resctrl_total.log
        echo "Warning: LLC monitoring file not found, check if resctrl is mounted with mon_data!"
    fi

if ps -p $STRESS_PID > /dev/null; then
    kill -9 $STRESS_PID
fi
pkill -9 stress-ng 2>/dev/null

echo "CAT test completed! Results saved to cat_1_10_resctrl_total.log"

: <<'EOF'
export LD_LIBRARY_PATH=lib

./pqos/pqos --iface=msr -a "cos:1=0"
./pqos/pqos --iface=msr -a "cos:1=1"
./pqos/pqos --iface=msr -a "cos:1=2"
./pqos/pqos --iface=msr -a "cos:1=3"
./pqos/pqos --iface=msr -a "cos:1=4"
./pqos/pqos --iface=msr -a "cos:1=5"

rm -rf bw_1_40_pqos_total.log

for ((n=1; n<=40; n+=1)); do
        hex_n=$(printf "%x" $n)
        ./pqos/pqos --iface=mmio --alloc-domain-id=0 --alloc-mem-region=0 -e "mba:1=0x$hex_n"
        /root/chenyu/Linux/mlc --max_bandwidth > bw_mba_pqos_$n.log
        all_reads=$(grep 'ALL Reads' bw_mba_pqos_$n.log | awk -F '[[:space:]]+' '{print $4}')
        echo "$n $all_reads" >> bw_1_40_pqos_total.log
done
EOF
