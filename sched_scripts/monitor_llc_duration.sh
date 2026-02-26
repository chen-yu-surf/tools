#!/bin/bash
if [ $# -ne 2 ]; then
    echo "Usage: $0 <interval_seconds> <process_pid>"
    exit 1
fi
d=$1
p=$2
if ! [[ $d =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: Interval must be a positive integer"
    exit 1
fi
if ! [[ $p =~ ^[1-9][0-9]*$ ]]; then
    exit 1
fi
if [ ! -d "/proc/$p" ]; then
    echo "Error: Process PID $p does not exist"
    exit 1
fi
prev_line=$(cat "/proc/$p/schedstat" | sed -n '2p')
if [ -z "$prev_line" ]; then
    echo "Error: Failed to get schedstat second line for process $p"
    exit 1
fi
while true; do
    sleep $d
    curr_line=$(cat "/proc/$p/schedstat" | sed -n '2p')
    if [ -z "$curr_line" ]; then
        echo "Process $p has ended"
        exit 0
    fi
    prev=($prev_line)
    curr=($curr_line)
    if [ ${#prev[@]} -ne ${#curr[@]} ]; then
        echo "Warning: Data format changed, skipping calculation"
        prev_line=$curr_line
        continue
    fi
    diffs=()
    for ((i=0; i<${#prev[@]}; i++)); do
        diff=$((curr[i] - prev[i]))
        diffs+=($diff)
    done
    echo "${diffs[@]}"
    prev_line=$curr_line
done
