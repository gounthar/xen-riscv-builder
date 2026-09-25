#!/usr/bin/env bash
# k3s.disk series, 2026-09-23: runs 53-54 single-node, 55 two-node with the
# server state on the PV disk. Image initrd-tools-kdisk.img (15709cb9d2e5).
set -u
R=$HOME/xen-run; IMG=$R/initrd-tools-kdisk.img
clean() { for p in $(pgrep -f "^timeout 8000 bash") $(pgrep -f "^bash $R/xen-run2"); do kill $p 2>/dev/null; done; }
one() {   # one <N> <multinode 0|1>
	local n=$1 mn=$2 L=$R/xen-domu-run$1.log pid t0
	clean; sleep 5
	t0=$(date +%s)
	setsid env RCS_DEVFIX=1 WITH_DISK=1 DISK_MB=512 K3S_DISK=1 MULTINODE=$mn \
		WAIT_LOG=$L POSTCREATE=3600 bash $R/run.sh $n $IMG &
	pid=$!
	while :; do
		sleep 20
		if [ "$mn" = 1 ]; then
			grep -aq -- "---AGENT-LOG-END---" $L 2>/dev/null && grep -aq "^---HOTPLUG-END---" $L && break
		else
			grep -aq "^---HOTPLUG-END---" $L 2>/dev/null && break
		fi
		grep -aq -E "Kernel panic|Unhandled exception" $L 2>/dev/null && break
		kill -0 $pid 2>/dev/null || break
		[ $(( $(date +%s) - t0 )) -ge 5400 ] && break
	done
	sleep 5
	podman stop -t 5 xen-run$n >/dev/null 2>&1
	kill -- -$pid 2>/dev/null; wait $pid 2>/dev/null; clean
	{ echo "run$n kdisk mn=$mn $(date -Is) wall=$(( $(date +%s) - t0 ))s"
	  grep -a -E "SUMMARY|K3S_FAIL|k3s.disk: at K3S_OK|pod ran on node" $L | tr -d "\r"; } >> $R/repeat2.log
}
# Arguments: N:multinode pairs, e.g. 56:1
for a in "$@"; do one "${a%%:*}" "${a##*:}"; done
echo KDISK_SERIES_DONE >> $R/repeat2.log
