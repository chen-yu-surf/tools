#!/bin/bash

if [ $# -ne 2 ]; then
	echo "Usage: $0 <start> <sample>"
	exit 1
fi

start=$1
sample=$2

declare -A prev_interrupts

capture_interrupts() {
	while read -r line; do
		[[ $line == CPU* ]] && continue

		irq=${line%%:*}
		if [[ $line =~ ^[[:space:]]*([0-9A-Za-z]+):[[:space:]]+([0-9 ]+).* ]]; then
			IFS=' ' read -r -a counts <<< "${BASH_REMATCH[2]}"
		else
			continue
		fi

		for idx in "${!counts[@]}"; do
			key="CPU${idx} IRQ:${irq}"
			current_count=${counts[$idx]}

			if [[ -n ${prev_interrupts[$key]} ]]; then
				delta=$((current_count - prev_interrupts[$key]))

				if ((delta > 0)); then
					echo "$key $delta"
					#echo "$key $delta"
				fi
			fi

			prev_interrupts[$key]=$current_count
		done
	done < <(cat /proc/interrupts)
}

sleep $start
capture_interrupts
 
sleep $sample
capture_interrupts > interrupts_tmp.txt
sort -V interrupts_tmp.txt
rm -f interrupts_tmp.txt
