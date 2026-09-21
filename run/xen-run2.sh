#!/bin/bash
# Drives dom0's console for the Xen domU run.
#
# Replaces the blind-send /tmp/claude-1000/xen-run.sh, which wrote all nine
# commands into the console at once. On 2026-09-20 that run froze mid-echo of
# the bridge command and produced nothing for 20 minutes, with no way to tell
# which command had died or whether the console had dropped characters.
#
# Two changes:
#   1. One command at a time, with a gap, so the guest's serial input buffer
#      is never asked to hold more than one line.
#   2. A unique marker echoed after every command, carrying that command's
#      exit status. A missing marker names the command that failed; a marker
#      with a non-zero status names one that ran and failed. Silence is no
#      longer ambiguous.
#
# Markers are STEP<n>:<name>:rc=<status>. Grep the log for '^STEP' to get the
# whole sequence at a glance.

set -u
GAP="${GAP:-5}"          # seconds between commands
SETTLE="${SETTLE:-150}"  # wait for dom0 to reach a shell
HOLD="${HOLD:-3600}"     # keep stdin open while the domU runs

send() {                 # send <n> <name> <command...>
    local n=$1 name=$2; shift 2
    printf '%s\n' "$*"
    printf 'echo STEP%s:%s:rc=$?\n' "$n" "$name"
    sleep "$GAP"
}

sleep "$SETTLE"

send 0 shell    'echo DOM0_SHELL_MARKER'
send 1 path     'PATH=$PATH:/dist/install/usr/local/sbin:/dist/install/usr/local/bin'
send 2 addbr    'brctl addbr xenbr0'
send 3 brup     'ip link set xenbr0 up'
send 4 braddr   'ip addr add 192.168.128.1/24 dev xenbr0'
send 5 brshow   'ip -o addr show xenbr0'
send 6 tmpfs    'mount -t tmpfs -o size=96m tmpfs /mnt'
send 7 diskimg  'dd if=/dev/zero of=/mnt/disk.img bs=1M count=64 2>/dev/null'
send 8 disksize 'ls -l /mnt/disk.img'
send 9 xlver    'xl info 2>&1 | head -3'

# tools/xl/xl_parse.c:1379 defaults an unspecified domain type to PVH only
# under "#if defined(__arm__) || defined(__aarch64__)". riscv64 matches
# neither, falls through to PV, and libxl_riscv.c:602 then asserts
# c_info->type != LIBXL_DOMAIN_TYPE_PV, so xl create aborts. Upstream's own
# domu.cfg has no type= either. Set it explicitly until that #if is fixed.
send 10 settype "grep -q '^type' /domu/domu.cfg || echo 'type = \"pvh\"' >> /domu/domu.cfg"
send 11 showcfg 'cat /domu/domu.cfg'

# WITH_DISK=0 drops the disk stanza. /etc/xen/scripts/block timed out on the
# previous run (xen-domu-run3-BLOCKTIMEOUT.log): a hang, not an error, with
# bash, losetup and the script all present in the image. Dropping the disk
# isolates netfront, which is the part nothing has ever exercised. /init
# reports "disk=skipped: no block device" rather than failing (init:808).
if [ "${WITH_DISK:-1}" = "0" ]; then
    send 12 nodisk "sed -i '/^disk *=/d' /domu/domu.cfg"
fi
# SKIP_LPJ_CAL=1 prepends lpj= to the guest cmdline, which makes Linux skip
# calibrate_delay(). Run 6 booted the domU and then spun at ~100% CPU for 86
# minutes with no output after "sched_clock: 64 bits at 10MHz". The hypothesis
# is that it is stuck in calibrate_delay waiting for timer interrupts that
# never arrive, because xen/arch/riscv/vtimer.c:23 domain_vtimer_init() is a
# stub that prints "to be implemented" and returns 0.
#
# This is the discriminating test, and it can falsify the hypothesis:
#   past sched_clock  -> it WAS calibrate_delay, so the timer is the cause
#   stuck in the same place -> hypothesis WRONG, something else is spinning
if [ "${SKIP_LPJ_CAL:-0}" = "1" ]; then
    send 12b lpj "sed -i 's/^extra = \"/extra = \"lpj=10000000 /' /domu/domu.cfg"
fi
# keep_bootcon keeps the SBI bootconsole registered after hvc0 takes over, and
# sbi_console_putchar is one ecall, so one VM exit, PER CHARACTER. Run 14 showed
# the guest spending all its time in console_flush_all with every traced exit
# being a7=0x1 putchar. earlycon itself is kept: it is what makes pre-console
# failures visible at all. Only its survival past hvc0 is dropped.
if [ "${NO_BOOTCON:-0}" = "1" ]; then
    send 12c nobootcon "sed -i 's/ keep_bootcon//' /domu/domu.cfg"
fi

# Run 16 measured the domU advancing ~0.77 s of guest time in ~3 min of wall
# clock while dom0 booted at roughly 3x real time, and 61 of the guest's first
# 70 hypercalls were EVTCHNOP_send from the console notify path. If console
# throughput is the limit, silencing the guest should make it race ahead.
if [ "${GUEST_QUIET:-0}" = "1" ]; then
    send 12d quiet "sed -i 's/test=all/loglevel=1 test=all/' /domu/domu.cfg"
fi

send 13 showcfg2 'cat /domu/domu.cfg'
# The block hotplug script's claim_lock (locking.sh) loops forever unless
# `stat -L /dev/stdin` works, and devtmpfs does not create the /dev/fd family
# (udev or mdev normally do). Found in run 23 by tracing the script.
send 13v devfd 'ln -sfn /proc/self/fd /dev/fd; ln -sf /proc/self/fd/0 /dev/stdin; ln -sf /proc/self/fd/1 /dev/stdout; ln -sf /proc/self/fd/2 /dev/stderr; ls -l /dev/stdin'
# vif-bridge is the same hotplug machinery that hung on block, so a tool that
# is missing or a lock that blocks will show up here too.
send 14 tools 'command -v bash losetup flock xenstore-read xenstore-write xenstore-list'

# xenconsoled calls openpty(), which needs /dev/ptmx and a mounted devpts.
# The initrd has neither the mount point nor the mount, so run 5 got
# "xenconsoled: Failed to create tty for domain-1 (errno = 2)" and libxl then
# timed out waiting for a console node that was never going to appear.
# CONFIG_UNIX98_PTYS=y in the dom0 kernel, so this is purely a missing mount.
send 14a devpts 'mkdir -p /dev/pts && mount -t devpts devpts /dev/pts'
send 14b ptscheck 'ls -ld /dev/pts && ls -l /dev/ptmx'

# libxl waits for /local/domain/N/console/tty to appear and times out without it
# (libxl_create.c:1982 console_xswait_callback). That node is written by
# xenconsoled, which ships in the image but is not started by dom0's init.
# Run 4 died here with the vif already attached and on the bridge.
send 15 consoled 'xenconsoled --pid-file /var/run/xenconsoled.pid'
send 16 psxen 'ps | grep -c xenconsole'

printf 'echo ---CREATE---\n'

if [ "${TRACE:-0}" = "1" ]; then
    # Create WITHOUT -c so dom0's shell stays usable. The discriminator is
    # whether Xen attributes climbing CPU time to the domain: a rising Time(s)
    # in "xl list" means d1v0 is executing (spin or interrupt storm), a flat
    # one means it is blocked. QEMU's own 120% tells us nothing, since that
    # could be Xen or dom0 polling.
    send 17 create   'xl create /domu/domu.cfg'
    send 18 list1    'xl list'
    send 19 vcpu1    'xl vcpu-list'
    send 20 wait     'sleep 30; echo waited'
    send 21 list2    'xl list'
    send 22 vcpu2    'xl vcpu-list'
    send 23 dumpdom  'xl debug-keys q'
    send 24 dumpreg  'xl debug-keys d'
    send 25 dumpirq  'xl debug-keys i'
    send 26 list3    'xl list'
else
    printf 'xl create -c /domu/domu.cfg\n'
fi

# xl create -c attaches dom0's stdin to the domU console, so nothing below
# reaches dom0's shell until the domain exits or the create fails. Long wait
# first; if the guest is still up, this text lands harmlessly in a console
# whose only reader is /init, which ignores it.
sleep "${POSTCREATE:-1200}"
printf 'echo ---HOTPLUG-LOG---\n'
printf 'tail -80 /var/log/xen/xen-hotplug.log 2>&1\n'
printf 'echo ---HOTPLUG-END---\n'

sleep "$HOLD"
