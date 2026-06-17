#!/usr/bin/env bash
# flat_race_targeted.sh — Targeted race condition tests for specific code paths
# in the "sched/eevdf: Move to a single runqueue" commit.
#
# Each test uses real open-source benchmarks (hackbench, stress-ng, sysbench,
# perf bench) as workload generators while exercising specific race windows
# identified from code review.
#
# Test cases:
#   1. curr_vs_hcurr:       Tick's reweight_eevdf vs cgroup migration of the
#                           running task. Uses stress-ng --cpu pinned to one CPU.
#   2. migrate_curr:        Move running tasks between shallow/deep cgroups.
#                           Uses sysbench cpu as workload.
#   3. delayed_destroy:     Cgroup destroyed while tasks inside are sleeping.
#                           Uses stress-ng --sleep to generate sched_delayed.
#   4. enqueue_reweight:    Concurrent fork storm + cpu.weight changes.
#                           Uses stress-ng --fork as the fork generator.
#   5. throttle_migrate:    Throttle a cgroup while migrating its tasks.
#                           Uses hackbench as the task pool.
#   6. deep_fork_exit:      Fork/exit in depth-32 cgroup + sibling weight churn.
#                           Uses stress-ng --fork in the deep leaf.
#   7. sched_class_bounce:  CFS<->RT class switch on tasks in deep cgroups.
#                           Uses perf bench sched pipe as workload.
#   8. multi_renice:        Mass renice of tasks on the same CPU/cgroup.
#                           Uses sysbench cpu pinned to one CPU.
#
# Required: stress-ng, hackbench, sysbench, perf (warns if missing)
# Run as root. PASS/FAIL based on kernel log.
set -uo pipefail

CG=/sys/fs/cgroup
ROOT=$CG/flatrace_targeted
KLOG=/tmp/flat_race_targeted_kmsg.$$
PASS=0
FAIL=0
ONLINE_CPUS=$(nproc)

[[ $(id -u) == 0 ]] || { echo "ERROR: run as root"; exit 1; }
[[ -e $CG/cgroup.controllers ]] || { echo "ERROR: need cgroup v2"; exit 1; }
grep -qw cpu "$CG/cgroup.controllers" || { echo "ERROR: cpu controller unavailable"; exit 1; }

PAT='WARNING:|kernel BUG|BUG:|Call Trace|RCU.*stall|soft lockup|hard LOCKUP|list_(add|del) corruption|KASAN|sched:|fair\.c|h_curr|__enqueue_entity|reweight_eevdf|h_nr_queued|h_nr_runnable|put_prev_entity|set_next_entity'

cleanup_cg() {
	set +e
	find "$ROOT" -depth -type d 2>/dev/null | while read -r d; do
		[[ -f "$d/cgroup.procs" ]] && while read -r p; do
			echo "$p" > "$CG/cgroup.procs" 2>/dev/null
		done < "$d/cgroup.procs"
		rmdir "$d" 2>/dev/null
	done
	set -e
}
trap cleanup_cg EXIT INT TERM

make_chain() {
	local depth=$1 base=$2 p="$base"
	mkdir -p "$base"
	echo "+cpu" > "$base/cgroup.subtree_control" 2>/dev/null || true
	for ((i=1; i<=depth; i++)); do
		p="$p/l$i"
		mkdir -p "$p"
		(( i < depth )) && echo "+cpu" > "$p/cgroup.subtree_control" 2>/dev/null || true
	done
	echo "$p"
}

snapshot_klog() { dmesg > "$KLOG.before" 2>/dev/null || true; }

check_klog() {
	local test_name=$1
	sleep 1
	dmesg > "$KLOG.after" 2>/dev/null || true
	local new
	new=$(comm -13 <(sort "$KLOG.before") <(sort "$KLOG.after") 2>/dev/null \
		| grep -E "$PAT" || true)
	if [[ -n "$new" ]]; then
		echo "  FAIL: new kernel log events:"
		echo "$new" | head -20
		FAIL=$((FAIL+1))
		return 1
	else
		echo "  PASS"
		PASS=$((PASS+1))
		return 0
	fi
}

# Get PIDs living in a specific cgroup leaf
get_leaf_pids() {
	cat "$1/cgroup.procs" 2>/dev/null | head -30
}

# ============================================================================
# TEST 1: curr_vs_hcurr — Tick reweight_eevdf races with cgroup migration
# stress-ng --cpu pinned to CPU0; rapidly migrate those workers between
# two depth-8 cgroups -> the running task's h_load is recalculated by tick
# while task_change_group_fair detaches/reattaches it.
# ============================================================================
test_curr_vs_hcurr() {
	echo "TEST 1: curr_vs_hcurr (tick reweight vs cgroup migration)"
	local dur=${1:-15}
	cleanup_cg
	mkdir -p "$ROOT"
	echo "+cpu" > "$ROOT/cgroup.subtree_control" 2>/dev/null || true

	local leaf1 leaf2
	leaf1=$(make_chain 8 "$ROOT/a")
	leaf2=$(make_chain 8 "$ROOT/b")

	snapshot_klog

	if ! command -v stress-ng >/dev/null; then
		echo "  SKIP (stress-ng not found)"
		return
	fi

	# Start CPU workers pinned to CPU0 (maximizes curr contention)
	stress-ng --cpu 4 --cpu-method matrixprod --timeout "${dur}s" \
		--taskset 0 >/dev/null 2>&1 &
	local load_pid=$!
	sleep 1

	# Move those workers into our leaf cgroup
	for pid in $(pgrep -P "$load_pid" 2>/dev/null); do
		echo "$pid" > "$leaf1/cgroup.procs" 2>/dev/null || true
	done

	# Rapid migration between two deep cgroups
	local end=$((SECONDS + dur))
	while (( SECONDS < end )); do
		for pid in $(get_leaf_pids "$leaf1"); do
			echo "$pid" > "$leaf2/cgroup.procs" 2>/dev/null || true
		done
		for pid in $(get_leaf_pids "$leaf2"); do
			echo "$pid" > "$leaf1/cgroup.procs" 2>/dev/null || true
		done
	done

	kill "$load_pid" 2>/dev/null; wait 2>/dev/null
	check_klog "curr_vs_hcurr"
}

# ============================================================================
# TEST 2: migrate_curr — Move running task between shallow and deep cgroups
# Uses sysbench cpu as compute workload. The h_load jump from depth-4 to
# depth-16 exercises __calc_prop_weight with very different chain lengths.
# ============================================================================
test_migrate_curr() {
	echo "TEST 2: migrate_curr (running task between shallow/deep cgroups)"
	local dur=${1:-15}
	cleanup_cg
	mkdir -p "$ROOT"
	echo "+cpu" > "$ROOT/cgroup.subtree_control" 2>/dev/null || true

	local leaf_shallow leaf_deep
	leaf_shallow=$(make_chain 2 "$ROOT/shallow")
	leaf_deep=$(make_chain 16 "$ROOT/deep")

	snapshot_klog

	if ! command -v sysbench >/dev/null; then
		echo "  SKIP (sysbench not found)"
		return
	fi

	# sysbench cpu in the shallow cgroup
	bash -c "echo \$BASHPID > '$leaf_shallow/cgroup.procs' 2>/dev/null;
		exec sysbench cpu --threads=$ONLINE_CPUS --time=$dur run" \
		>/dev/null 2>&1 &
	local load_pid=$!
	sleep 1

	# Rapidly bounce sysbench's threads between shallow and deep
	local end=$((SECONDS + dur - 1))
	while (( SECONDS < end )); do
		for pid in $(get_leaf_pids "$leaf_shallow"); do
			echo "$pid" > "$leaf_deep/cgroup.procs" 2>/dev/null || true
		done
		sleep 0.005
		for pid in $(get_leaf_pids "$leaf_deep"); do
			echo "$pid" > "$leaf_shallow/cgroup.procs" 2>/dev/null || true
		done
		sleep 0.005
	done

	kill "$load_pid" 2>/dev/null; wait 2>/dev/null
	check_klog "migrate_curr"
}

# ============================================================================
# TEST 3: delayed_destroy — Cgroup destroyed while tasks inside are sleeping
# stress-ng --sleep generates tasks that repeatedly enter/exit sleep states
# (triggering sched_delayed). We yank them out and destroy the cgroup.
# ============================================================================
test_delayed_destroy() {
	echo "TEST 3: delayed_destroy (sched_delayed + cgroup removal)"
	local dur=${1:-15}
	local iterations=0
	cleanup_cg
	mkdir -p "$ROOT"
	echo "+cpu" > "$ROOT/cgroup.subtree_control" 2>/dev/null || true

	local fallback
	fallback=$(make_chain 1 "$ROOT/fallback")

	snapshot_klog

	if ! command -v stress-ng >/dev/null; then
		echo "  SKIP (stress-ng not found)"
		return
	fi

	local end=$((SECONDS + dur))
	while (( SECONDS < end )); do
		local tmp="$ROOT/dly_$$_$RANDOM"
		local leaf
		leaf=$(make_chain 4 "$tmp")

		# Start stress-ng --sleep in the leaf (many short sleeps -> delayed)
		stress-ng --sleep 4 --sleep-max 500 --timeout 2s >/dev/null 2>&1 &
		local pid=$!
		sleep 0.2

		# Move stress-ng workers into the cgroup
		for cpid in $(pgrep -P "$pid" 2>/dev/null); do
			echo "$cpid" > "$leaf/cgroup.procs" 2>/dev/null || true
		done

		# Let them run briefly, then yank out and destroy
		sleep 0.5
		for cpid in $(get_leaf_pids "$leaf"); do
			echo "$cpid" > "$fallback/cgroup.procs" 2>/dev/null || true
		done
		kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

		find "$tmp" -depth -type d 2>/dev/null | while read -r d; do
			rmdir "$d" 2>/dev/null || true
		done
		iterations=$((iterations+1))
	done

	echo "  ($iterations iterations)"
	check_klog "delayed_destroy"
}

# ============================================================================
# TEST 4: enqueue_reweight — Concurrent fork storm + cpu.weight changes
# stress-ng --fork generates enqueue_hierarchy storms in a depth-8 cgroup.
# Meanwhile we rapidly change cpu.weight on the leaf and its parents,
# causing update_cfs_group -> reweight_entity to race with the fork's
# __calc_prop_weight walk.
# ============================================================================
test_enqueue_reweight() {
	echo "TEST 4: enqueue_reweight (fork storm + weight change)"
	local dur=${1:-15}
	cleanup_cg
	mkdir -p "$ROOT"
	echo "+cpu" > "$ROOT/cgroup.subtree_control" 2>/dev/null || true

	local leaf
	leaf=$(make_chain 8 "$ROOT/ew")

	snapshot_klog

	if ! command -v stress-ng >/dev/null; then
		echo "  SKIP (stress-ng not found)"
		return
	fi

	# stress-ng --fork in the deep cgroup
	bash -c "echo \$BASHPID > '$leaf/cgroup.procs' 2>/dev/null;
		exec stress-ng --fork $((ONLINE_CPUS/2 + 1)) --timeout ${dur}s" \
		>/dev/null 2>&1 &
	local load_pid=$!

	# Concurrent weight changes on leaf and parents
	local end=$((SECONDS + dur))
	while (( SECONDS < end )); do
		[[ -w "$leaf/cpu.weight" ]] && echo $(( 1 + RANDOM % 10000 )) > "$leaf/cpu.weight" 2>/dev/null || true
		local parent
		parent=$(dirname "$leaf")
		[[ -w "$parent/cpu.weight" ]] && echo $(( 1 + RANDOM % 10000 )) > "$parent/cpu.weight" 2>/dev/null || true
		parent=$(dirname "$parent")
		[[ -w "$parent/cpu.weight" ]] && echo $(( 1 + RANDOM % 5000 )) > "$parent/cpu.weight" 2>/dev/null || true
		sleep 0.003
	done

	kill "$load_pid" 2>/dev/null; wait 2>/dev/null
	check_klog "enqueue_reweight"
}

# ============================================================================
# TEST 5: throttle_migrate — Throttle cgroup while migrating its tasks
# hackbench provides a large pool of tasks in a cgroup. We throttle it hard
# while simultaneously migrating tasks to different CPUs via taskset.
# Tests h_nr_queued accounting across throttle + migration.
# ============================================================================
test_throttle_migrate() {
	echo "TEST 5: throttle_migrate (bandwidth throttle + task migration)"
	local dur=${1:-15}
	cleanup_cg
	mkdir -p "$ROOT"
	echo "+cpu" > "$ROOT/cgroup.subtree_control" 2>/dev/null || true

	local leaf
	leaf=$(make_chain 4 "$ROOT/tm")

	snapshot_klog

	if ! command -v hackbench >/dev/null; then
		echo "  SKIP (hackbench not found)"
		return
	fi

	# hackbench running inside the cgroup (provides many tasks)
	bash -c "echo \$BASHPID > '$leaf/cgroup.procs' 2>/dev/null;
		exec hackbench -pipe -g $ONLINE_CPUS -l 100000" \
		>/dev/null 2>&1 &
	local load_pid=$!
	sleep 1

	# Concurrent throttle/unthrottle + task migration
	local end=$((SECONDS + dur))
	while (( SECONDS < end )); do
		# Throttle hard
		[[ -w "$leaf/cpu.max" ]] && echo "1000 100000" > "$leaf/cpu.max" 2>/dev/null || true
		# Migrate tasks while throttled
		for pid in $(get_leaf_pids "$leaf" | head -5); do
			local c=$((RANDOM % ONLINE_CPUS))
			taskset -pc "$c" "$pid" >/dev/null 2>&1 || true
		done
		sleep 0.002
		# Unthrottle
		[[ -w "$leaf/cpu.max" ]] && echo "max 100000" > "$leaf/cpu.max" 2>/dev/null || true
		sleep 0.002
	done

	kill "$load_pid" 2>/dev/null; wait 2>/dev/null
	check_klog "throttle_migrate"
}

# ============================================================================
# TEST 6: deep_fork_exit — Fork/exit in depth-32 cgroup with sibling churn
# stress-ng --fork at depth-32. Sibling stress-ng --cpu at intermediate levels
# cause cfs_rq->load changes that __calc_prop_weight reads mid-walk.
# ============================================================================
test_deep_fork_exit() {
	echo "TEST 6: deep_fork_exit (depth-32 fork storm + sibling weight churn)"
	local dur=${1:-15}
	cleanup_cg
	mkdir -p "$ROOT"
	echo "+cpu" > "$ROOT/cgroup.subtree_control" 2>/dev/null || true

	local leaf
	leaf=$(make_chain 32 "$ROOT/deep")

	# Siblings at intermediate levels
	local sib1="$ROOT/deep/l1/sib1"
	local sib2="$ROOT/deep/l1/l2/l3/l4/sib4"
	mkdir -p "$sib1" "$sib2" 2>/dev/null || true

	snapshot_klog

	if ! command -v stress-ng >/dev/null; then
		echo "  SKIP (stress-ng not found)"
		return
	fi

	# Sibling workloads at intermediate levels (their enqueue/dequeue changes
	# intermediate cfs_rq->load.weight values)
	bash -c "echo \$BASHPID > '$sib1/cgroup.procs' 2>/dev/null;
		exec stress-ng --cpu 2 --timeout ${dur}s" >/dev/null 2>&1 &
	local sib1_pid=$!

	bash -c "echo \$BASHPID > '$sib2/cgroup.procs' 2>/dev/null;
		exec stress-ng --yield 2 --timeout ${dur}s" >/dev/null 2>&1 &
	local sib2_pid=$!

	# Fork storm at the bottom
	bash -c "echo \$BASHPID > '$leaf/cgroup.procs' 2>/dev/null;
		exec stress-ng --fork $((ONLINE_CPUS/2 + 1)) --timeout ${dur}s" \
		>/dev/null 2>&1 &
	local fork_pid=$!

	sleep "$dur"
	kill "$fork_pid" "$sib1_pid" "$sib2_pid" 2>/dev/null; wait 2>/dev/null
	check_klog "deep_fork_exit"
}

# ============================================================================
# TEST 7: sched_class_bounce — CFS<->RT rapid switching
# perf bench sched pipe provides two tasks doing pipe ping-pong. We rapidly
# switch them CFS->FIFO->CFS, exercising switching_from_fair + dequeue of
# possibly-delayed entity + set_next_task_fair re-insertion.
# ============================================================================
test_sched_class_bounce() {
	echo "TEST 7: sched_class_bounce (CFS<->RT in deep cgroups)"
	local dur=${1:-15}
	cleanup_cg
	mkdir -p "$ROOT"
	echo "+cpu" > "$ROOT/cgroup.subtree_control" 2>/dev/null || true

	local leaf
	leaf=$(make_chain 8 "$ROOT/sclass")

	snapshot_klog

	if ! command -v perf >/dev/null; then
		echo "  SKIP (perf not found)"
		return
	fi

	# perf bench sched pipe — two tasks doing rapid context switches
	bash -c "echo \$BASHPID > '$leaf/cgroup.procs' 2>/dev/null;
		exec perf bench sched pipe -l 10000000" >/dev/null 2>&1 &
	local load_pid=$!
	sleep 1

	# Rapidly flip the pipe tasks between RT and CFS
	local end=$((SECONDS + dur - 1))
	while (( SECONDS < end )); do
		for pid in $(pgrep -P "$load_pid" 2>/dev/null); do
			chrt -f -p 1 "$pid" 2>/dev/null || true
		done
		sleep 0.002
		for pid in $(pgrep -P "$load_pid" 2>/dev/null); do
			chrt -o -p 0 "$pid" 2>/dev/null || true
		done
		sleep 0.002
	done

	kill "$load_pid" 2>/dev/null; wait 2>/dev/null
	check_klog "sched_class_bounce"
}

# ============================================================================
# TEST 8: multi_renice — Mass renice of tasks on the same CPU
# sysbench cpu threads pinned to CPU0. We renice them all simultaneously,
# causing back-to-back reweight_eevdf calls on the same rq->cfs tree.
# Also exercises the "curr" branch of reweight_eevdf.
# ============================================================================
test_multi_renice() {
	echo "TEST 8: multi_renice (mass renice same cgroup/CPU)"
	local dur=${1:-15}
	cleanup_cg
	mkdir -p "$ROOT"
	echo "+cpu" > "$ROOT/cgroup.subtree_control" 2>/dev/null || true

	local leaf
	leaf=$(make_chain 8 "$ROOT/renice")

	snapshot_klog

	if ! command -v sysbench >/dev/null; then
		echo "  SKIP (sysbench not found)"
		return
	fi

	# sysbench threads pinned to CPU0
	bash -c "echo \$BASHPID > '$leaf/cgroup.procs' 2>/dev/null;
		exec taskset -c 0 sysbench cpu --threads=16 --time=$dur run" \
		>/dev/null 2>&1 &
	local load_pid=$!
	sleep 1

	# Repeatedly renice all threads
	local end=$((SECONDS + dur - 1))
	while (( SECONDS < end )); do
		for pid in $(pgrep -P "$load_pid" 2>/dev/null); do
			renice -n $(( (RANDOM % 39) - 20 )) -p "$pid" >/dev/null 2>&1 || true
		done
		sleep 0.005
	done

	kill "$load_pid" 2>/dev/null; wait 2>/dev/null
	check_klog "multi_renice"
}

# ============================================================================
# MAIN
# ============================================================================
TEST_DUR=${TEST_DUR:-15}

echo "========================================"
echo " Targeted flat-pick race condition tests"
echo " Duration per test: ${TEST_DUR}s"
echo " Kernel: $(uname -r)"
echo "========================================"
echo

test_curr_vs_hcurr "$TEST_DUR"
echo
test_migrate_curr "$TEST_DUR"
echo
test_delayed_destroy "$TEST_DUR"
echo
test_enqueue_reweight "$TEST_DUR"
echo
test_throttle_migrate "$TEST_DUR"
echo
test_deep_fork_exit "$TEST_DUR"
echo
test_sched_class_bounce "$TEST_DUR"
echo
test_multi_renice "$TEST_DUR"

echo
echo "========================================"
echo " Results: PASS=$PASS  FAIL=$FAIL"
echo "========================================"
rm -f "$KLOG.before" "$KLOG.after"
(( FAIL == 0 )) && exit 0 || exit 1
