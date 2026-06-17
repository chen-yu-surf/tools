#!/usr/bin/env bash
# launch.sh — Launcher / usage guide for the flat-pick test suite.
#
# Prerequisites (install via your distro's package manager):
#   hackbench   — from rt-tests package (or util-linux on some distros)
#   schbench    — https://github.com/chrismason/schbench
#   stress-ng   — apt install stress-ng / dnf install stress-ng
#   sysbench    — apt install sysbench / dnf install sysbench
#   cyclictest  — from rt-tests package
#   perf        — linux-tools-$(uname -r) or perf package
#
# Usage:
#   1. Boot UNPATCHED kernel, run performance benchmark:
#        sudo ./flat_pick_bench.sh
#
#   2. Boot PATCHED kernel, run performance benchmark:
#        sudo ./flat_pick_bench.sh
#
#   3. Compare results:
#        ./compare.sh results_<unpatched-uname>.csv results_<patched-uname>.csv
#
#   4. Run race/correctness tests (on patched kernel):
#        sudo ./flat_race_stress.sh       # general chaos, long-running
#        sudo ./flat_race_targeted.sh     # focused race-condition tests
#
# Environment variable overrides (examples):
#   DEPTHS="1 4 16" RUNS=3 sudo ./flat_pick_bench.sh     # quick run
#   DURATION=300 sudo ./flat_race_stress.sh               # 5-min stress
#   TEST_DUR=30 sudo ./flat_race_targeted.sh              # 30s per test case
#
set -euo pipefail

echo "flat-pick test suite"
echo "===================="
echo
echo "Available scripts:"
echo "  flat_pick_bench.sh    — Performance benchmarks (hackbench, schbench,"
echo "                          perf bench, sysbench, stress-ng, cyclictest)"
echo "  flat_race_stress.sh   — General chaos/race stress test"
echo "  flat_race_targeted.sh — Targeted race condition tests (8 cases)"
echo "  compare.sh            — Compare two benchmark CSV files"
echo
echo "Required tools:"
for cmd in hackbench schbench stress-ng sysbench cyclictest perf; do
	if command -v "$cmd" >/dev/null 2>&1; then
		printf "  %-12s  OK (%s)\n" "$cmd" "$(command -v "$cmd")"
	else
		printf "  %-12s  MISSING\n" "$cmd"
	fi
done
echo
echo "Run 'sudo ./flat_pick_bench.sh' to start benchmarking."
