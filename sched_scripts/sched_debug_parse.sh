cat /sys/kernel/debug/sched/debug | grep 'avg_ilb_cost'  | awk -F ':' '{print $2}' > avg_ilb_cost.txt ; awk '{s+=$1} END {print s}' avg_ilb_cost.txt
cat /sys/kernel/debug/sched/debug | grep 'avg_idle'  | awk -F ':' '{print $2}' > avg_idle.txt ; awk '{s+=$1} END {print s}' avg_idle.txt
