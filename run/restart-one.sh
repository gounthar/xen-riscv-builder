#!/usr/bin/env bash
# COPY of kdisk-series-pcpu.sh's per-run logic for the 2026-09-24 restart and
# 2-vCPU tests, not committed. One run: restart-one.sh <N> <image> [VAR=val...]
# Always RCS_DEVFIX=1 WITH_DISK=1 DISK_MB=512 K3S_DISK=1, driver
# xen-run2-restart.sh. Extra VAR=val (RESTART=1, VCPUS=2) go to the driver.
# Writes host wall-clock times of the markers to $R/times-runN.log, stops on
# the end marker, a Xen assertion or panic, or after CAP seconds.
set -u
R=$HOME/xen-run; n=$1; IMG=$2; shift 2
L=$R/xen-domu-run$n.log T=$R/times-run$n.log CAP=${CAP:-7200}
t0=$(date +%s)
echo "run$n start $(date -Is) args: $*" > "$T"
setsid env RCS_DEVFIX=1 WITH_DISK=1 DISK_MB=512 K3S_DISK=1 "$@" \
	WAIT_LOG="$L" POSTCREATE=3600 DRIVER=xen-run2-restart.sh bash "$R/run.sh" "$n" "$IMG" &
pid=$!
seen=""
while :; do
	sleep 10
	for m in ^PAYLOAD_START ^K3S_OK ^K3S_FAIL ^PAYLOAD_DONE 'reboot: Power down' ^---BOOT2--- ; do
		c=$(grep -ac -- "$m" "$L" 2>/dev/null); c=${c:-0}
		k="$m#$c"
		case " $seen " in *" ${k// /_} "*) ;; *)
			[ "$c" -gt 0 ] && { echo "$(( $(date +%s) - t0 ))s host: '$m' count=$c" >> "$T"; seen="$seen ${k// /_}"; } ;;
		esac
	done
	grep -aq "^---HOTPLUG-END---" "$L" 2>/dev/null && break
	grep -aq -E "Kernel panic|Unhandled exception|Assertion .* failed|Oops" "$L" 2>/dev/null && { echo "stopped on error" >> "$T"; break; }
	kill -0 $pid 2>/dev/null || break
	[ $(( $(date +%s) - t0 )) -ge "$CAP" ] && { echo "stopped at cap" >> "$T"; break; }
done
sleep 5
podman stop -t 5 xen-run$n >/dev/null 2>&1
kill -- -$pid 2>/dev/null; wait $pid 2>/dev/null
echo "run$n end $(date -Is) wall=$(( $(date +%s) - t0 ))s" >> "$T"
grep -a -E "SUMMARY|K3S_FAIL|RESTART:|PODS:|cpus:|smp: Brought|Assertion" "$L" | tr -d '\r' >> "$T"
echo RUN_DONE >> "$T"
