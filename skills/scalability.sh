#!/usr/bin/env bash
#
# scalability.sh
#
# Region-aware (native) MBA scalability test. Runs ON the test machine.
# Sweeps a list of throttle levels for the "region_mba_test" resctrl group,
# saturates memory bandwidth with Intel MLC and, for each level, records:
#     * the memory bandwidth MLC reports (MB/sec)
#     * the region MBM bytes the group accumulates over a fixed window
#
# Usage:
#     sudo ./scalability.sh
#     sudo LEVELS="1 10 20 30 40 50" REGION=0 ./scalability.sh
#
# SPDX-License-Identifier: GPL-2.0

set -uo pipefail

RESCTRL="/sys/fs/resctrl"
GROUP_NAME="region_mba_test"
GROUP="${RESCTRL}/${GROUP_NAME}"
REGION="${REGION:-0}"
CTRL="MB_REGION${REGION}_OPT"
MBM_FILE="mbm_region${REGION}_bytes"
MLC="${MLC:-/home/chenyu5/mlc}"
NUMA_NODE="${NUMA_NODE:-${REGION}}"

# Throttle levels to sweep (space separated, valid range 1-255).
LEVELS="${LEVELS:-1 2 4 8 10 12 14 16 18 20 22 24 30 40 45 50}"

# Timing (seconds). MLC_WARMUP + MBM_WINDOW must stay below MLC_RUNTIME.
MLC_RUNTIME="${MLC_RUNTIME:-8}"
MLC_WARMUP="${MLC_WARMUP:-2}"
MBM_WINDOW="${MBM_WINDOW:-3}"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
[[ -x "${MLC}" ]] || { echo "mlc not found/executable at ${MLC}" >&2; exit 1; }

modprobe msr 2>/dev/null || true
mountpoint -q "${RESCTRL}" || mount -t resctrl resctrl "${RESCTRL}"
echo native > "${RESCTRL}/info/MB/control_mode"
mkdir -p "${GROUP}"
echo $$ > "${GROUP}/tasks"

printf '%-10s %-14s %-22s\n' throttle mlc_MBps "${MBM_FILE}/${MBM_WINDOW}s"
for L in ${LEVELS}; do
	if ! echo "${CTRL}:0=${L};1=${L};2=${L};3=${L}" > "${GROUP}/schemata"; then
		echo "write level ${L} FAILED:"
		cat "${RESCTRL}/info/last_cmd_status"
		continue
	fi
	numactl --membind="${NUMA_NODE}" "${MLC}" --loaded_latency -R -d0 -t"${MLC_RUNTIME}" \
		> "/tmp/mlc_${L}.log" 2>&1 &
	pid=$!
	sleep "${MLC_WARMUP}"
	b1=0; for f in "${GROUP}"/mon_data/mon_L3_*/"${MBM_FILE}"; do
		v=$(cat "$f" 2>/dev/null); [[ $v =~ ^[0-9]+$ ]] && b1=$((b1+v))
	done
	sleep "${MBM_WINDOW}"
	b2=0; for f in "${GROUP}"/mon_data/mon_L3_*/"${MBM_FILE}"; do
		v=$(cat "$f" 2>/dev/null); [[ $v =~ ^[0-9]+$ ]] && b2=$((b2+v))
	done
	wait "${pid}"
	bw=$(awk '/^[= ]*={5,}/{s=1;next} s && /[0-9]/{print $NF; exit}' "/tmp/mlc_${L}.log")
	printf '%-10s %-14s %-22s\n' "${L}" "${bw:-0}" "$((b2-b1))"
done

# Restore full bandwidth and move this shell back to the root group.
echo "${CTRL}:0=255;1=255;2=255;3=255" > "${GROUP}/schemata"
echo $$ > "${RESCTRL}/tasks"
echo DONE
