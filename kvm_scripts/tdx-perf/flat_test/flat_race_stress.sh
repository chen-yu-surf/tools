#!/usr/bin/env bash
# flat_race_stress.sh — Concurrency / race stress test for the EEVDF flat-pick
# series ("sched/eevdf: Move to a single runqueue").
#
# Uses REAL benchmarks (hackbench, stress-ng, sysbench) as load generators
# while continuously mutating the cgroup hierarchy and task state to trip
# race-sensitive invariants:
#
#   - cfs_rq->h_curr set/clear in set_next_entity()/put_prev_entity()
#   - __enqueue_entity() root+task-only WARNs
#   - reweight_eevdf() rb-tree re-insert + h_nr_queued bracketing
#   - put_prev_task_fair() dual-walk (cfs_rq->curr vs h_curr)
#   - task_change_group_fair() detach/re-attach while curr or sched_delayed
#   - enqueue_hierarchy() __calc_prop_weight with changing cfs_rq->load
#   - unregister_fair_sched_group() concurrent with running tasks
#   - h_nr_queued/h_nr_runnable accounting across throttle/unthrottle
#   - requeue_delayed_entity() with concurrent cgroup migration
#
# PASS/FAIL: kernel log. Any new WARNING/BUG/stall from sched code = FAIL.
#
# Required tools: hackbench, stress-ng, sysbench (warns and degrades if missing)
# Optional tools: perf
set -uo pipefail

# ---- tunables (override via env) -------------------------------------------
DURATION=${DURATION:-120}              # seconds of total chaos
LEAVES=${LEAVES:-8}                    # leaf cgroups tasks bounce between
MAXDEPTH=${MAXDEPTH:-6}                # max nesting depth
DEEP_DEPTH=${DEEP_DEPTH:-32}           # extra-deep cgroup for worst-case walk
HOTPLUG=${HOTPLUG:-0}                  # 1 = also offline/online CPUs (disruptive!)
OPRATE_MS=${OPRATE_MS:-10}             # base sleep between chaos ops (ms)

CG=/sys/fs/cgroup
ROOT=$CG/flatrace
KLOG=/tmp/flat_race_kmsg.$$
# ----------------------------------------------------------------------------

[[ $(id -u) == 0 ]] || { echo "ERROR: run as root"; exit 1; }
[[ -e $CG/cgroup.controllers ]] || { echo "ERROR: need cgroup v2"; exit 1; }
grep -qw cpu "$CG/cgroup.controllers" || { echo "ERROR: cpu controller unavailable"; exit 1; }

ONLINE_CPUS=$(nproc)
declare -a LEAFDIRS=()
declare -a LOAD_PIDS=()
STOP=0

msleep() {
	local ms=$1
	sleep "$(awk "BEGIN{printf \"%.4f\", ($ms + int(rand()*$ms))/1000}")"
}
rand() { echo $(( RANDOM % $1 )); }

build_hierarchy() {
	mkdir -p "$ROOT"
	echo "+cpu" > "$ROOT/cgroup.subtree_control" 2>/dev/null || true

	for ((i=0; i<LEAVES; i++)); do
		local d=$(( 1 + $(rand "$MAXDEPTH") ))
		local p="$ROOT"
		for ((j=1; j<=d; j++)); do
			p="$p/g${i}_l${j}"
			mkdir -p "$p"
			(( j < d )) && echo "+cpu" > "$p/cgroup.subtree_control" 2>/dev/null || true
		done
		LEAFDIRS+=("$p")
	done

	# Extra-deep chain
	local p="$ROOT"
	for ((j=1; j<=DEEP_DEPTH; j++)); do
		p="$p/deep_l${j}"
		mkdir -p "$p"
		(( j < DEEP_DEPTH )) && echo "+cpu" > "$p/cgroup.subtree_control" 2>/dev/null || true
	done
	LEAFDIRS+=("$p")
}

# ---- workload generators using real benchmarks -----------------------------
start_load() {
	local leaf

	# 1) hackbench — heavy context-switch + IPC workload (runs in a loop)
	if command -v hackbench >/dev/null; then
		leaf=${LEAFDIRS[$(rand ${#LEAFDIRS[@]})]}
		(
			echo $BASHPID > "$leaf/cgroup.procs" 2>/dev/null
			while [[ -e "$KLOG.run" ]]; do
				hackbench -pipe -g "$ONLINE_CPUS" -l 5000 >/dev/null 2>&1 || true
			done
		) &
		LOAD_PIDS+=($!)
	fi

	# 2) stress-ng --cpu — CPU-bound workers that tick frequently
	if command -v stress-ng >/dev/null; then
		leaf=${LEAFDIRS[$(rand ${#LEAFDIRS[@]})]}
		(
			echo $BASHPID > "$leaf/cgroup.procs" 2>/dev/null
			stress-ng --cpu "$ONLINE_CPUS" --timeout "${DURATION}s" \
				--cpu-method matrixprod >/dev/null 2>&1 || true
		) &
		LOAD_PIDS+=($!)
	fi

	# 3) stress-ng --fork — rapid fork/exit (enqueue_hierarchy storms)
	if command -v stress-ng >/dev/null; then
		leaf=${LEAFDIRS[-1]}  # the deep one
		(
			echo $BASHPID > "$leaf/cgroup.procs" 2>/dev/null
			stress-ng --fork "$((ONLINE_CPUS/2 + 1))" --timeout "${DURATION}s" \
				>/dev/null 2>&1 || true
		) &
		LOAD_PIDS+=($!)
	fi

	# 4) stress-ng --yield — exercises put_prev_task/set_next_task rapidly
	if command -v stress-ng >/dev/null; then
		leaf=${LEAFDIRS[$(rand ${#LEAFDIRS[@]})]}
		(
			echo $BASHPID > "$leaf/cgroup.procs" 2>/dev/null
			stress-ng --yield "$ONLINE_CPUS" --timeout "${DURATION}s" \
				>/dev/null 2>&1 || true
		) &
		LOAD_PIDS+=($!)
	fi

	# 5) stress-ng --sleep — short sleeps trigger sched_delayed / wakeup paths
	if command -v stress-ng >/dev/null; then
		leaf=${LEAFDIRS[$(rand ${#LEAFDIRS[@]})]}
		(
			echo $BASHPID > "$leaf/cgroup.procs" 2>/dev/null
			stress-ng --sleep "$ONLINE_CPUS" --timeout "${DURATION}s" \
				--sleep-max 1000 >/dev/null 2>&1 || true
		) &
		LOAD_PIDS+=($!)
	fi

	# 6) sysbench cpu — multi-threaded compute
	if command -v sysbench >/dev/null; then
		leaf=${LEAFDIRS[$(rand ${#LEAFDIRS[@]})]}
		(
			echo $BASHPID > "$leaf/cgroup.procs" 2>/dev/null
			sysbench cpu --threads="$ONLINE_CPUS" --time="$DURATION" run \
				>/dev/null 2>&1 || true
		) &
		LOAD_PIDS+=($!)
	fi

	# 7) perf bench sched messaging (if perf available) — IPC + scheduling
	if command -v perf >/dev/null; then
		leaf=${LEAFDIRS[$(rand ${#LEAFDIRS[@]})]}
		(
			echo $BASHPID > "$leaf/cgroup.procs" 2>/dev/null
			while [[ -e "$KLOG.run" ]]; do
				perf bench sched messaging -p -g "$ONLINE_CPUS" -l 3000 \
					>/dev/null 2>&1 || true
			done
		) &
		LOAD_PIDS+=($!)
	fi
}

# ---- chaos operations (cgroup / task mutations under load) -----------------

# Collect PIDs of tasks in our cgroup tree for migration/renice targets
get_cg_pids() {
	find "$ROOT" -name cgroup.procs -exec cat {} + 2>/dev/null | shuf | head -20
}

chaos_migrate() {
	local pids leaf
	pids=$(get_cg_pids)
	[[ -z "$pids" ]] && return
	leaf=${LEAFDIRS[$(rand ${#LEAFDIRS[@]})]}
	for pid in $pids; do
		echo "$pid" > "$leaf/cgroup.procs" 2>/dev/null || true
	done
}

chaos_migrate_deep_shallow() {
	local pids
	pids=$(get_cg_pids)
	[[ -z "$pids" ]] && return
	for pid in $pids; do
		if (( $(rand 2) )); then
			echo "$pid" > "${LEAFDIRS[-1]}/cgroup.procs" 2>/dev/null || true
		else
			echo "$pid" > "${LEAFDIRS[0]}/cgroup.procs" 2>/dev/null || true
		fi
	done
}

chaos_renice() {
	local pids
	pids=$(get_cg_pids)
	[[ -z "$pids" ]] && return
	for pid in $pids; do
		renice -n $(( $(rand 40) - 20 )) -p "$pid" >/dev/null 2>&1 || true
	done
}

chaos_weight() {
	local leaf=${LEAFDIRS[$(rand ${#LEAFDIRS[@]})]}
	[[ -w "$leaf/cpu.weight" ]] && echo $(( 1 + $(rand 10000) )) > "$leaf/cpu.weight" 2>/dev/null || true
}

chaos_weight_parent() {
	local leaf=${LEAFDIRS[$(rand ${#LEAFDIRS[@]})]}
	local parent
	parent=$(dirname "$leaf")
	[[ -w "$parent/cpu.weight" ]] && echo $(( 1 + $(rand 10000) )) > "$parent/cpu.weight" 2>/dev/null || true
}

chaos_throttle() {
	local leaf=${LEAFDIRS[$(rand ${#LEAFDIRS[@]})]}
	[[ -w "$leaf/cpu.max" ]] || return
	if (( $(rand 2) )); then
		echo "$(( 5000 + $(rand 40000) )) 100000" > "$leaf/cpu.max" 2>/dev/null || true
	else
		echo "max 100000" > "$leaf/cpu.max" 2>/dev/null || true
	fi
}

chaos_throttle_burst() {
	local leaf=${LEAFDIRS[$(rand ${#LEAFDIRS[@]})]}
	[[ -w "$leaf/cpu.max" ]] || return
	echo "1000 100000" > "$leaf/cpu.max" 2>/dev/null || true
	echo "max 100000" > "$leaf/cpu.max" 2>/dev/null || true
}

chaos_affinity() {
	local pids
	pids=$(get_cg_pids)
	[[ -z "$pids" ]] && return
	local c=$(rand "$ONLINE_CPUS")
	for pid in $pids; do
		taskset -pc "$c" "$pid" >/dev/null 2>&1 || true
	done
}

chaos_affinity_release() {
	local pids
	pids=$(get_cg_pids)
	[[ -z "$pids" ]] && return
	for pid in $pids; do
		taskset -pc 0-$((ONLINE_CPUS-1)) "$pid" >/dev/null 2>&1 || true
	done
}

chaos_cgcreate_destroy() {
	local base=${LEAFDIRS[$(rand ${#LEAFDIRS[@]})]}
	local parent
	parent=$(dirname "$base")
	local tmp="$parent/eph_$$_$RANDOM"
	mkdir -p "$tmp" 2>/dev/null || return
	# Move tasks in, then out, then destroy
	local pids
	pids=$(get_cg_pids)
	for pid in $pids; do
		echo "$pid" > "$tmp/cgroup.procs" 2>/dev/null || true
		break  # just one
	done
	msleep 5
	# Move back
	for pid in $pids; do
		echo "$pid" > "$base/cgroup.procs" 2>/dev/null || true
		break
	done
	msleep 3
	rmdir "$tmp" 2>/dev/null || true
}

chaos_sched_class() {
	local pids
	pids=$(get_cg_pids)
	[[ -z "$pids" ]] && return
	local pid
	for pid in $pids; do
		chrt -f -p 1 "$pid" 2>/dev/null || true
		chrt -o -p 0 "$pid" 2>/dev/null || true
		break
	done
}

chaos_hotplug() {
	(( HOTPLUG )) || return
	local c=$(( 1 + $(rand $((ONLINE_CPUS-1)) ) ))
	local f="/sys/devices/system/cpu/cpu$c/online"
	[[ -w "$f" ]] || return
	echo 0 > "$f" 2>/dev/null || true
	msleep 30
	echo 1 > "$f" 2>/dev/null || true
}

run_chaos() {
	local ops=(chaos_migrate chaos_migrate_deep_shallow
		   chaos_renice chaos_weight chaos_weight_parent
		   chaos_throttle chaos_throttle_burst
		   chaos_affinity chaos_affinity_release
		   chaos_cgcreate_destroy chaos_sched_class
		   chaos_hotplug)
	local end=$(( SECONDS + DURATION ))
	while (( SECONDS < end )) && (( ! STOP )); do
		${ops[$(rand ${#ops[@]})]}
		msleep "$OPRATE_MS"
	done
}

# ---- kernel log check ------------------------------------------------------
PAT='WARNING:|kernel BUG|BUG:|Call Trace|RCU.*stall|soft lockup|hard LOCKUP|list_(add|del) corruption|refcount|KASAN|sched:|fair\.c|h_curr|__enqueue_entity|set_next_entity|put_prev_entity|reweight_eevdf|h_nr_queued|h_nr_runnable|task_change_group|switching_from_fair'

cleanup() {
	STOP=1
	rm -f "$KLOG.run"
	set +e
	# Kill all load generators
	for pid in "${LOAD_PIDS[@]}"; do
		kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
	done
	pkill -P $$ 2>/dev/null
	sleep 2
	wait 2>/dev/null
	# Drain cgroups and remove
	find "$ROOT" -depth -type d 2>/dev/null | while read -r d; do
		[[ -f "$d/cgroup.procs" ]] && while read -r p; do
			echo "$p" > "$CG/cgroup.procs" 2>/dev/null
		done < "$d/cgroup.procs"
		rmdir "$d" 2>/dev/null
	done
}
trap cleanup EXIT INT TERM

echo "== flat_race_stress: duration=${DURATION}s leaves=$LEAVES maxdepth=$MAXDEPTH deep=$DEEP_DEPTH =="
echo "   kernel=$(uname -r)"
echo

# Baseline kernel log
dmesg 2>/dev/null > "$KLOG.before" || true
BEFORE=$(grep -Ec "$PAT" "$KLOG.before" 2>/dev/null || echo 0)

build_hierarchy
touch "$KLOG.run"
start_load

echo "Load generators running: ${#LOAD_PIDS[@]} processes"
echo "Starting chaos operations for ${DURATION}s (rate ~${OPRATE_MS}ms)..."
echo

run_chaos

rm -f "$KLOG.run"
sleep 3

dmesg 2>/dev/null > "$KLOG.after" || true
NEW=$(comm -13 <(sort "$KLOG.before") <(sort "$KLOG.after") 2>/dev/null | grep -E "$PAT" || true)

echo
echo "== kernel-log verdict =="
if [[ -n "$NEW" ]]; then
	echo "FAIL: new scheduler-related kernel log events during the run:"
	echo "------------------------------------------------------------"
	echo "$NEW"
	echo "------------------------------------------------------------"
	echo "(full logs: $KLOG.before / $KLOG.after)"
	exit 1
else
	echo "PASS: no new WARNING/BUG/stall matching scheduler patterns."
	echo "      (baseline=$BEFORE)"
	rm -f "$KLOG.before" "$KLOG.after"
	exit 0
fi
