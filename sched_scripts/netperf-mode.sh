#!/bin/bash
# netperf-mode.sh
#
# Two comparison axes, selected with COMPARE:
#
#   COMPARE=mode (default)
#     cgroup_mode = smp vs concur, with sched_feat WA_WEIGHT kept ON for both.
#
#   COMPARE=feat
#     cgroup_mode is pinned to $FIX_MODE and never touched between runs;
#     sched_feat is flipped WA_WEIGHT vs NO_WA_WEIGHT instead.  Everything
#     else -- cgroup layout, governor, C-states, flow count, round-robin
#     ordering, statistics -- is identical to the cgroup_mode comparison.
#
# Same measurement methodology as netperf-raw.sh:
#
#   - BOTH netserver and the netperf clients run inside a cgroup that this
#     script creates (default /sys/fs/cgroup/$CG_NAME, cpu controller on).
#     The shell is moved into the cgroup before anything is forked, so every
#     child inherits it -- there is no per-pid migration race.
#   - with SPLIT_CG=1 the server and the clients get two sibling child
#     cgroups instead, which is the configuration that silently invalidated
#     the earlier measurements when netserver was left in
#     /system.slice/netperf.service.  Default is 0 (one shared cgroup).
#   - configs are executed round-robin instead of back-to-back, and repeated
#     ROUNDS times, because ordering effects on this box are large
#
# This one also writes /sys/kernel/debug/sched/cgroup_mode, and forces
# WA_WEIGHT on before every measurement.
#
#   ./netperf-mode.sh                  # run the cgroup_mode comparison
#   ./netperf-mode.sh feat             # run the WA_WEIGHT on/off comparison
#   ./netperf-mode.sh summary mode     # re-print the cgroup_mode stats
#   ./netperf-mode.sh summary feat     # re-print the WA_WEIGHT stats
#   ./netperf-mode.sh summary all      # re-print both
#   ./netperf-mode.sh restore          # re-enable deep C-states
#   ./netperf-mode.sh cgclean          # remove a leftover test cgroup
#
# The two axes write separate result files, $RESULT_DIR/res.mode.txt and
# $RESULT_DIR/res.feat.txt, so running one does not destroy the other's data.
# A bare 'summary' defaults to whatever COMPARE= says, i.e. 'mode'.
#
# Env knobs: RUNTIME NR_THREADS TEST ROUNDS RESULT_DIR DISABLE_C6
#            STOP_SERVICE CPU_UTIL COMPARE FEAT MODES RESTORE_MODE
#            FIX_MODE FEATS RESTORE_FEAT
#            USE_CGROUP CG_NAME SPLIT_CG CG_WEIGHT

RUNTIME=${RUNTIME:-60}
NR_THREADS=${NR_THREADS:-$(($(nproc) * 2))}
TEST=${TEST:-TCP_MAERTS}
ROUNDS=${ROUNDS:-4}
RESULT_DIR=${RESULT_DIR:-/tmp/netperf-mode}
DISABLE_C6=${DISABLE_C6:-1}
STOP_SERVICE=${STOP_SERVICE:-1}
CPU_UTIL=${CPU_UTIL:-0}

# what is varied between runs: "mode" = cgroup_mode, "feat" = sched_feat
COMPARE=${COMPARE:-mode}

# COMPARE=mode: cgroup_mode is the variable, this sched_feat is forced
FEAT=${FEAT:-WA_WEIGHT}
MODES=${MODES:-"smp concur"}
RESTORE_MODE=${RESTORE_MODE:-concur}

# COMPARE=feat: sched_feat is the variable, cgroup_mode is pinned
FIX_MODE=${FIX_MODE:-concur}
FEATS=${FEATS:-"WA_WEIGHT NO_WA_WEIGHT"}
RESTORE_FEAT=${RESTORE_FEAT:-WA_WEIGHT}

USE_CGROUP=${USE_CGROUP:-1}
CG_NAME=${CG_NAME:-netperf_test}
SPLIT_CG=${SPLIT_CG:-0}
CG_WEIGHT=${CG_WEIGHT:-}

FEATF=/sys/kernel/debug/sched/features
MODEF=/sys/kernel/debug/sched/cgroup_mode
CG_BASE=/sys/fs/cgroup
NS_PID=""
CG_ORIG=""
CG_MADE=""
CG_LAST=""
CG_SERVER=""
CG_CLIENT=""

# Each axis keeps its own result file, so a feat run does not clobber the
# numbers from a previous mode run and both can be summarised afterwards.
# The per-flow raw logs are named after the config, which never collides
# between the two axes (smp/concur vs WA_WEIGHT/NO_WA_WEIGHT).
cfg_list()   # axis -> the configs to round-robin over
{
	case "$1" in
	mode)	echo "$MODES" ;;
	feat)	echo "$FEATS" ;;
	*)	echo "FATAL: COMPARE must be 'mode' or 'feat', got '$1'" >&2; exit 1 ;;
	esac
}

res_file()   # axis -> where its res lines live
{
	echo "$RESULT_DIR/res.$1.txt"
}

CFGS_STR=$(cfg_list "$COMPARE") || exit 1
RES=$(res_file "$COMPARE")

# ---------------------------------------------------------------------------
set_performance_governor()
{
	local cpu_dir online_file file
	for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
		online_file="$cpu_dir"/online
		[ -f "$online_file" ] && [ "$(cat "$online_file")" -eq 0 ] && continue

		file="$cpu_dir"/cpufreq/scaling_governor
		[ -f "$file" ] && echo performance | sudo tee "$file" >/dev/null
	done
}

find_deep_states()
{
	local s lat
	for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
		lat=$(cat "$s"/latency 2>/dev/null) || continue
		[ "${lat:-0}" -ge 50 ] && echo "${s##*/state}"
	done
}

set_cstates()   # 1 = disable deep states, 0 = enable
{
	local want=$1 st cpu
	for st in $(find_deep_states); do
		for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
			[ -f "$cpu/cpuidle/state$st/disable" ] || continue
			echo "$want" | sudo tee "$cpu/cpuidle/state$st/disable" >/dev/null
		done
	done
}

# "up smp (concur) max tasks" -> "concur"
cur_mode()
{
	sudo cat $MODEF 2>/dev/null | tr ' ' '\n' | sed -n 's/^(\(.*\))$/\1/p'
}

# readback of one feature, as "WA_WEIGHT" or "NO_WA_WEIGHT"
cur_feat()   # feature name, with or without the NO_ prefix
{
	sudo cat $FEATF 2>/dev/null | tr ' ' '\n' | grep -E "^(NO_)?${1#NO_}$"
}

show_env()
{
	local ns_pid ns_cg
	ns_pid=$(pgrep -o -x netserver 2>/dev/null)
	ns_cg=$(cut -d: -f3 /proc/${ns_pid:-0}/cgroup 2>/dev/null)

	echo "kernel        : $(uname -r)"
	echo "nproc / flows : $(nproc) / $NR_THREADS"
	echo "test / dur    : $TEST / ${RUNTIME}s, $ROUNDS round(s), round-robin"
	if [ "$COMPARE" = feat ]; then
		echo "compare       : sched_feat $FEATS,  cgroup_mode pinned to $FIX_MODE"
	else
		echo "compare       : cgroup_mode $MODES,  sched_feat forced to $FEAT"
	fi
	echo "cgroup_mode   : $(sudo cat $MODEF 2>/dev/null)   (will be modified)"
	echo "sched_feat    : $(cur_feat WA_WEIGHT)   (will be modified)"
	echo "governors     : $(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | tr '\n' ' ')"
	local st
	for st in $(find_deep_states); do
		echo "  deep Cstate $st: $(cat /sys/devices/system/cpu/cpu0/cpuidle/state$st/name) lat=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state$st/latency) disable=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state$st/disable)"
	done
	echo "self cgroup   : $(cut -d: -f3 /proc/self/cgroup)"
	echo "netserver     : $(pgrep -x netserver 2>/dev/null | wc -l) proc(s)${ns_pid:+, cgroup $ns_cg}"
}

# ---------------------------------------------------------------------------
# cgroup v2 handling.  Both sides of the workload are placed in a cgroup that
# this script creates, so that tg->shares and the task_h_load() truncation
# depth are identical and known, instead of being whatever the login session
# and systemd happened to leave behind.
cg_depth()
{
	echo "$1" | awk -F/ '{ n = 0; for (i = 1; i <= NF; i++) if ($i != "") n++; print n }'
}

# a cgroup may only gain a controller if its parent delegates it, and a cgroup
# that already holds processes cannot enable subtree_control -- so this is only
# ever called on ancestors, never on the leaf we are about to populate.
cg_enable_cpu()   # dir
{
	local d=$1
	grep -qw cpu "$d/cgroup.subtree_control" 2>/dev/null && return 0
	grep -qw cpu "$d/cgroup.controllers" 2>/dev/null || {
		echo "FATAL: cpu controller not available in $d"; exit 1; }
	echo +cpu | sudo tee "$d/cgroup.subtree_control" >/dev/null || {
		echo "FATAL: cannot enable cpu controller in $d"; exit 1; }
}

cg_mkpath()   # relative path below $CG_BASE, e.g. "netperf_test/client"
{
	local rel=$1 cur=$CG_BASE p
	local -a parts
	IFS=/ read -r -a parts <<< "$rel"
	for p in "${parts[@]}"; do
		[ -z "$p" ] && continue
		cg_enable_cpu "$cur"
		cur=$cur/$p
		if [ ! -d "$cur" ]; then
			sudo mkdir "$cur" || { echo "FATAL: mkdir $cur failed"; exit 1; }
			# deepest first, so a plain rmdir loop works
			CG_MADE="$cur${CG_MADE:+ }$CG_MADE"
		fi
	done
	CG_LAST=$cur
}

cg_attach()   # pid dir
{
	[ -n "$2" ] || return 0
	echo "$1" | sudo tee "$2/cgroup.procs" >/dev/null || {
		echo "FATAL: cannot attach pid $1 to $2"; exit 1; }
}

cg_setup()
{
	[ "$USE_CGROUP" = 1 ] || return 0

	CG_ORIG=$(cut -d: -f3 /proc/self/cgroup)

	if [ "$SPLIT_CG" = 1 ]; then
		cg_mkpath "$CG_NAME/server"; CG_SERVER=$CG_LAST
		cg_mkpath "$CG_NAME/client"; CG_CLIENT=$CG_LAST
	else
		cg_mkpath "$CG_NAME"
		CG_SERVER=$CG_LAST
		CG_CLIENT=$CG_LAST
	fi

	if [ -n "$CG_WEIGHT" ]; then
		echo "$CG_WEIGHT" | sudo tee "$CG_BASE/$CG_NAME/cpu.weight" >/dev/null
	fi
}

cg_report()
{
	if [ "$USE_CGROUP" != 1 ]; then
		echo "cgroup        : not managed by this script"
		return
	fi
	local self_cg ns_cg
	self_cg=$(cut -d: -f3 /proc/self/cgroup)
	ns_cg=$(cut -d: -f3 /proc/${NS_PID:-0}/cgroup 2>/dev/null)
	echo "cgroup created: $CG_BASE/$CG_NAME  (SPLIT_CG=$SPLIT_CG)"
	echo "  clients     : $self_cg  depth=$(cg_depth "$self_cg")"
	echo "  netserver   : $ns_cg  depth=$(cg_depth "$ns_cg")"
	echo "  cpu.weight  : $(cat "$CG_BASE/$CG_NAME/cpu.weight" 2>/dev/null)"
	echo "  was         : $CG_ORIG  depth=$(cg_depth "$CG_ORIG")"
	if [ "$self_cg" != "$ns_cg" ]; then
		echo "  NOTE        : server and clients are in DIFFERENT cgroups"
	fi
}

cg_restore()
{
	[ -n "$CG_ORIG" ] || return 0
	# the shell has to leave first, otherwise the rmdir below returns EBUSY
	echo $$ | sudo tee "$CG_BASE$CG_ORIG/cgroup.procs" >/dev/null 2>&1
	local d i
	for i in 1 2 3; do
		local left=""
		for d in $CG_MADE; do
			[ -d "$d" ] || continue
			sudo rmdir "$d" 2>/dev/null || left="$left $d"
		done
		[ -z "$left" ] && break
		sleep 1
	done
	for d in $CG_MADE; do
		[ -d "$d" ] && echo "WARN: could not remove $d"
	done
	CG_ORIG=""
	CG_MADE=""
}

# ---------------------------------------------------------------------------
# netserver must live in the same cgroup as the clients, otherwise the two
# sides of the workload get different tg->shares and different task_h_load()
# truncation depths, which silently invalidates the comparison.
ns_count()
{
	# pgrep -c prints 0 *and* exits 1 when nothing matches, so "|| echo 0"
	# would emit two lines.  Count them ourselves instead.
	pgrep -x netserver 2>/dev/null | wc -l
}

ns_list()
{
	local p
	for p in $(pgrep -x netserver 2>/dev/null); do
		echo "    pid $p uid $(stat -c %u /proc/$p 2>/dev/null) cgroup $(cut -d: -f3 /proc/$p/cgroup 2>/dev/null)"
	done
}

# A netserver instance is usually already running, owned by root, inside
# /system.slice/netperf.service.  It must be gone before we fork our own --
# leaving it alive means the clients talk to a server in a different cgroup,
# which is exactly the confound that invalidated the earlier measurements.
kill_existing_netserver()
{
	local i n

	n=$(ns_count)
	if [ "$n" = 0 ] && [ "$STOP_SERVICE" != 1 ]; then
		return 0
	fi

	if [ "$STOP_SERVICE" != 1 ]; then
		echo "netserver     : $n already running, STOP_SERVICE=0 -- not touching it"
		ns_list
		return 0
	fi

	# Stop the unit even when nothing is running right now, so that it cannot
	# come back in the middle of the campaign.  The unit may be native or a
	# SysV init script picked up by systemd-sysv-generator; handle both.
	if systemctl cat netperf.service >/dev/null 2>&1; then
		echo "netperf.service: $(systemctl is-active netperf.service 2>/dev/null) -- stopping"
		sudo systemctl stop netperf.service >/dev/null 2>&1
	fi
	[ -x /etc/init.d/netperf ] && sudo /etc/init.d/netperf stop >/dev/null 2>&1

	for i in 1 2 3; do
		n=$(ns_count)
		[ "$n" = 0 ] && break
		echo "killing $n leftover netserver process(es), attempt $i:"
		ns_list
		if [ "$i" -lt 3 ]; then
			sudo pkill -x netserver 2>/dev/null
		else
			sudo pkill -9 -x netserver 2>/dev/null
		fi
		sleep 2
	done

	n=$(ns_count)
	if [ "$n" != 0 ]; then
		echo "FATAL: $n netserver process(es) survived SIGKILL:"
		ns_list
		exit 1
	fi
}

start_netserver()
{
	kill_existing_netserver

	if [ "$(ns_count)" != 0 ]; then
		echo "FATAL: a netserver is still running:"
		ns_list
		echo "       it is NOT in this shell's cgroup, results would be invalid."
		echo "       stop it first:  sudo systemctl stop netperf.service"
		exit 1
	fi

	netserver -4 -D > "$RESULT_DIR"/netserver.log 2>&1 &
	NS_PID=$!
	sleep 2
	kill -0 "$NS_PID" 2>/dev/null || {
		echo "FATAL: netserver failed to start"
		cat "$RESULT_DIR"/netserver.log 2>/dev/null
		exit 1
	}
	echo "netserver     : started pid=$NS_PID cgroup=$(cut -d: -f3 /proc/$NS_PID/cgroup)"
}

stop_netserver()
{
	[ -n "$NS_PID" ] && kill $NS_PID 2>/dev/null
	NS_PID=""
}

# ---------------------------------------------------------------------------
one()   # cfg rep
{
	local cfg=$1 rep=$2
	local out=$RESULT_DIR/$cfg.$rep
	local extra="" pids="" i want_mode want_feat rb_mode rb_feat

	kill -0 "$NS_PID" 2>/dev/null || {
		echo "FATAL: netserver (pid $NS_PID) died before $cfg rep$rep"
		tail -5 "$RESULT_DIR"/netserver.log 2>/dev/null
		exit 1
	}

	[ "$CPU_UTIL" = 1 ] && extra="-c -C"

	if [ "$COMPARE" = feat ]; then
		want_mode=$FIX_MODE
		want_feat=$cfg
	else
		want_mode=$cfg
		want_feat=$FEAT
	fi

	# Both knobs are written for every run, including the one that is held
	# constant, so a config never inherits state from the previous run.
	echo "$want_mode" | sudo tee $MODEF >/dev/null
	echo "$want_feat" | sudo tee $FEATF >/dev/null
	rb_mode=$(cur_mode)
	rb_feat=$(cur_feat "$want_feat")
	sleep 2

	if [ "$rb_mode" != "$want_mode" ]; then
		echo "FATAL: cgroup_mode readback '$rb_mode' != requested '$want_mode'"
		exit 1
	fi
	if [ "$rb_feat" != "$want_feat" ]; then
		echo "FATAL: sched_feat readback '$rb_feat' != requested '$want_feat'"
		exit 1
	fi

	rm -f "$out"
	for ((i = 0; i < NR_THREADS; i++)); do
		netperf -4 -H 127.0.0.1 -t "$TEST" $extra -l "$RUNTIME" -P 0 \
			>> "$out" 2>/dev/null &
		pids="$pids $!"
	done
	wait $pids

	# netperf data line: <recv_sock> <send_sock> <msg> <elapsed> <throughput> ...
	# The $1-is-numeric guard drops netperf's "catcher: timer popped ..." noise.
	awk -v m="$cfg" -v r="$rep" -v rb="$rb_mode/$rb_feat" '
		$1 ~ /^[0-9]+$/ && NF >= 5 { s += $5; n++ }
		END { printf "%s %s %.0f %d %s\n", m, r, s, n, rb }
	' "$out" >> "$RES"

	tail -1 "$RES" | awk '{
		printf "    %-12s rep%-2s %10d Mbps  flows=%-4d [%s]\n", $1, $2, $3, $4, $5 }'
}

# ---------------------------------------------------------------------------
summarize()   # [axis], defaults to $COMPARE
{
	local axis=${1:-$COMPARE}
	local res m
	res=$(res_file "$axis")
	local -a cfgs=($(cfg_list "$axis")) || return 1

	if [ ! -s "$res" ]; then
		echo
		echo "==== $axis: no results in $res ===="
		return
	fi

	echo
	echo "==== $axis: raw throughput (Mbps) ===="
	for m in "${cfgs[@]}"; do
		printf "%-12s" "$m"
		awk -v m="$m" '$1 == m { printf " %9d", $3 }' "$res"
		echo
	done

	echo
	echo "==== $axis: stats ===="
	printf "%-12s %10s %10s %10s %10s %7s\n" CONFIG median mean min max cv%
	for m in "${cfgs[@]}"; do
		awk -v m="$m" '
			$1 == m { v[n++] = $3; s += $3 }
			END {
				if (n == 0) exit
				for (i = 0; i < n - 1; i++)
					for (j = 0; j < n - 1 - i; j++)
						if (v[j] > v[j+1]) { t = v[j]; v[j] = v[j+1]; v[j+1] = t }
				mean = s / n
				med  = (n % 2) ? v[int(n/2)] : (v[n/2 - 1] + v[n/2]) / 2
				for (i = 0; i < n; i++) sd += (v[i] - mean) ^ 2
				sd = (n > 1) ? sqrt(sd / (n - 1)) : 0
				printf "%-12s %10.0f %10.0f %10d %10d %6.1f%%\n",
				       m, med, mean, v[0], v[n-1], 100 * sd / mean
			}' "$res"
	done

	[ "${#cfgs[@]}" -ge 2 ] || return

	echo
	awk -v c0="${cfgs[0]}" -v c1="${cfgs[1]}" -v axis="$axis" '
		$1 == c0 { a[na++] = $3 }
		$1 == c1 { b[nb++] = $3 }
		function med(v, n,   i, j, t) {
			for (i = 0; i < n - 1; i++)
				for (j = 0; j < n - 1 - i; j++)
					if (v[j] > v[j+1]) { t = v[j]; v[j] = v[j+1]; v[j+1] = t }
				return (n % 2) ? v[int(n/2)] : (v[n/2 - 1] + v[n/2]) / 2
		}
		END {
			if (na == 0 || nb == 0) exit
			ma = med(a, na); mb = med(b, nb)
			printf "==== %s effect (median) ====\n",
			       (axis == "feat") ? "sched_feat" : "cgroup_mode"
			printf "  %s %10.0f  ->  %s %10.0f   %+.1f%%   (%s/%s = %.3f)\n",
			       c0, ma, c1, mb, 100 * (mb - ma) / ma, c1, c0, mb / ma
		}' "$res"
}

# ---------------------------------------------------------------------------
do_run()
{
	local m
	mkdir -p "$RESULT_DIR"
	# only this axis' data is discarded; the other axis' res file survives
	rm -f "$RES"
	for m in $CFGS_STR; do rm -f "$RESULT_DIR"/"$m".*; done

	set_performance_governor
	[ "$DISABLE_C6" = 1 ] && set_cstates 1

	echo "=============== environment ==============="
	show_env
	trap 'stop_netserver; cg_restore' EXIT
	cg_setup
	# netserver is forked while the shell sits in the server cgroup; cgroup
	# membership does not follow the parent, so moving the shell afterwards
	# leaves netserver where it is.
	cg_attach $$ "$CG_SERVER"
	start_netserver
	cg_attach $$ "$CG_CLIENT"
	cg_report
	echo "==========================================="
	echo

	local CFGS=($CFGS_STR)
	local k j idx
	for ((k = 0; k < ROUNDS; k++)); do
		echo "===== round $((k+1))/$ROUNDS  $(date +%H:%M:%S) ====="
		for ((j = 0; j < ${#CFGS[@]}; j++)); do
			idx=$(( (k + j) % ${#CFGS[@]} ))
			one "${CFGS[$idx]}" "$((k+1))"
		done
	done

	echo "$RESTORE_MODE" | sudo tee $MODEF >/dev/null
	echo "$RESTORE_FEAT" | sudo tee $FEATF >/dev/null
	stop_netserver
	cg_restore

	summarize

	echo
	echo "cgroup_mode restored to: $(sudo cat $MODEF)"
	echo "sched_feat  restored to: $(cur_feat "$RESTORE_FEAT")"
	echo "restore:  ./netperf-mode.sh restore"
	[ "$STOP_SERVICE" = 1 ] && echo "          sudo systemctl start netperf.service"
}

case "$1" in
summary)
	# ./netperf-mode.sh summary [mode|feat|all]   (default: $COMPARE)
	case "${2:-$COMPARE}" in
	all)	summarize mode; summarize feat ;;
	*)	summarize "${2:-$COMPARE}" ;;
	esac
	;;
restore)
	set_cstates 0
	echo "deep C-states re-enabled"
	;;
cgclean)
	sudo rmdir "$CG_BASE/$CG_NAME"/server "$CG_BASE/$CG_NAME"/client 2>/dev/null
	sudo rmdir "$CG_BASE/$CG_NAME" 2>/dev/null
	[ -d "$CG_BASE/$CG_NAME" ] &&
		echo "still present, pids: $(cat "$CG_BASE/$CG_NAME"/cgroup.procs 2>/dev/null | tr '\n' ' ')" ||
		echo "removed $CG_BASE/$CG_NAME"
	;;
feat)
	# WA_WEIGHT on/off with cgroup_mode held at $FIX_MODE
	COMPARE=feat
	CFGS_STR=$(cfg_list feat)
	RES=$(res_file feat)
	do_run
	;;
""|run|mode)
	COMPARE=mode
	CFGS_STR=$(cfg_list mode)
	RES=$(res_file mode)
	do_run
	;;
*)
	echo "usage: $0 [run|mode|feat|summary [mode|feat|all]|restore|cgclean]"
	echo "  run|mode : vary cgroup_mode ($MODES), sched_feat forced to $FEAT"
	echo "  feat     : vary sched_feat ($FEATS), cgroup_mode pinned to $FIX_MODE"
	echo "  summary  : re-print stats for one axis, or 'all' for both"
	echo "results in $RESULT_DIR/res.mode.txt and $RESULT_DIR/res.feat.txt"
	;;
esac
