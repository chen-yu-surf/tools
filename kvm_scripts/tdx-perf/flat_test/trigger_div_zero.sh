#!/bin/bash
# trigger_div_zero.sh - Trigger divide-by-zero in propagate_entity_load_avg
#
# Bug mechanism:
#   In update_tg_cfs_load():
#     if (scale_load_down(gcfs_rq->load.weight)) {
#         load_sum = div_u64(gcfs_rq->avg.load_sum,
#                            scale_load_down(gcfs_rq->load.weight));
#     }
#
#   scale_load_down() returns unsigned long (64-bit), but div_u64() takes
#   a u32 divisor. The compiler truncates the 64-bit result to 32 bits
#   (mov ecx, eax). If the lower 32 bits of scale_load_down() are 0 but
#   upper bits are non-zero:
#     - The if-guard sees a non-zero unsigned long → passes
#     - The div_u64 divisor gets truncated to 0 → divide-by-zero
#
# Trigger paths:
#   1. task_tick_fair → entity_tick → update_load_avg → propagate_entity_load_avg
#      (fires every scheduler tick for running tasks in cgroup hierarchies)
#   2. sched_ttwu_pending → enqueue_task_fair → enqueue_hierarchy → update_load_avg
#      (remote wakeup IPI on idle CPUs)
#
# The tick path is MUCH easier to trigger since it fires every ~1-4ms for
# every running task in a group hierarchy. We just need gcfs_rq->load.weight
# to reach a state where lower 32 bits of (weight >> 10) = 0.
#
# Strategy:
#   1. Deep cgroup hierarchies with many running tasks (tick path fires constantly)
#   2. Rapid task migration between groups (stresses load.weight accounting)
#   3. Rapid cpu.weight changes (triggers reweight_entity → transient load.weight)
#   4. Concurrent cgroup destruction (can leave stale per-cpu cfs_rq data)
#   5. Mixed nice values (diverse weight contributions increase chance of
#      problematic bit patterns in load.weight)

set -e

CGROOT="/sys/fs/cgroup"
TEST_ROOT="$CGROOT/test_flat_div0"
DEPTH=16
NUM_GROUPS=16
ITERATIONS=300
ONLINE_CPUS=$(nproc)
HB_GROUPS=16
HB_FDS=80

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ORIG_PRINTK_LEVEL=""

cleanup() {
    echo -e "${YELLOW}[*] Cleaning up...${NC}"
    # Kill any remaining workloads
    pkill -9 -f "hackbench" 2>/dev/null || true
    pkill -9 -f "stress-ng" 2>/dev/null || true
    sleep 1

    # Move all tasks back to root before removing
    if [ -d "$TEST_ROOT" ]; then
        find "$TEST_ROOT" -name "cgroup.procs" -exec sh -c '
            while read pid; do
                echo $pid > '"$CGROOT"'/cgroup.procs 2>/dev/null || true
            done < "$1"
        ' _ {} \;
        sleep 1
        # Remove deepest first
        find "$TEST_ROOT" -depth -type d -exec rmdir {} \; 2>/dev/null || true
    fi

    # Restore printk
    if [ -n "$ORIG_PRINTK_LEVEL" ]; then
        echo "$ORIG_PRINTK_LEVEL" > /proc/sys/kernel/printk 2>/dev/null || true
    fi
}

trap cleanup EXIT

check_prerequisites() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: Must run as root"
        exit 1
    fi

    if ! which hackbench >/dev/null 2>&1; then
        echo "ERROR: hackbench not found. Install it (e.g., from rt-tests or linux-tools)"
        exit 1
    fi

    # Check cgroup v2
    if ! mount | grep -q "cgroup2 on $CGROOT"; then
        echo "ERROR: cgroup v2 not mounted at $CGROOT"
        exit 1
    fi

    # Enable cpu controller in root
    echo "+cpu" > "$CGROOT/cgroup.subtree_control" 2>/dev/null || true
}

check_crash() {
    if dmesg 2>/dev/null | grep -qi "divide error\|oops.*propagate_entity"; then
        echo -e "${RED}[!] *** DIVIDE-BY-ZERO DETECTED! ***${NC}"
        dmesg | grep -A 30 "divide error\|Oops" | tail -40
        return 0
    fi
    return 1
}

# Create a deeply nested cgroup hierarchy and return the leaf path
create_deep_hierarchy() {
    local base="$1"
    local id="$2"
    local depth="${3:-$DEPTH}"
    local path="$base/grp_${id}"

    mkdir -p "$path"
    echo "+cpu" > "$path/cgroup.subtree_control" 2>/dev/null || true

    local current="$path"
    for ((d=1; d<=depth; d++)); do
        current="$current/L${d}"
        mkdir -p "$current"
        if [ $d -lt $depth ]; then
            echo "+cpu" > "$current/cgroup.subtree_control" 2>/dev/null || true
        fi
    done
    echo "$current"
}

# =============================================================================
# Phase 1: Tick-triggered propagation with rapid weight churn
#
# The tick path (task_tick_fair → entity_tick → update_load_avg →
# propagate_entity_load_avg) fires on every scheduler tick for tasks
# running in group hierarchies. If gcfs_rq->load.weight has corrupted
# lower 32 bits (=0 after >> 10), the tick will crash.
#
# Strategy: keep tasks running in deep cgroups while rapidly churning
# cpu.weight values to stress the reweight paths that modify load.weight.
# =============================================================================
stress_tick_weight_churn() {
    echo -e "${GREEN}[*] Phase 1: Tick-path stress with rapid weight churn${NC}"
    echo -e "  ${YELLOW}Running tasks in ${DEPTH}-level deep hierarchy, churning weights${NC}"

    # Create several deep hierarchies
    local leaves=()
    for ((g=0; g<NUM_GROUPS; g++)); do
        local leaf
        leaf=$(create_deep_hierarchy "$TEST_ROOT" "tick_${g}")
        leaves+=("$leaf")
    done

    # Start hackbench in each hierarchy — tasks running continuously
    # means tick fires entity_tick → propagate_entity_load_avg at every level
    local hb_pids=()
    for ((g=0; g<NUM_GROUPS; g++)); do
        hackbench -p -l 1000000 -g $HB_GROUPS -f $HB_FDS &
        local hb_pid=$!
        hb_pids+=($hb_pid)
        # Move into the deep cgroup
        for pid in $(pgrep -P $hb_pid 2>/dev/null); do
            echo "$pid" > "${leaves[$g]}/cgroup.procs" 2>/dev/null || true
        done
        echo "$hb_pid" > "${leaves[$g]}/cgroup.procs" 2>/dev/null || true
    done

    # Let tasks get settled and start generating ticks
    sleep 0.5

    # Now rapidly churn cpu.weight on ALL levels of ALL hierarchies
    # This calls update_cfs_group → reweight_entity which does:
    #   update_load_sub(&cfs_rq->load, old_weight)
    #   update_load_add(&cfs_rq->load, new_weight)
    # Creating transient states in load.weight
    echo -e "  ${YELLOW}Churning cpu.weight on all hierarchy levels...${NC}"
    for ((iter=0; iter<ITERATIONS; iter++)); do
        for ((g=0; g<NUM_GROUPS; g++)); do
            local path="$TEST_ROOT/grp_tick_${g}"
            local cur="$path"
            for ((d=1; d<=DEPTH; d++)); do
                cur="$cur/L${d}"
                # Rapidly change weight — varies from 1 to 10000
                local w=$(( (iter * 7 + g * 13 + d * 3) % 10000 + 1 ))
                echo "$w" > "$cur/cpu.weight" 2>/dev/null || true
            done
        done

        if [ $((iter % 50)) -eq 0 ]; then
            echo -e "  ${YELLOW}[iter $iter/$ITERATIONS]${NC}"
            if check_crash; then return; fi
        fi
    done

    # Kill hackbench
    for pid in "${hb_pids[@]}"; do
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done

    # Cleanup hierarchies
    for pid in $(find "$TEST_ROOT" -path "*/grp_tick_*" -name "cgroup.procs" \
                 -exec cat {} \; 2>/dev/null | sort -u); do
        echo "$pid" > "$TEST_ROOT/cgroup.procs" 2>/dev/null || true
    done
    find "$TEST_ROOT" -path "*/grp_tick_*" -depth -type d -exec rmdir {} \; 2>/dev/null || true

    echo -e "${GREEN}[*] Phase 1 complete${NC}"
}

# =============================================================================
# Phase 2: Rapid migration between groups under tick
#
# Moving tasks between cgroups calls:
#   sched_move_task → dequeue + sched_change_group + enqueue
# This modifies gcfs_rq->load.weight (subtract from old, add to new).
# If tick fires while propagating through a hierarchy level whose
# gcfs_rq->load.weight is in a problematic state, we crash.
# =============================================================================
stress_migration_under_tick() {
    echo -e "${GREEN}[*] Phase 2: Rapid migration between groups under tick${NC}"

    # Create two deep hierarchies to ping-pong tasks between
    local leaf_a leaf_b
    leaf_a=$(create_deep_hierarchy "$TEST_ROOT" "mig_a")
    leaf_b=$(create_deep_hierarchy "$TEST_ROOT" "mig_b")

    # Start many hackbench instances (lots of tasks = lots of ticks)
    local hb_pids=()
    for ((i=0; i<NUM_GROUPS; i++)); do
        hackbench -p -l 1000000 -g $HB_GROUPS -f $HB_FDS &
        hb_pids+=($!)
    done
    sleep 0.3

    # Rapidly move tasks between the two hierarchies
    # Each move does dequeue (subtract weight) + enqueue (add weight)
    # at ALL levels of the hierarchy
    echo -e "  ${YELLOW}Ping-ponging tasks between two ${DEPTH}-level hierarchies...${NC}"
    for ((iter=0; iter<ITERATIONS*2; iter++)); do
        local target
        if [ $((iter % 2)) -eq 0 ]; then
            target="$leaf_a"
        else
            target="$leaf_b"
        fi

        # Move a batch of tasks
        for pid in $(pgrep -f hackbench 2>/dev/null | shuf | head -20); do
            echo "$pid" > "$target/cgroup.procs" 2>/dev/null || true
        done

        # Also churn weight simultaneously
        local w=$(( (iter * 31) % 10000 + 1 ))
        echo "$w" > "$leaf_a/cpu.weight" 2>/dev/null || true
        echo "$w" > "$leaf_b/cpu.weight" 2>/dev/null || true

        if [ $((iter % 100)) -eq 0 ]; then
            echo -e "  ${YELLOW}[iter $iter/$((ITERATIONS*2))]${NC}"
            if check_crash; then return; fi
        fi
    done

    # Kill hackbench
    for pid in "${hb_pids[@]}"; do
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done

    # Move remaining tasks out and cleanup
    for pid in $(find "$TEST_ROOT" -path "*/grp_mig_*" -name "cgroup.procs" \
                 -exec cat {} \; 2>/dev/null | sort -u); do
        echo "$pid" > "$TEST_ROOT/cgroup.procs" 2>/dev/null || true
    done
    find "$TEST_ROOT" -path "*/grp_mig_*" -depth -type d -exec rmdir {} \; 2>/dev/null || true

    echo -e "${GREEN}[*] Phase 2 complete${NC}"
}

# =============================================================================
# Phase 3: Create/destroy storm with concurrent running tasks
#
# Rapidly create deep hierarchies, move running tasks in, then destroy.
# The cgroup destruction path (css_free → sched_unregister_group) happens
# asynchronously via RCU callbacks. If a task's tick fires while the
# hierarchy is being torn down, gcfs_rq->load.weight can be stale/corrupted.
# =============================================================================
stress_create_destroy_under_tick() {
    echo -e "${GREEN}[*] Phase 3: Create/destroy storm with concurrent ticks${NC}"

    # Background hackbench — generates constant ticks
    local bg_pids=()
    for ((i=0; i<4; i++)); do
        hackbench -p -l 1000000 -g $HB_GROUPS -f $HB_FDS &
        bg_pids+=($!)
    done
    sleep 0.3

    for ((iter=0; iter<ITERATIONS; iter++)); do
        # Create a deep hierarchy
        local leaf
        leaf=$(create_deep_hierarchy "$TEST_ROOT" "cd_${iter}")

        # Move some running tasks into it (they immediately start ticking there)
        for pid in $(pgrep -f hackbench 2>/dev/null | shuf | head -30); do
            echo "$pid" > "$leaf/cgroup.procs" 2>/dev/null || true
        done

        # Immediately churn the weight
        for w in 1 10000 1 5000 1; do
            echo "$w" > "$leaf/cpu.weight" 2>/dev/null || true
        done

        # Move tasks out and destroy — per-cpu cfs_rq enters "dying" state
        # while RCU callbacks haven't fired yet
        for pid in $(cat "$leaf/cgroup.procs" 2>/dev/null); do
            echo "$pid" > "$TEST_ROOT/cgroup.procs" 2>/dev/null || true
        done
        find "$TEST_ROOT/grp_cd_${iter}" -depth -type d -exec rmdir {} \; 2>/dev/null || true

        if [ $((iter % 50)) -eq 0 ]; then
            echo -e "  ${YELLOW}[iter $iter/$ITERATIONS]${NC}"
            if check_crash; then
                for pid in "${bg_pids[@]}"; do kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
                return
            fi
        fi
    done

    for pid in "${bg_pids[@]}"; do kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
    echo -e "${GREEN}[*] Phase 3 complete${NC}"
}

# =============================================================================
# Phase 4: Mixed nice values to create diverse weight patterns
#
# Different nice values produce different scale_load(weight) values.
# Mixing many nice levels increases the chance that gcfs_rq->load.weight
# ends up with lower 32 bits of (weight >> 10) = 0 after accumulation.
# =============================================================================
stress_mixed_nice_weights() {
    echo -e "${GREEN}[*] Phase 4: Mixed nice values + deep hierarchy ticks${NC}"

    local leaf
    leaf=$(create_deep_hierarchy "$TEST_ROOT" "nice")

    # Start tasks at various nice levels in the same deep cgroup
    local pids=()
    for nice_val in -20 -15 -10 -5 0 5 10 15 19; do
        for ((i=0; i<8; i++)); do
            nice -n "$nice_val" hackbench -p -l 500000 -g $HB_GROUPS -f $HB_FDS 2>/dev/null &
            pids+=($!)
        done
    done
    sleep 0.2

    # Move all into the deep cgroup
    for pid in "${pids[@]}"; do
        for cpid in $(pgrep -P "$pid" 2>/dev/null); do
            echo "$cpid" > "$leaf/cgroup.procs" 2>/dev/null || true
        done
        echo "$pid" > "$leaf/cgroup.procs" 2>/dev/null || true
    done

    echo -e "  ${YELLOW}Running ${#pids[@]} hackbench groups at mixed nice values...${NC}"

    # Let ticks fire while rapidly changing weights
    for ((iter=0; iter<ITERATIONS; iter++)); do
        local w=$(( (iter * 37) % 10000 + 1 ))
        # Change weight at multiple levels
        local cur="$TEST_ROOT/grp_nice"
        for ((d=1; d<=DEPTH && d<=8; d++)); do
            cur="$cur/L${d}"
            echo "$w" > "$cur/cpu.weight" 2>/dev/null || true
            w=$(( (w * 3 + 7) % 10000 + 1 ))
        done

        # Also rapidly renice some tasks (changes per-entity weight)
        for pid in $(pgrep -f hackbench 2>/dev/null | shuf | head -5); do
            local n=$(( (RANDOM % 39) - 20 ))
            renice "$n" -p "$pid" 2>/dev/null || true
        done

        if [ $((iter % 50)) -eq 0 ]; then
            echo -e "  ${YELLOW}[iter $iter/$ITERATIONS]${NC}"
            if check_crash; then break; fi
        fi
    done

    # Cleanup
    for pid in "${pids[@]}"; do
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    for pid in $(cat "$leaf/cgroup.procs" 2>/dev/null); do
        echo "$pid" > "$TEST_ROOT/cgroup.procs" 2>/dev/null || true
    done
    find "$TEST_ROOT/grp_nice" -depth -type d -exec rmdir {} \; 2>/dev/null || true

    echo -e "${GREEN}[*] Phase 4 complete${NC}"
}

# =============================================================================
# Phase 5: Affinity storm — force load imbalances and migrations
#
# Rapidly changing CPU affinity causes task migrations which trigger
# enqueue/dequeue at all hierarchy levels. Combined with tick processing,
# this maximizes the rate of propagate_entity_load_avg calls and creates
# transient weight states.
# =============================================================================
stress_affinity_storm() {
    echo -e "${GREEN}[*] Phase 5: Affinity storm + deep hierarchy ticks${NC}"

    # Create multiple deep hierarchies
    local leaves=()
    for ((g=0; g<4; g++)); do
        local leaf
        leaf=$(create_deep_hierarchy "$TEST_ROOT" "aff_${g}")
        leaves+=("$leaf")
    done

    # Start tasks in each hierarchy
    local all_pids=()
    for ((g=0; g<4; g++)); do
        hackbench -p -l 1000000 -g $HB_GROUPS -f $HB_FDS &
        local hb_pid=$!
        all_pids+=($hb_pid)
        for pid in $(pgrep -P $hb_pid 2>/dev/null); do
            echo "$pid" > "${leaves[$g]}/cgroup.procs" 2>/dev/null || true
        done
        echo "$hb_pid" > "${leaves[$g]}/cgroup.procs" 2>/dev/null || true
    done
    sleep 0.3

    echo -e "  ${YELLOW}Rapidly changing affinity on $ONLINE_CPUS CPUs...${NC}"
    for ((iter=0; iter<ITERATIONS*2; iter++)); do
        # Rapidly bounce task affinity — each change triggers migration
        # which does dequeue (old cpu) + enqueue (new cpu) through hierarchy
        for pid in $(pgrep -f hackbench 2>/dev/null | shuf | head -30); do
            local cpu=$(( RANDOM % ONLINE_CPUS ))
            taskset -pc "$cpu" "$pid" 2>/dev/null || true
        done

        # Also move tasks between cgroups during affinity changes
        if [ $((iter % 3)) -eq 0 ]; then
            local src=$(( iter % 4 ))
            local dst=$(( (iter + 1) % 4 ))
            for pid in $(cat "${leaves[$src]}/cgroup.procs" 2>/dev/null | head -5); do
                echo "$pid" > "${leaves[$dst]}/cgroup.procs" 2>/dev/null || true
            done
        fi

        if [ $((iter % 100)) -eq 0 ]; then
            echo -e "  ${YELLOW}[iter $iter/$((ITERATIONS*2))]${NC}"
            if check_crash; then break; fi
        fi
    done

    # Cleanup
    for pid in "${all_pids[@]}"; do
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    for pid in $(find "$TEST_ROOT" -path "*/grp_aff_*" -name "cgroup.procs" \
                 -exec cat {} \; 2>/dev/null | sort -u); do
        echo "$pid" > "$TEST_ROOT/cgroup.procs" 2>/dev/null || true
    done
    find "$TEST_ROOT" -path "*/grp_aff_*" -depth -type d -exec rmdir {} \; 2>/dev/null || true

    echo -e "${GREEN}[*] Phase 5 complete${NC}"
}

# =============================================================================
# Phase 6: Throttle + unthrottle burst with deep hierarchy
#
# CPU bandwidth throttling queues up tasks. When unthrottled, a burst of
# enqueues traverses the hierarchy. During throttle, intermediate group
# entities may get dequeued (load.weight drops). The unthrottle burst
# re-enqueues through potentially stale hierarchy state.
# =============================================================================
stress_throttle_burst() {
    echo -e "${GREEN}[*] Phase 6: Throttle/unthrottle burst in deep hierarchy${NC}"

    local leaf
    leaf=$(create_deep_hierarchy "$TEST_ROOT" "thr")

    # Start many tasks
    local thr_pids=()
    for ((i=0; i<4; i++)); do
        hackbench -p -l 1000000 -g $HB_GROUPS -f $HB_FDS &
        thr_pids+=($!)
    done
    sleep 0.2
    for hb_pid in "${thr_pids[@]}"; do
        for pid in $(pgrep -P $hb_pid 2>/dev/null); do
            echo "$pid" > "$leaf/cgroup.procs" 2>/dev/null || true
        done
        echo "$hb_pid" > "$leaf/cgroup.procs" 2>/dev/null || true
    done

    echo -e "  ${YELLOW}Rapidly throttling/unthrottling...${NC}"
    for ((iter=0; iter<ITERATIONS; iter++)); do
        # Throttle HARD — accumulates pending wakeups, group entities dequeue
        echo "1000 100000" > "$leaf/cpu.max" 2>/dev/null || true

        # Immediately unthrottle — burst of enqueues through hierarchy
        echo "max 100000" > "$leaf/cpu.max" 2>/dev/null || true

        # Simultaneously churn weight at intermediate levels
        local cur="$TEST_ROOT/grp_thr"
        for ((d=1; d<=DEPTH/2; d++)); do
            cur="$cur/L${d}"
            echo $(( RANDOM % 10000 + 1 )) > "$cur/cpu.weight" 2>/dev/null || true
        done

        if [ $((iter % 50)) -eq 0 ]; then
            echo -e "  ${YELLOW}[iter $iter/$ITERATIONS]${NC}"
            if check_crash; then break; fi
        fi
    done

    for pid in "${thr_pids[@]}"; do kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
    for pid in $(cat "$leaf/cgroup.procs" 2>/dev/null); do
        echo "$pid" > "$TEST_ROOT/cgroup.procs" 2>/dev/null || true
    done
    find "$TEST_ROOT/grp_thr" -depth -type d -exec rmdir {} \; 2>/dev/null || true

    echo -e "${GREEN}[*] Phase 6 complete${NC}"
}

# =============================================================================
# Phase 7: Extreme cgroup depth + continuous load
#
# Extra-deep hierarchy (32 levels) means more propagation steps per tick.
# More levels = more chances to hit a corrupted gcfs_rq->load.weight.
# Keep tasks continuously running to maximize tick rate.
# =============================================================================
stress_extreme_depth() {
    echo -e "${GREEN}[*] Phase 7: Extreme depth (32 levels) + continuous load${NC}"

    local leaf
    leaf=$(create_deep_hierarchy "$TEST_ROOT" "deep" 32)

    # Start many tasks at various nice levels
    local pids=()
    for nice_val in -20 -10 0 10 19; do
        for ((i=0; i<4; i++)); do
            nice -n "$nice_val" hackbench -p -l 500000 -g $HB_GROUPS -f $HB_FDS 2>/dev/null &
            pids+=($!)
        done
    done
    sleep 0.2

    # Move all into the 32-level deep cgroup
    for pid in "${pids[@]}"; do
        for cpid in $(pgrep -P "$pid" 2>/dev/null); do
            echo "$cpid" > "$leaf/cgroup.procs" 2>/dev/null || true
        done
        echo "$pid" > "$leaf/cgroup.procs" 2>/dev/null || true
    done

    echo -e "  ${YELLOW}Churning weights at all 32 levels while tasks tick...${NC}"
    for ((iter=0; iter<ITERATIONS; iter++)); do
        # Churn weights at all levels simultaneously
        local cur="$TEST_ROOT/grp_deep"
        for ((d=1; d<=32; d++)); do
            cur="$cur/L${d}"
            if [ -w "$cur/cpu.weight" ]; then
                echo $(( (iter * 7 + d * 11) % 10000 + 1 )) > "$cur/cpu.weight" 2>/dev/null || true
            fi
        done

        # Also renice tasks randomly
        for pid in $(pgrep -f hackbench 2>/dev/null | shuf | head -3); do
            renice $(( (RANDOM % 39) - 20 )) -p "$pid" 2>/dev/null || true
        done

        if [ $((iter % 50)) -eq 0 ]; then
            echo -e "  ${YELLOW}[iter $iter/$ITERATIONS]${NC}"
            if check_crash; then break; fi
        fi
    done

    for pid in "${pids[@]}"; do
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    for pid in $(cat "$leaf/cgroup.procs" 2>/dev/null); do
        echo "$pid" > "$TEST_ROOT/cgroup.procs" 2>/dev/null || true
    done
    find "$TEST_ROOT/grp_deep" -depth -type d -exec rmdir {} \; 2>/dev/null || true

    echo -e "${GREEN}[*] Phase 7 complete${NC}"
}

# =============================================================================
# Phase 8: Concurrent destroy + tick (targeted UAF)
#
# If the tick fires on a CPU while processing a group entity whose
# gcfs_rq per-cpu memory has been freed and recycled (after
# sched_unregister_group), the load.weight field will contain garbage
# that may have lower 32 bits = 0 after scale_load_down.
# =============================================================================
stress_concurrent_destroy_tick() {
    echo -e "${GREEN}[*] Phase 8: Concurrent destroy + tick (UAF targeting)${NC}"

    # Keep background load running (ticks fire continuously)
    local bg8_pids=()
    for ((i=0; i<8; i++)); do
        hackbench -p -l 1000000 -g $HB_GROUPS -f $HB_FDS &
        bg8_pids+=($!)
    done
    sleep 0.3

    # Rapidly create deep cgroups, move tasks in (triggering enqueue through
    # hierarchy + tick processing), move them out, destroy. Repeat at high rate
    # to maximize slab recycling of per-cpu cfs_rq objects.
    for ((iter=0; iter<ITERATIONS*3; iter++)); do
        local leaf
        leaf=$(create_deep_hierarchy "$TEST_ROOT" "uaf_${iter}")

        # Move running tasks in (they start ticking in this hierarchy)
        for pid in $(pgrep -f hackbench 2>/dev/null | shuf | head -10); do
            echo "$pid" > "$leaf/cgroup.procs" 2>/dev/null || true
        done

        # Churn weight to stress accounting
        echo $(( RANDOM % 10000 + 1 )) > "$leaf/cpu.weight" 2>/dev/null || true

        # Move out and destroy immediately
        for pid in $(cat "$leaf/cgroup.procs" 2>/dev/null); do
            echo "$pid" > "$TEST_ROOT/cgroup.procs" 2>/dev/null || true
        done
        find "$TEST_ROOT/grp_uaf_${iter}" -depth -type d -exec rmdir {} \; 2>/dev/null || true

        if [ $((iter % 100)) -eq 0 ]; then
            echo -e "  ${YELLOW}[iter $iter/$((ITERATIONS*3))]${NC}"
            if check_crash; then
                for pid in "${bg8_pids[@]}"; do kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
                return
            fi
        fi
    done

    for pid in "${bg8_pids[@]}"; do kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
    echo -e "${GREEN}[*] Phase 8 complete${NC}"
}

# =============================================================================
main() {
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN} Flat Pick: propagate_entity_load_avg div0   ${NC}"
    echo -e "${GREEN} Target: scale_load_down u32 truncation      ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo ""
    echo "System: $(nproc) CPUs, kernel $(uname -r)"
    echo "Config: DEPTH=$DEPTH, NUM_GROUPS=$NUM_GROUPS, ITERATIONS=$ITERATIONS"
    echo ""

    check_prerequisites
    cleanup 2>/dev/null || true

    # Enable core dumps
    ulimit -c unlimited
    echo "/tmp/core.%e.%p" > /proc/sys/kernel/core_pattern 2>/dev/null || true

    # Increase console loglevel to see oops
    ORIG_PRINTK_LEVEL=$(cat /proc/sys/kernel/printk)
    echo 8 > /proc/sys/kernel/printk

    # Clear dmesg
    dmesg -C 2>/dev/null || true

    mkdir -p "$TEST_ROOT"
    echo "+cpu" > "$TEST_ROOT/cgroup.subtree_control" 2>/dev/null || true

    # Phase 1: Tick path + weight churn (most likely to hit)
    stress_tick_weight_churn
    if check_crash; then exit 0; fi

    # Phase 2: Migration between groups under tick
    stress_migration_under_tick
    if check_crash; then exit 0; fi

    # Phase 3: Create/destroy storm
    stress_create_destroy_under_tick
    if check_crash; then exit 0; fi

    # Phase 4: Mixed nice values
    stress_mixed_nice_weights
    if check_crash; then exit 0; fi

    # Phase 5: Affinity storm
    stress_affinity_storm
    if check_crash; then exit 0; fi

    # Phase 6: Throttle/unthrottle burst
    stress_throttle_burst
    if check_crash; then exit 0; fi

    # Phase 7: Extreme depth (32 levels)
    stress_extreme_depth
    if check_crash; then exit 0; fi

    # Phase 8: Concurrent destroy + tick
    stress_concurrent_destroy_tick
    if check_crash; then exit 0; fi

    echo ""
    echo -e "${GREEN}[*] All phases complete.${NC}"
    echo -e "${YELLOW}[*] No crash detected. Try:${NC}"
    echo -e "${YELLOW}    - Increasing ITERATIONS (current: $ITERATIONS)${NC}"
    echo -e "${YELLOW}    - Running on more CPUs (current: $ONLINE_CPUS)${NC}"
    echo -e "${YELLOW}    - Running multiple instances in parallel${NC}"
    echo -e "${YELLOW}    - Check dmesg: dmesg | grep -i 'divide\|oops'${NC}"
}

main "$@"
