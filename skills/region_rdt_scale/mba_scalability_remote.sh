#!/usr/bin/env bash
#
# mba_scalability_remote.sh
#
# Runs ON the test machine (region-aware RDT kernel booted).
#
# It sweeps the region-aware MBA throttle level of memory Region N (default 0)
# for a dedicated resctrl group "region_mba_test", saturates memory bandwidth
# with Intel MLC, and records for every throttle level:
#     * the memory bandwidth reported by MLC (MB/sec)
#     * the region-N MBM bytes accumulated by the group over a fixed window
#
# For each throttle level the SAME value is written to the region's OPT, MIN
# and MAX controls (MB_REGION<n>_OPT/MIN/MAX). Levels swept: 1, 10, 20, ...
# up to the hardware maximum.
#
# ---------------------------------------------------------------------------
# How the test works (methodology summary)
# ---------------------------------------------------------------------------
# 1. Region-aware MBA controls (MB_REGION<n>_OPT/MIN/MAX) are only exposed when
#    the MB controller is in "native" mode. The script auto-switches
#    /sys/fs/resctrl/info/MB/control_mode to "native" if the region controls
#    are missing but the platform advertises that mode.
#
# 2. It creates a dedicated resctrl control+monitor group "region_mba_test" and
#    moves the running shell into it (echo $$ > group/tasks). MLC is launched
#    as a child of that shell, so it inherits the group and is both THROTTLED
#    by the group's MBA schemata and MONITORED by the group's MBM counters.
#
# 3. Throttle programming (per level): the same integer value is written to
#    every controlled L3/cache domain of Region N, and to all three region
#    controls at once, e.g.
#         MB_REGION<n>_OPT:0=VAL;1=VAL;2=VAL;3=VAL
#         MB_REGION<n>_MIN:0=VAL;1=VAL;2=VAL;3=VAL
#         MB_REGION<n>_MAX:0=VAL;1=VAL;2=VAL;3=VAL
#    OPT=MIN=MAX pins a fixed operating point instead of a range. Only Region N
#    is modified; other regions stay fully open. The domain id list is parsed
#    from the live schemata, and the hardware maximum is auto-detected.
#
# 4. Load generation (bandwidth saturation): MLC is run as
#         [numactl --membind=<node>] mlc --loaded_latency -R -d0 -t<runtime>
#    - loaded_latency with "-d0" (zero inject delay) drives the MAXIMUM request
#      rate, i.e. a single sustained full-saturation phase (this is why
#      --loaded_latency -d0 is used rather than --max_bandwidth, which runs
#      several back-to-back traffic-mix phases that don't align with one MBM
#      sampling window). "-R" = random access.
#    - loaded_latency prints an "Inject Delay | Latency(ns) | Bandwidth(MB/sec)"
#      table; the test parses the BANDWIDTH column (last field), NOT the
#      latency. So the recorded "mlc_MBps" score is achieved memory bandwidth.
#    - numactl --membind binds MLC's buffers to the region's NUMA node (memory
#      only; CPUs are left free because a CXL node usually has no CPUs) so the
#      traffic actually flows through the region being throttled.
#
# 5. Two independent bandwidth measurements are recorded per level:
#    a) mlc_MBps          - the aggregate, system-wide bandwidth MLC reports.
#    b) mbm_region<n>_bytes- the hardware MBM counter for Region N, read as the
#       DELTA over a fixed window: after a warmup (MBM_WARMUP) the per-domain
#       mon_data/mon_L3_*/mbm_region<n>_bytes files are SUMMED across all
#       monitoring domains at the start and end of an MBM_WINDOW-second window;
#       the difference is the region traffic during that window. (It is an
#       aggregate sum across domains, not a per-domain breakdown.)
#    Comparing the two confirms the load really traversed the intended region
#    (e.g. a CXL region only shows non-zero MBM once its node is onlined and
#    MLC is bound to it).
#
# 6. A cleanup trap always restores the region controls to the hardware max
#    (fully open), moves the shell back to the root group, and kills stray MLC.
# ---------------------------------------------------------------------------
#
# Outputs (in the current directory):
#     mba_scalability_region<n>.txt      - human readable summary table
#     mba_scalability_region<n>_mlc.txt  - "throttle_level  mlc_bw_MBps"
#     mba_scalability_region<n>_mbm.txt  - "throttle_level  mbm_region<n>_bytes"
#
# Requirements:
#     * run as root (resctrl + mlc need it), region-aware RDT kernel booted
#     * an Intel MLC binary (provide it yourself; see MLC_BIN below)
#     * numactl (only when NUMA binding is used, which is the default)
#
# Usage:
#     sudo [VAR=VALUE ...] ./mba_scalability_remote.sh
#     ./mba_scalability_remote.sh -h | --help
#
# Examples:
#     # Region 0 (local DRAM / NUMA node 0), mlc binary in the current dir:
#     sudo MLC_BIN=./mlc REGION=0 ./mba_scalability_remote.sh
#
#     # Region 1 (e.g. a CXL node); bind MLC memory to NUMA node 1:
#     sudo MLC_BIN=./mlc REGION=1 NUMA_NODE=1 ./mba_scalability_remote.sh
#
#     # Quicker sweep (finer start, coarser step, shorter runs):
#     sudo MLC_BIN=/opt/mlc/mlc REGION=0 THROTTLE_START=1 THROTTLE_STEP=20 \
#          MLC_RUNTIME=15 MBM_WINDOW=8 ./mba_scalability_remote.sh
#
#     # Disable NUMA binding (let MLC use default local allocation):
#     sudo MLC_BIN=./mlc REGION=0 NUMA_NODE=-1 ./mba_scalability_remote.sh
#
# Then plot the region 0 result with the bundled plotter:
#     ./plot_mba_scalability.py \
#         --mlc mba_scalability_region0_mlc.txt \
#         --mbm mba_scalability_region0_mbm.txt
#
# Preparing a CXL node before a region-1 (CXL) sweep:
#     A CXL memory expander is usually surfaced as its own cpu-less NUMA node
#     (e.g. node 1). If that memory is offline, MLC has nothing to allocate on
#     the node and the region-1 sweep stays flat with mbm_region1 == 0, because
#     no traffic ever reaches the region. Bring the node online first.
#
#     1. Find the CXL node id. It is the target_node of the CXL/dax device and
#        typically the only node with memory but no CPUs:
#            numactl -H                       # look for a "node N ... 0 MB" node
#            cat /sys/bus/dax/devices/dax*/target_node   2>/dev/null
#            cxl list -M                      # if the cxl tools are installed
#
#     2a. Preferred (if daxctl/ndctl are installed) - convert the devdax device
#         to system-ram so it becomes an onlined NUMA node:
#            daxctl reconfigure-device --mode=system-ram --online dax0.0
#
#     2b. Pure sysfs fallback (no extra tools needed) - online every offline
#         memory block that belongs to the CXL node (replace node1 as needed):
#            for s in /sys/devices/system/node/node1/memory*/state; do
#                [ "$(cat "$s")" = offline ] && echo online > "$s"
#            done
#         (Use "online_movable" instead of "online" if you want the capacity in
#          ZONE_MOVABLE; plain "online" -> ZONE_NORMAL works for MLC.)
#
#     3. Verify the node now reports its capacity, then run the sweep bound to it:
#            numactl -H | grep -A1 "node 1"   # node 1 size should be non-zero
#            sudo MLC_BIN=./mlc REGION=1 NUMA_NODE=1 ./mba_scalability_remote.sh
#
#     Note: some CXL parts front the media with a DRAM "extended linear cache",
#     so the measured bandwidth can look DRAM-like; the MBM counter still
#     attributes the traffic to the CXL region, which is what this test checks.
#
# SPDX-License-Identifier: GPL-2.0

set -uo pipefail

#############################################################################
# Configuration (overridable via environment)
#############################################################################
RESCTRL="/sys/fs/resctrl"
GROUP_NAME="region_mba_test"
GROUP="${RESCTRL}/${GROUP_NAME}"
REGION="${REGION:-0}"
# NUMA node whose memory MLC should allocate from (mlc -j<node>). By default it
# mirrors the region index (region0->node0, region1->node1, ...) so that the
# generated traffic actually targets the memory backing that region (e.g.
# region1 == the CXL node). Set NUMA_NODE=-1 (or empty) to let MLC use its
# default local allocation instead of binding.
NUMA_NODE="${NUMA_NODE-${REGION}}"
MLC_BIN="${MLC_BIN:-./mlc}"
THROTTLE_START="${THROTTLE_START:-1}"
THROTTLE_STEP="${THROTTLE_STEP:-10}"
MLC_RUNTIME="${MLC_RUNTIME:-25}"     # seconds mlc runs per throttle level
MBM_WARMUP="${MBM_WARMUP:-5}"        # seconds to let mlc ramp up before sampling
MBM_WINDOW="${MBM_WINDOW:-10}"       # seconds MBM sampling window

# Output files are tagged with the region index so sweeps of different regions
# do not overwrite each other. Override OUT_PREFIX to change the naming.
OUT_PREFIX="${OUT_PREFIX:-mba_scalability_region${REGION}}"
OUT_SUMMARY="${OUT_PREFIX}.txt"
OUT_MLC="${OUT_PREFIX}_mlc.txt"
OUT_MBM="${OUT_PREFIX}_mbm.txt"

OPT_CTRL="MB_REGION${REGION}_OPT"
MIN_CTRL="MB_REGION${REGION}_MIN"
MAX_CTRL="MB_REGION${REGION}_MAX"
MBM_FILE="mbm_region${REGION}_bytes"

log()  { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[-] %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
	cat <<EOF
Region-aware MBA scalability test.

Usage:
  sudo [VAR=VALUE ...] $0
  $0 -h | --help

Configuration (environment variables, all optional):
  REGION=$REGION            Memory region index controlled/monitored
  NUMA_NODE=$NUMA_NODE          NUMA node MLC allocates from (-1/empty = no binding)
  MLC_BIN=$MLC_BIN         Path to the Intel MLC binary (user-provided)
  THROTTLE_START=$THROTTLE_START         First throttle level
  THROTTLE_STEP=$THROTTLE_STEP         Step between throttle levels
  MLC_RUNTIME=$MLC_RUNTIME         Seconds MLC runs per level
  MBM_WARMUP=$MBM_WARMUP           Seconds to let MLC ramp before sampling
  MBM_WINDOW=$MBM_WINDOW          MBM sampling window (seconds)
  OUT_PREFIX=$OUT_PREFIX

Examples:
  # Region 0 (local DRAM / NUMA node 0), mlc in the current dir:
  sudo MLC_BIN=./mlc REGION=0 $0

  # Region 1 (e.g. a CXL node); bind MLC memory to NUMA node 1:
  sudo MLC_BIN=./mlc REGION=1 NUMA_NODE=1 $0

  # Quicker sweep:
  sudo MLC_BIN=./mlc REGION=0 THROTTLE_STEP=20 MLC_RUNTIME=15 $0

Plot the result afterwards:
  ./plot_mba_scalability.py \\
      --mlc ${OUT_PREFIX}_mlc.txt --mbm ${OUT_PREFIX}_mbm.txt
EOF
}

case "${1:-}" in
	-h|--help) usage; exit 0 ;;
esac

#############################################################################
# Preconditions
#############################################################################
[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root."
[[ -x "${MLC_BIN}" ]] || die "mlc binary not found/executable at ${MLC_BIN}"

# Load msr driver required by mlc for prefetcher control.
modprobe msr 2>/dev/null || true

# Build the MLC memory-binding launch prefix. MLC's own "-j<node>" flag is
# unreliable for loaded_latency (it is silently ignored on some builds), so we
# force allocation onto the region's NUMA node with "numactl --membind". Only
# memory is bound; CPUs are left free because a CXL node typically has no CPUs
# of its own (threads run on node0 and access node1 memory across the link).
MLC_NUMA_PREFIX=""
if [[ -n "${NUMA_NODE}" && "${NUMA_NODE}" =~ ^[0-9]+$ ]]; then
	if ! command -v numactl >/dev/null 2>&1; then
		warn "numactl not found; cannot bind MLC memory to node ${NUMA_NODE}. Traffic may not reach region ${REGION}. Install numactl."
	else
		node_memkb="$(awk '/MemTotal/{print $4}' "/sys/devices/system/node/node${NUMA_NODE}/meminfo" 2>/dev/null)"
		if [[ -z "${node_memkb}" || "${node_memkb}" -eq 0 ]]; then
			warn "NUMA node ${NUMA_NODE} has 0 kB online memory; 'numactl --membind=${NUMA_NODE}' will fail. Online that node's memory first."
		else
			MLC_NUMA_PREFIX="numactl --membind=${NUMA_NODE}"
			log "MLC memory bound to NUMA node ${NUMA_NODE} via '${MLC_NUMA_PREFIX}'; node has ${node_memkb} kB online"
		fi
	fi
else
	log "MLC memory allocation not NUMA-bound (using default local allocation)"
fi

# Mount resctrl if not already mounted.
if ! mountpoint -q "${RESCTRL}"; then
	log "Mounting resctrl at ${RESCTRL}"
	mkdir -p "${RESCTRL}"
	mount -t resctrl resctrl "${RESCTRL}" || die "Failed to mount resctrl"
	MOUNTED_BY_US=1
else
	MOUNTED_BY_US=0
fi

# Region-aware MBA controls (MB_REGION<n>_OPT/MIN/MAX) are only exposed when the
# MB controller is switched from the classic "legacy" mode into "native" mode on
# platforms that support them. If the region control is missing but the platform
# lists "native" as an available mode, enable it automatically so the test is
# portable across machines without a manual setup step.
CTRL_MODE_FILE="${RESCTRL}/info/MB/control_mode"
if ! grep -q "^${MAX_CTRL}:" "${RESCTRL}/schemata" \
	&& [[ -w "${CTRL_MODE_FILE}" ]] \
	&& grep -qw "native" "${CTRL_MODE_FILE}" \
	&& ! grep -q "\[native\]" "${CTRL_MODE_FILE}"; then
	log "Enabling region-aware MBA (native control_mode)"
	echo native > "${CTRL_MODE_FILE}" 2>/dev/null \
		|| warn "Failed to set native control_mode at ${CTRL_MODE_FILE}"
fi

# Verify region-aware MBA is available.
if ! grep -q "^${MAX_CTRL}:" "${RESCTRL}/schemata"; then
	die "Region-aware MBA control '${MAX_CTRL}' not present in ${RESCTRL}/schemata. Is the region-aware RDT kernel booted and does the platform expose region ${REGION}? (Tried enabling native control_mode automatically.)"
fi

#############################################################################
# Determine the hardware maximum throttle value.
#   Prefer the info 'max' property file; fall back to the default (root)
#   schemata value which is the fully-open (max) setting after mount.
#############################################################################
MAXVAL=""
max_file="$(ls "${RESCTRL}"/info/MB/schemata/*"REGION${REGION}_MAX"*/max 2>/dev/null | head -n1 || true)"
if [[ -n "${max_file}" && -r "${max_file}" ]]; then
	MAXVAL="$(cat "${max_file}")"
fi
if [[ -z "${MAXVAL}" ]]; then
	# Largest value among the domains on the default group schemata line.
	MAXVAL="$(grep "^${MAX_CTRL}:" "${RESCTRL}/schemata" \
		| sed "s/^${MAX_CTRL}://" \
		| tr ';' '\n' | cut -d= -f2 | sort -n | tail -n1)"
fi
[[ -n "${MAXVAL}" && "${MAXVAL}" =~ ^[0-9]+$ ]] || die "Could not determine region MBA maximum value"
log "Region ${REGION} MBA maximum throttle value = ${MAXVAL}"

#############################################################################
# Create the test group and move this shell into it so mlc inherits it.
#############################################################################
if [[ ! -d "${GROUP}" ]]; then
	log "Creating resctrl group ${GROUP_NAME}"
	mkdir "${GROUP}" || die "Failed to create ${GROUP}"
fi

log "Assigning current shell (pid $$) to ${GROUP_NAME}"
echo $$ > "${GROUP}/tasks" || die "Failed to assign shell to group"

# Cache-id list for the region control, parsed from the group's schemata.
CACHE_IDS="$(grep "^${MAX_CTRL}:" "${GROUP}/schemata" \
	| sed "s/^${MAX_CTRL}://" | tr ';' '\n' | cut -d= -f1 | tr '\n' ' ')"
[[ -n "${CACHE_IDS}" ]] || die "Could not parse cache ids from ${GROUP}/schemata"
log "Region ${REGION} controlled cache/domain ids: ${CACHE_IDS}"

#############################################################################
# Cleanup handler: restore full bandwidth, move shell back to root group.
#############################################################################
cleanup() {
	set +e
	# Move this shell back to the default group before removing our group.
	echo $$ > "${RESCTRL}/tasks" 2>/dev/null
	if [[ -d "${GROUP}" ]]; then
		# Restore the region controls to the maximum (fully open).
		write_region_level "${MAXVAL}" 2>/dev/null
	fi
	# Kill any stray mlc we launched.
	pkill -P $$ mlc 2>/dev/null
}
trap cleanup EXIT INT TERM

#############################################################################
# Helpers
#############################################################################

# Build "id0=VAL;id1=VAL;..." for all cache ids.
build_line() {
	local val="$1" out=""
	local id
	for id in ${CACHE_IDS}; do
		out+="${id}=${val};"
	done
	echo "${out%;}"
}

# Write the same throttle level to OPT, MIN and MAX for the region.
write_region_level() {
	local val="$1"
	local body
	body="$(build_line "${val}")"
	echo "${OPT_CTRL}:${body}" > "${GROUP}/schemata" || return 1
	echo "${MIN_CTRL}:${body}" > "${GROUP}/schemata" || return 1
	echo "${MAX_CTRL}:${body}" > "${GROUP}/schemata" || return 1
	return 0
}

# Sum the region MBM byte counters across all L3 monitoring domains.
read_mbm_region_bytes() {
	local total=0 v f found=0
	for f in "${GROUP}"/mon_data/mon_L3_*/"${MBM_FILE}"; do
		[[ -r "${f}" ]] || continue
		v="$(cat "${f}" 2>/dev/null)"
		# Skip non-numeric readings (e.g. "Unavailable"/"Unassigned").
		[[ "${v}" =~ ^[0-9]+$ ]] || continue
		total=$(( total + v ))
		found=1
	done
	[[ "${found}" -eq 1 ]] || { echo ""; return 1; }
	echo "${total}"
}

# Parse the bandwidth (MB/sec) from an mlc --loaded_latency -R -d0 log.
parse_mlc_bw() {
	local logf="$1"
	awk '/^[= ]*={5,}/{sep=1; next} sep && $0 ~ /[0-9]/ {print $NF; exit}' "${logf}"
}

#############################################################################
# Build the list of throttle levels: START, STEP, 2*STEP, ... , MAXVAL
#############################################################################
declare -a LEVELS=()
LEVELS+=("${THROTTLE_START}")
v=${THROTTLE_STEP}
while (( v < MAXVAL )); do
	LEVELS+=("${v}")
	v=$(( v + THROTTLE_STEP ))
done
# Ensure the hardware max is the final point.
if [[ "${LEVELS[-1]}" != "${MAXVAL}" ]]; then
	LEVELS+=("${MAXVAL}")
fi
log "Throttle levels to test: ${LEVELS[*]}"

#############################################################################
# Prepare output files
#############################################################################
{
	echo "# Region-aware MBA scalability test"
	echo "# region=${REGION} mlc_numa_node=${NUMA_NODE} mlc_runtime=${MLC_RUNTIME}s mbm_window=${MBM_WINDOW}s"
	echo "# columns: throttle_level : mlc_bandwidth_MBps : mbm_region${REGION}_bytes(over ${MBM_WINDOW}s window)"
	printf '%-14s %-22s %-24s\n' "throttle" "mlc_MBps" "mbm_region${REGION}_bytes"
} > "${OUT_SUMMARY}"
: > "${OUT_MLC}"
: > "${OUT_MBM}"

#############################################################################
# Main sweep
#############################################################################
for level in "${LEVELS[@]}"; do
	log "=== Throttle level ${level} (max ${MAXVAL}) ==="

	if ! write_region_level "${level}"; then
		warn "Failed to set throttle level ${level}; last_cmd_status:"
		cat "${RESCTRL}/info/last_cmd_status" 2>/dev/null | sed 's/^/    /'
		continue
	fi
	# Show what was actually programmed.
	grep "^MB_REGION${REGION}_" "${GROUP}/schemata" | sed 's/^/    /'

	# Launch mlc to saturate memory bandwidth with 100% reads at max rate.
	# It is a child of this shell, so it inherits the region_mba_test group.
	mlc_log="mlc_out_level_${level}.log"
	${MLC_NUMA_PREFIX} "${MLC_BIN}" --loaded_latency -R -d0 -t"${MLC_RUNTIME}" > "${mlc_log}" 2>&1 &
	mlc_pid=$!

	# Let mlc ramp up to steady-state bandwidth.
	sleep "${MBM_WARMUP}"

	# Sample MBM across a fixed window while mlc keeps memory saturated.
	b1="$(read_mbm_region_bytes)" || { warn "MBM read failed"; b1=""; }
	sleep "${MBM_WINDOW}"
	b2="$(read_mbm_region_bytes)" || { warn "MBM read failed"; b2=""; }

	if [[ -n "${b1}" && -n "${b2}" ]]; then
		mbm_bytes=$(( b2 - b1 ))
	else
		mbm_bytes=0
	fi

	# Wait for mlc to finish and read its reported bandwidth.
	wait "${mlc_pid}" 2>/dev/null
	mlc_bw="$(parse_mlc_bw "${mlc_log}")"
	[[ -n "${mlc_bw}" ]] || mlc_bw="0"

	log "level=${level}  mlc=${mlc_bw} MB/sec  mbm_region${REGION}=${mbm_bytes} bytes/${MBM_WINDOW}s"

	printf '%-14s %-22s %-24s\n' "${level}" "${mlc_bw}" "${mbm_bytes}" >> "${OUT_SUMMARY}"
	printf '%s %s\n' "${level}" "${mlc_bw}"   >> "${OUT_MLC}"
	printf '%s %s\n' "${level}" "${mbm_bytes}" >> "${OUT_MBM}"
done

log "Sweep complete. Results:"
echo "----------------------------------------"
cat "${OUT_SUMMARY}"
echo "----------------------------------------"
log "Wrote ${OUT_SUMMARY}, ${OUT_MLC}, ${OUT_MBM}"
