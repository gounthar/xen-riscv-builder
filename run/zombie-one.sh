#!/usr/bin/env bash
# COPY of restart-one.sh for the 2026-09-24 zombie-domU and 2-vCPU runs
# (119+), not committed. One run: zombie-one.sh <N> <image> [VAR=val...]
# Driver xen-run2-zombie.sh, RCS_DEVFIX=1 WITH_DISK=1. RUNSH picks a copy of
# run.sh (run-gen.sh mounts $GEN as generate_dtb.sh). Stops on the end marker,
# a Xen assertion or panic, or after CAP seconds.
set -u
R=$HOME/xen-run; n=$1; IMG=$2; shift 2
L=$R/xen-domu-run$n.log T=$R/times-run$n.log CAP=${CAP:-7200}
t0=$(date +%s)
echo "run$n start $(date -Is) args: $*" > "$T"
setsid env RCS_DEVFIX=1 WITH_DISK=1 "$@" \
	WAIT_LOG="$L" POSTCREATE=3600 DRIVER=xen-run2-zombie.sh bash "$R/${RUNSH:-run.sh}" "$n" "$IMG" &
pid=$!
seen=""
while :; do
	sleep 10
	for m in ^PAYLOAD_START ^K3S_OK ^K3S_FAIL ^PAYLOAD_DONE 'reboot: Power down' 0x53525354 'smp: Brought up' 'CPU1: failed' ; do
		c=$(grep -ac -- "$m" "$L" 2>/dev/null); c=${c:-0}
		k="$m#$c"
		case " $seen " in *" ${k// /_} "*) ;; *)
			[ "$c" -gt 0 ] && { echo "$(( $(date +%s) - t0 ))s host: '$m' count=$c" >> "$T"; seen="$seen ${k// /_}"; } ;;
		esac
	done
	grep -aqE "^---(ZOMBIE|SMP)-END---" "$L" 2>/dev/null && break
	grep -aq -E "Kernel panic|Unhandled exception|Assertion .* failed|Oops" "$L" 2>/dev/null && { echo "stopped on error" >> "$T"; break; }
	kill -0 $pid 2>/dev/null || break
	[ $(( $(date +%s) - t0 )) -ge "$CAP" ] && { echo "stopped at cap" >> "$T"; break; }
done
sleep 5
podman stop -t 5 xen-run$n >/dev/null 2>&1
kill -- -$pid 2>/dev/null; wait $pid 2>/dev/null
echo "run$n end $(date -Is) wall=$(( $(date +%s) - t0 ))s" >> "$T"
grep -a -E "cpus:|smp: Brought|CPU1|Assertion|0x53525354|^STEP" "$L" | tr -d '\r' >> "$T"
echo RUN_DONE >> "$T"
