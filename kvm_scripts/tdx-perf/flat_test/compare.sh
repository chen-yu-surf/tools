#!/usr/bin/env bash
# compare.sh — Compare two flat_pick_bench.sh CSV result files.
#
# Benchmarks with "lower is better" semantics: hackbench, schbench, perf_msg,
# perf_pipe, cyclictest. Speedup = base/flat (>1 = flat is better).
#
# Benchmarks with "higher is better" semantics: sysbench, stressng_fork,
# stressng_ctx. Speedup = flat/base (>1 = flat is better).
#
# Usage: ./compare.sh results_<unpatched>.csv results_<patched>.csv
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 results_base.csv results_flat.csv"; exit 1; }

LOWER_BETTER="hackbench|schbench|perf_msg|perf_pipe|cyclictest"
HIGHER_BETTER="sysbench|stressng_fork|stressng_ctx"

median() {
	awk -F, 'NR>1 && $6!="NA"{ k=$2"|"$3; a[k]=a[k]" "$6 }
	END{ for (k in a){ n=split(a[k],v," "); asort(v); print k, v[int((n+1)/2)] } }' "$1" \
	| sort
}

echo "============================================================"
echo " Comparison: $(basename "$1") vs $(basename "$2")"
echo "============================================================"
printf "%-15s %-7s %-12s %-12s %s\n" "BENCH" "DEPTH" "BASE" "FLAT" "SPEEDUP"
echo "------------------------------------------------------------"

join -j1 <(median "$1") <(median "$2") \
| sort \
| awk -v lb="$LOWER_BETTER" -v hb="$HIGHER_BETTER" '{
	split($1,p,"|");
	bench=p[1]; depth=p[2]; base=$2; flat=$3;
	if (base+0 == 0 || flat+0 == 0) { speedup="N/A" }
	else if (match(bench, lb)) { speedup=sprintf("%.2fx", base/flat) }
	else if (match(bench, hb)) { speedup=sprintf("%.2fx", flat/base) }
	else { speedup="?" }
	printf "%-15s %-7s %-12s %-12s %s\n", bench, depth, base, flat, speedup
}'
