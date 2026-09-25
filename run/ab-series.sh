#!/usr/bin/env bash
# Interleaved A/B series for the per-cpu assertion, 2026-09-23/24 (runs 75+).
# A = base Xen 08074f7f22ee, B = exp 6+7 Xen 4307f2165ce4 (this_cpu_ptr fix + place_modules backport).
# Per-run logic copied from builder run/kdisk-series-pcpu.sh (stops on Assertion); differences:
# swaps the installed Xen binary before each run and records its sha256, caps a run at 1800 s
# (normal runs take 585-906 s), and stops starting pairs at a wall-clock cutoff.
# Usage: bash ab-series.sh <first-run-number> <cutoff-epoch>
set -u
R=$HOME/xen-run; IMG=$R/initrd-tools-kdisk.img; OUT=$R/ab-series.log
XEN=$R/xen/xen/xen
A_BIN=$R/xen-bin-pgoar-08074f7f22ee; A_SHA=08074f7f22ee78bdc54acf7503729240cb08d5d459c381107fd527b2ecce64dc
B_BIN=$R/xen-bin-pcpu-4307f2165ce4;  B_SHA=4307f2165ce4cd2c4bd0611158ba693a24bcc63f9922e9f43361b2eda811a721
N=$1; CUTOFF=$2; CAP=1800
clean() { for p in $(pgrep -f "^timeout 8000 bash") $(pgrep -f "^bash $R/xen-run2"); do kill $p 2>/dev/null; done; }
install_bin() {   # install_bin <A|B>; aborts the series if the sha does not match
	local src sha want
	if [ "$1" = A ]; then src=$A_BIN; want=$A_SHA; else src=$B_BIN; want=$B_SHA; fi
	cp "$src" "$XEN"; sync
	sha=$(sha256sum "$XEN" | cut -d" " -f1)
	[ "$sha" = "$want" ] || { echo "ABORT: installed sha $sha != $want for arm $1" >> $OUT; exit 1; }
	echo "$sha"
}
one() {   # one <N> <arm A|B> <multinode 0|1>
	local n=$1 arm=$2 mn=$3 L=$R/xen-domu-run$1.log pid t0 sha why=cap c
	sha=$(install_bin $arm) || exit 1
	clean; sleep 5
	t0=$(date +%s)
	setsid env RCS_DEVFIX=1 WITH_DISK=1 DISK_MB=512 K3S_DISK=1 MULTINODE=$mn DOM0_MEM=1024M \
		WAIT_LOG=$L POSTCREATE=3600 bash $R/run.sh $n $IMG &
	pid=$!
	while :; do
		sleep 20
		if [ "$mn" = 1 ]; then
			grep -aq -- "---AGENT-LOG-END---" $L 2>/dev/null && grep -aq "^---HOTPLUG-END---" $L && { why=end; break; }
		else
			grep -aq "^---HOTPLUG-END---" $L 2>/dev/null && { why=end; break; }
		fi
		grep -aq -E "Kernel panic|Unhandled exception|Assertion .* failed" $L 2>/dev/null && { why=fault; break; }
		kill -0 $pid 2>/dev/null || { why=exited; break; }
		[ $(( $(date +%s) - t0 )) -ge $CAP ] && { why=cap; break; }
		[ $(date +%s) -ge $CUTOFF ] && { why=cutoff; break; }
	done
	sleep 5
	podman stop -t 5 xen-run$n >/dev/null 2>&1
	kill -- -$pid 2>/dev/null; wait $pid 2>/dev/null; clean
	c() { grep -a -c -E "$@" "$L"; }
	echo "run$n arm=$arm mn=$mn sha=${sha:0:12} start=$(date -d @$t0 -Is) wall=$(( $(date +%s) - t0 ))s stop=$why" \
		"assert=$(c 'Assertion .* failed') panic=$(c -i 'panic|Unhandled exception') k3sok=$(c K3S_OK)" \
		"sumk3sok=$(c 'SUMMARY.*k3s=ok') hpend=$(c '^---HOTPLUG-END---') agentend=$(c -- '---AGENT-LOG-END---')" \
		"poweroff=$(c 'reboot: Power down') banner=\"$(grep -a -m1 'Xen version' $L | sed 's/.*debug=y //' | tr -d '\r')\"" >> $OUT
}
echo "AB_SERIES_START $(date -Is) first=$N cutoff=$(date -d @$CUTOFF -Is)" >> $OUT
k=0
while :; do
	# a pair takes at most ~2x15 min when clean; do not start one that cannot finish by the cutoff
	[ $(( $(date +%s) + 1920 )) -le $CUTOFF ] || break
	mn=$(( k % 2 ))
	if [ $(( (k / 2) % 2 )) = 0 ]; then order="A B"; else order="B A"; fi
	for arm in $order; do one $N $arm $mn; N=$((N + 1)); done
	k=$((k + 1))
done
install_bin A >/dev/null && echo "AB_SERIES_DONE $(date -Is) pairs=$k installed=$(sha256sum $XEN | cut -c1-12)" >> $OUT
