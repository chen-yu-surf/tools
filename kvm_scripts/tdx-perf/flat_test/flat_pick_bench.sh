#!/usr/bin/env bash
# flat_pick_bench.sh — Performance regression / improvement benchmarks for the
# EEVDF flat-pick series ("sched/eevdf: Move to a single runqueue").
#
# Sweeps cgroup nesting depth using established open-source benchmarks:
#   - hackbench            : throughput (seconds, lower = better)
#   - schbench             : wakeup latency p99 (usec, lower = better)
#   - perf bench sched msg : messaging throughput (seconds, lower = better)
#   - perf bench sched pipe: pipe context-switch (seconds, lower = better)
#   - sysbench cpu         : events/sec (higher = better)
#   - stress-ng --fork     : fork throughput (bogo-ops/sec, higher = better)
#   - stress-ng --context  : context-switch rate (bogo-ops/sec, higher = better)
#   - cyclictest           : worst-case wakeup latency (usec, lower = better)
#
# The flat series removes per-level pick descent (improves with depth) but adds
# per-tick __calc_prop_weight() walks and reweight_eevdf() (costs grow with
# depth). The depth sweep exposes both effects.
#
# Run on unpatched and patched kernels, then compare CSVs with compare.sh.
set -euo pipefail

# ---- tunables (override via env) -------------------------------------------
DEPTHS=${DEPTHS:-"1 2 4 8 16 32"}
RUNS=${RUNS:-5}

# hackbench
HB_GROUPS=${HB_GROUPS:-$(nproc)}
HB_LOOPS=${HB_LOOPS:-10000}

# schbench
SCH_MSG=${SCH_MSG:-2}
SCH_WORKERS=${SCH_WORKERS:-$(nproc)}
SCH_RUNTIME=${SCH_RUNTIME:-30}

# perf bench sched messaging
PB_GROUPS=${PB_GROUPS:-$(nproc)}
PB_LOOPS=${PB_LOOPS:-10000}

# sysbench cpu
SB_THREADS=${SB_THREADS:-$(nproc)}
SB_DURATION=${SB_DURATION:-10}

# stress-ng
SF_DURATION=${SF_DURATION:-10}
SF_WORKERS=${SF_WORKERS:-$(nproc)}

# cyclictest
CT_DURATION=${CT_DURATION:-10}
CT_THREADS=${CT_THREADS:-$(nproc)}
CT_INTERVAL=${CT_INTERVAL:-1000}       # usec

CG=/sys/fs/cgroup
ROOT=$CG/picktest
OUT=results_$(uname -r).csv
# ----------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $(id -u) == 0 ]] || die "run as root"
[[ -e $CG/cgroup.controllers ]] || die "need cgroup v2"

# Check tools — warn but do not abort
for cmd in hackbench schbench perf sysbench stress-ng cyclictest; do
	command -v "$cmd" >/dev/null || echo "WARNING: $cmd not found — skipping that benchmark"
done

# CPU frequency stabilization
command -v cpupower >/dev/null && cpupower frequency-set -g performance >/dev/null 2>&1 || true
[[ -w /sys/devices/system/cpu/intel_pstate/no_turbo ]] && echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true

cleanup() {
	set +e
	find "$ROOT" -depth -type d 2>/dev/null | while read -r d; do
		[[ -f "$d/cgroup.procs" ]] && while read -r p; do
			echo "$p" > "$CG/cgroup.procs" 2>/dev/null
		done < "$d/cgroup.procs"
		rmdir "$d" 2>/dev/null
	done
}
trap cleanup EXIT

mkdir -p "$ROOT"
echo "+cpu" > "$ROOT/cgroup.subtree_control" 2>/dev/null || true

make_chain() {
	local depth=$1 p="$ROOT"
	for ((i=1; i<=depth; i++)); do
		p="$p/l$i"
		mkdir -p "$p"
		(( i < depth )) && echo "+cpu" > "$p/cgroup.subtree_control" 2>/dev/null || true
	done
	echo "$p"
}

# Run a command inside a cgroup leaf (the calling shell moves into cg first)
run_in_cg() {
	local leaf=$1; shift
	bash -c 'echo $BASHPID > "'"$leaf"'/cgroup.procs" 2>/dev/null; exec "$@"' _ "$@"
}

# ---- benchmark functions (each prints a single metric value) ---------------

bench_hackbench() {
	local leaf=$1
	command -v hackbench >/dev/null || { echo "NA"; return; }
	run_in_cg "$leaf" hackbench -pipe -g "$HB_GROUPS" -l "$HB_LOOPS" 2>&1 \
		| awk '/Time:/{print $2}'
}

bench_schbench() {
	local leaf=$1
	command -v schbench >/dev/null || { echo "NA"; return; }
	run_in_cg "$leaf" schbench -m "$SCH_MSG" -t "$SCH_WORKERS" -r "$SCH_RUNTIME" 2>&1 \
		| awk '
		/[Ww]akeup [Ll]atencies/ { sec="wakeup"; next }
		/[Rr]equest [Ll]atencies|RPS/ { sec="other"; next }
		sec=="wakeup" && /99\.0+th:/ && !/\*/ { wk=$NF }
		END { print (wk=="" ? "NA" : wk) }'
}

bench_perf_msg() {
	local leaf=$1
	command -v perf >/dev/null || { echo "NA"; return; }
	run_in_cg "$leaf" perf bench sched messaging -p -g "$PB_GROUPS" -l "$PB_LOOPS" 2>&1 \
		| awk '/Total time:/{gsub(/\[|\]|sec/,"",$NF); print $NF}'
}

bench_perf_pipe() {
	local leaf=$1
	command -v perf >/dev/null || { echo "NA"; return; }
	run_in_cg "$leaf" perf bench sched pipe -l 1000000 2>&1 \
		| awk '/Total time:/{gsub(/\[|\]|sec/,"",$NF); print $NF}'
}

bench_sysbench() {
	local leaf=$1
	command -v sysbench >/dev/null || { echo "NA"; return; }
	run_in_cg "$leaf" sysbench cpu --threads="$SB_THREADS" --time="$SB_DURATION" run 2>&1 \
		| awk '/events per second:/{print $NF}'
}

bench_stressng_fork() {
	local leaf=$1
	command -v stress-ng >/dev/null || { echo "NA"; return; }
	run_in_cg "$leaf" stress-ng --fork "$SF_WORKERS" --timeout "${SF_DURATION}s" \
		--metrics-brief 2>&1 \
		| awk '/fork/{print $(NF-1)}'
}

bench_stressng_ctx() {
	local leaf=$1
	command -v stress-ng >/dev/null || { echo "NA"; return; }
	run_in_cg "$leaf" stress-ng --context "$SF_WORKERS" --timeout "${SF_DURATION}s" \
		--metrics-brief 2>&1 \
		| awk '/context/{print $(NF-1)}'
}

bench_cyclictest() {
	local leaf=$1
	command -v cyclictest >/dev/null || { echo "NA"; return; }
	# Run as SCHED_OTHER to test CFS wakeup latency (not RT)
	run_in_cg "$leaf" cyclictest -D "$CT_DURATION" -t "$CT_THREADS" \
		-i "$CT_INTERVAL" -q --policy other 2>&1 \
		| awk '/Max Latencies/{split($0,a,":"); gsub(/ /,"",a[2]);
			n=split(a[2],v,/ +/); m=0;
			for(i=1;i<=n;i++) if(v[i]+0>m) m=v[i]+0;
			print (m?m:"NA")}'
}

# ---- main loop -------------------------------------------------------------
echo "kernel,bench,depth,param,run,metric" > "$OUT"
echo "== flat_pick_bench: depths=[$DEPTHS] runs=$RUNS kernel=$(uname -r) =="
echo

for d in $DEPTHS; do
	echo "--- depth=$d ---"
	cleanup 2>/dev/null || true
	mkdir -p "$ROOT"
	echo "+cpu" > "$ROOT/cgroup.subtree_control" 2>/dev/null || true
	leaf=$(make_chain "$d")

	for ((r=1; r<=RUNS; r++)); do
		t=$(bench_hackbench "$leaf")
		echo "$(uname -r),hackbench,$d,$HB_GROUPS,$r,${t:-NA}" | tee -a "$OUT"
	done

	for ((r=1; r<=RUNS; r++)); do
		t=$(bench_schbench "$leaf")
		echo "$(uname -r),schbench,$d,$SCH_WORKERS,$r,${t:-NA}" | tee -a "$OUT"
	done

	for ((r=1; r<=RUNS; r++)); do
		t=$(bench_perf_msg "$leaf")
		echo "$(uname -r),perf_msg,$d,$PB_GROUPS,$r,${t:-NA}" | tee -a "$OUT"
	done

	for ((r=1; r<=RUNS; r++)); do
		t=$(bench_perf_pipe "$leaf")
		echo "$(uname -r),perf_pipe,$d,1M,$r,${t:-NA}" | tee -a "$OUT"
	done

	for ((r=1; r<=RUNS; r++)); do
		t=$(bench_sysbench "$leaf")
		echo "$(uname -r),sysbench,$d,$SB_THREADS,$r,${t:-NA}" | tee -a "$OUT"
	done

	for ((r=1; r<=RUNS; r++)); do
		t=$(bench_stressng_fork "$leaf")
		echo "$(uname -r),stressng_fork,$d,$SF_WORKERS,$r,${t:-NA}" | tee -a "$OUT"
	done

	for ((r=1; r<=RUNS; r++)); do
		t=$(bench_stressng_ctx "$leaf")
		echo "$(uname -r),stressng_ctx,$d,$SF_WORKERS,$r,${t:-NA}" | tee -a "$OUT"
	done

	for ((r=1; r<=RUNS; r++)); do
		t=$(bench_cyclictest "$leaf")
		echo "$(uname -r),cyclictest,$d,$CT_THREADS,$r,${t:-NA}" | tee -a "$OUT"
	done
done

echo
echo "== medians =="
awk -F, 'NR>1 && $6!="NA"{k=$2"|"$3; a[k]=a[k]" "$6}
END{
	for (k in a){ n=split(a[k],v," "); asort(v);
		split(k,p,"|");
		printf "%-15s depth=%-3s median=%s\n", p[1], p[2], v[int((n+1)/2)] }
}' "$OUT" | sort -k1,1 -k2.7n
echo
echo "Results: $OUT"
