#!/usr/bin/env bash
# RFC-as-sent series, 2026-09-25/26 (runs 202+). Copy of ac-series.sh.
# Every run: Xen built from gitlab gounthar/xen rfc/domu-experiments-2026-09-25 @ d425b43c60 (783835cbda89),
# tools from the same tree. Arms differ only in the guest kernel inside the dom0 image:
#   G2 = pre-0003 guest (6ca55de83440, the A/C series guest), image initrd-tools-rfc-g2.img
#   G3 = Linux RFC guest @ 79db70fe3a incl. 0003 DT detection (79318495d69f), image initrd-tools-rfc-g3.img
# Per-run logic copied from builder run/kdisk-series-pcpu.sh (stops on Assertion); differences:
# swaps the installed Xen binary before each run and records its sha256, caps a run at 1800 s
# (normal runs take 585-906 s), and stops starting pairs at a wall-clock cutoff.
# Usage: bash ab-series.sh <first-run-number> <cutoff-epoch>
set -u
R=$HOME/xen-run; OUT=$R/rfc-series.log
XEN=$R/xen/xen/xen
RFC_BIN=$R/xen-bin-rfc-783835cbda89; RFC_SHA=783835cbda89f4faa0ecd697702e59a1df11ad617f8e52a5c4e94e0e1bf44bd4
BASE_BIN=$R/xen-bin-pgoar-08074f7f22ee; BASE_SHA=08074f7f22ee78bdc54acf7503729240cb08d5d459c381107fd527b2ecce64dc
N=$1; CUTOFF=$2; CAP=1800
clean() { for p in $(pgrep -f "^timeout 8000 bash") $(pgrep -f "^bash $R/xen-run2"); do kill $p 2>/dev/null; done; }
install_bin() {   # install_bin <rfc|base>; aborts the series if the sha does not match
	local src sha want
	if [ "$1" = rfc ]; then src=$RFC_BIN; want=$RFC_SHA; else src=$BASE_BIN; want=$BASE_SHA; fi
	cp "$src" "$XEN"; sync
	sha=$(sha256sum "$XEN" | cut -d" " -f1)
	[ "$sha" = "$want" ] || { echo "ABORT: installed sha $sha != $want for $1" >> $OUT; exit 1; }
	echo "$sha"
}
one() {   # one <N> <arm G2|G3> <multinode 0|1>
	local n=$1 arm=$2 mn=$3 L=$R/xen-domu-run$1.log pid t0 sha why=cap c
	sha=$(install_bin rfc) || exit 1
	IMG=$R/initrd-tools-rfc-$(echo $arm | tr G g).img
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
	echo "run$n arm=$arm mn=$mn sha=${sha:0:12} img=$(sha256sum $IMG | cut -c1-12) start=$(date -d @$t0 -Is) wall=$(( $(date +%s) - t0 ))s stop=$why" \
		"assert=$(c 'Assertion .* failed') panic=$(c -i 'panic|Unhandled exception') k3sok=$(c K3S_OK)" \
		"sumk3sok=$(c 'SUMMARY.*k3s=ok') hpend=$(c '^---HOTPLUG-END---') agentend=$(c -- '---AGENT-LOG-END---')" \
		"poweroff=$(c 'reboot: Power down') banner=\"$(grep -a -m1 'Xen version' $L | sed 's/.*debug=y //' | tr -d '\r')\"" >> $OUT
}
echo "RFC_SERIES_START $(date -Is) first=$N cutoff=$(date -d @$CUTOFF -Is)" >> $OUT
k=0
while :; do
	# a pair takes at most ~2x15 min when clean; do not start one that cannot finish by the cutoff
	[ $(( $(date +%s) + 1920 )) -le $CUTOFF ] || break
	mn=$(( k % 2 ))
	if [ $(( (k / 2) % 2 )) = 0 ]; then order="G2 G3"; else order="G3 G2"; fi
	for arm in $order; do one $N $arm $mn; N=$((N + 1)); done
	k=$((k + 1))
done
install_bin base >/dev/null && echo "RFC_SERIES_DONE $(date -Is) pairs=$k installed=$(sha256sum $XEN | cut -c1-12)" >> $OUT
