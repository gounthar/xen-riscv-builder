#!/usr/bin/env bash
# Runs 69-74 (2026-09-23): boot Xen with dom0_mem=3072M only until dom0 banks and initrd placement print, then stop.
# Usage: bash bank-series.sh <N>:<XEN_EXTRA or -> ...
set -u
R=$HOME/xen-run; IMG=$R/initrd-tools-kdisk.img
clean() { for p in $(pgrep -f "^timeout 8000 bash") $(pgrep -f "^bash $R/xen-run2"); do kill $p 2>/dev/null; done; }
one() {
	local n=$1 extra=$2 L=$R/xen-domu-run$1.log pid t0
	[ "$extra" = "-" ] && extra=""
	clean; sleep 5; t0=$(date +%s)
	setsid env RCS_DEVFIX=1 WITH_DISK=1 DISK_MB=512 K3S_DISK=1 MULTINODE=0 DOM0_MEM=3072M XEN_EXTRA="$extra" \
		POSTCREATE=600 bash $R/run-bank.sh $n $IMG &
	pid=$!
	while :; do
		sleep 5
		grep -aq "Loading d0 initrd" $L 2>/dev/null && { sleep 10; break; }
		grep -aq -E "Unhandled exception|Assertion .* failed|panic" $L 2>/dev/null && break
		kill -0 $pid 2>/dev/null || break
		[ $(( $(date +%s) - t0 )) -ge 1200 ] && break
	done
	podman stop -t 5 xen-run$n >/dev/null 2>&1
	kill -- -$pid 2>/dev/null; wait $pid 2>/dev/null; clean
	{ echo "run$n bank xen_extra=[$extra] $(date -Is) wall=$(( $(date +%s) - t0 ))s"
	  grep -a -E "^\(XEN\) (Command line|Allocated 0x|BANK\[|Loading d0 initrd)" $L | tr -d "\r"; } >> $R/bank.log
}
for a in "$@"; do one "${a%%:*}" "${a#*:}"; done
echo BANK_SERIES_DONE >> $R/bank.log
