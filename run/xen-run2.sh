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
# DISK_MB sizes the disk image. The default 64 MiB is written out as zeros,
# as in every run so far. Anything larger is created sparse (seek, no data),
# so dom0's tmpfs only spends RAM on the blocks the guest actually writes;
# that is the number k3s.disk=1 is about. TMPFS_MB defaults to 32 MiB of
# headroom over the image; the dom0 script al.sh (MULTINODE) lives there too.
DISK_MB="${DISK_MB:-64}"
TMPFS_MB="${TMPFS_MB:-$((DISK_MB + 32))}"
send 6 tmpfs    "mount -t tmpfs -o size=${TMPFS_MB}m tmpfs /mnt"
if [ "$DISK_MB" = 64 ]; then
send 7 diskimg  'dd if=/dev/zero of=/mnt/disk.img bs=1M count=64 2>/dev/null'
else
send 7 diskimg  "dd if=/dev/zero of=/mnt/disk.img bs=1M count=0 seek=${DISK_MB} 2>/dev/null"
fi
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

# K3S_DISK=1 asks the payload to put K3s's agent/ and server/ on xvda
# (xen-riscv-domu-containers, init: k3s.disk). Needs WITH_DISK=1 and a
# DISK_MB above 64: run 52 used 159M of DISK_MB=512 at K3S_OK. The payload
# reports K3S_FAIL rather than fall back to tmpfs if the device is missing.
# Leave DOM0_MEM at 1024M: run 51 with 3072M split dom0 into three banks and
# Xen faulted loading the dom0 initrd across the first bank's end.
if [ "${K3S_DISK:-0}" = "1" ]; then
    send 12e k3sdisk "sed -i 's/test=all/test=all k3s.disk=1/' /domu/domu.cfg"
    # MULTINODE: the server is domu-mn.cfg, which has no disk stanza and runs
    # test=k3s. Give the server the disk; the agent stays on tmpfs.
    if [ "${MULTINODE:-0}" = "1" ]; then
        send 12f mndisk "sed -i 's/test=k3s/test=k3s k3s.disk=1/' /domu/domu-mn.cfg"
        send 12g mndisk2 "grep -q '^disk' /domu/domu-mn.cfg || echo \"disk = [ 'format=raw,vdev=xvda,access=rw,backendtype=phy,target=/mnt/disk.img' ]\" >> /domu/domu-mn.cfg"
        send 12h mnshow "cat /domu/domu-mn.cfg"
    fi
fi

send 13 showcfg2 'cat /domu/domu.cfg'
# The block hotplug script's claim_lock (locking.sh) loops forever unless
# `stat -L /dev/stdin` works, and devtmpfs does not create the /dev/fd family
# (udev or mdev normally do). Found in run 23 by tracing the script.
# RCS_DEVFIX=1: the dom0 image's rcS makes these links and mounts devpts
# itself (builder Makefile, initrd-tools), so skip 13v and 14a and only
# look. That is the run that proves the rcS fix, not the driver.
if [ "${RCS_DEVFIX:-0}" = 1 ]; then
send 13v devfdcheck 'ls -l /dev/stdin /dev/fd'
else
send 13v devfd 'ln -sfn /proc/self/fd /dev/fd; ln -sf /proc/self/fd/0 /dev/stdin; ln -sf /proc/self/fd/1 /dev/stdout; ln -sf /proc/self/fd/2 /dev/stderr; ls -l /dev/stdin'
fi
# vif-bridge is the same hotplug machinery that hung on block, so a tool that
# is missing or a lock that blocks will show up here too.
send 14 tools 'command -v bash losetup flock xenstore-read xenstore-write xenstore-list'

# xenconsoled calls openpty(), which needs /dev/ptmx and a mounted devpts.
# The initrd has neither the mount point nor the mount, so run 5 got
# "xenconsoled: Failed to create tty for domain-1 (errno = 2)" and libxl then
# timed out waiting for a console node that was never going to appear.
# CONFIG_UNIX98_PTYS=y in the dom0 kernel, so this is purely a missing mount.
[ "${RCS_DEVFIX:-0}" = 1 ] || send 14a devpts 'mkdir -p /dev/pts && mount -t devpts devpts /dev/pts'
send 14b ptscheck 'ls -ld /dev/pts && ls -l /dev/ptmx'

# libxl waits for /local/domain/N/console/tty to appear and times out without it
# (libxl_create.c:1982 console_xswait_callback). That node is written by
# xenconsoled, which ships in the image but is not started by dom0's init.
# Run 4 died here with the vif already attached and on the bridge.
# MULTINODE=1 attaches to one domU only, so xenconsoled also logs every
# guest's console to a file; the agent's is printed once the server is gone.
if [ "${MULTINODE:-0}" = "1" ]; then
send 15 consoled 'mkdir -p /var/log/xen/console && xenconsoled --pid-file /var/run/xenconsoled.pid --log=guest --log-dir=/var/log/xen/console'
else
send 15 consoled 'xenconsoled --pid-file /var/run/xenconsoled.pid'
fi
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
elif [ "${NETCHECK:-0}" = "1" ]; then
    # Create WITHOUT -c so dom0's shell stays usable, then ping the guest
    # from dom0 across xenbr0 while its payload runs. A reply needs both
    # directions through netfront, netback and the bridge. The guest's own
    # console output is not captured in this mode.
    send 17 create   'xl create /domu/domu.cfg'
    send 18 list1    'xl list'
    send 19 wait1    'sleep 90; echo waited'
    send 20 vifs     'brctl show xenbr0; ip -o link show | grep vif'
    send 21 ping1    'ping -c 5 -W 5 192.168.128.2'
    send 22 wait2    'sleep 60; echo waited'
    send 23 ping2    'ping -c 5 -W 5 192.168.128.2'
    send 24 vifstat  'ip -s link show vif1.0'
    send 25 list2    'xl list'
elif [ "${PINGPAIR:-0}" = "1" ]; then
    # The A/B for the page_get_owner_and_reference() stub: two domUs, no K3s,
    # one pinging the other with frames big enough that the receiving vif
    # copies from the sender's grant. domu holds itself up (net.hold), domu2
    # pings it and its console is attached, so the result is in this log.
    send 17 createa  'xl create /domu/domu-ping-a.cfg'
    sleep "${AGENT_SETTLE:-60}"
    send 18 list1    'xl list'
    printf 'xl create -c /domu/domu-ping-b.cfg\n'
elif [ "${MULTINODE:-0}" = "1" ]; then
    # Two-node K3s: the agent (domu2) first and detached, then the server
    # (domu, domu-mn.cfg) with its console attached. A dom0 background job
    # waits for PAYLOAD_DONE in the server's console log, gives the agent up
    # to 600 s to reach its own, then prints the agent's console log. It keys
    # on the logs, not on the domains: run 43 showed a powered-off domU stays
    # in "xl list" (domain_relinquish_resources() is -ENOSYS on riscv), so a
    # wait for the domain to go never ends.
    #
    # Run 40 typed that job as one 300-character line while domu2's earlycon
    # output was flooding the same serial console; characters were lost, the
    # shell sat at a ">" continuation prompt, and it swallowed the server's
    # xl create. So: wait out the agent's boot burst here on the host, and
    # write the job as short lines, each checked by its own marker, into
    # /mnt (run 41: the dom0 image has no /tmp). The end
    # marker is assembled from $E so the tty echo of what we type cannot
    # match it.
    send 17 create2  'xl create /domu/domu2.cfg'
    sleep "${AGENT_SETTLE:-60}"
    send 18 list1    'xl list'
    send 19a al1     "echo 'C=/var/log/xen/console; T=PAYLOAD_DONE' > /mnt/al.sh"
    send 19b al2     "echo 'until grep -q \$T \$C/guest-domu.log; do sleep 10; done' >> /mnt/al.sh"
    send 19c al3     "echo 'n=0; until grep -q \$T \$C/guest-domu2.log; do' >> /mnt/al.sh"
    send 19d al4     "echo '[ \$n -ge 60 ] && break; sleep 10; n=\$((n+1)); done' >> /mnt/al.sh"
    send 19e al5     "echo 'echo ---AGENT-LOG---; cat \$C/guest-domu2.log' >> /mnt/al.sh"
    send 19f al6     "echo 'xl list; E=END; echo ---AGENT-LOG-\$E---' >> /mnt/al.sh"
    send 19g alshow  'cat /mnt/al.sh; wc -l < /mnt/al.sh'
    send 19h albg    'sh /mnt/al.sh &'
    printf 'xl create -c /domu/domu-mn.cfg\n'
else
    printf 'xl create -c /domu/domu.cfg\n'
fi

# xl create -c attaches dom0's stdin to the domU console, so nothing below
# reaches dom0's shell until the domain exits or the create fails. Long wait
# first; if the guest is still up, this text lands harmlessly in a console
# whose only reader is /init, which ignores it.
# Nothing typed after this point reached dom0 in any earlier run: once the
# attached guest powers off, xl's console stays attached to it (runs 24, 30,
# 36 end at "Power down" with no hotplug output). WAIT_LOG is the run's own
# log on the host. With it, wait for the attached guest's power-down rather
# than a fixed time, then detach with ^] (xenconsole's escape) so what follows
# goes to dom0's shell. Detaching early would cost the guest's output, which
# is why this keys on the power-down line and not on a timer. POSTCREATE is
# the upper bound either way.
if [ -n "${WAIT_LOG:-}" ]; then
    t=0
    until grep -aq 'reboot: Power down' "$WAIT_LOG" 2>/dev/null || [ "$t" -ge "${POSTCREATE:-1200}" ]; do
        sleep 10; t=$((t + 10))
    done
    sleep 5
    printf '\035'; sleep 3; printf '\n'; sleep 3
else
    sleep "${POSTCREATE:-1200}"
fi
printf 'echo ---DOM0-TMPFS---; df -k /mnt; ls -ls /mnt/disk.img\n'
printf 'echo ---HOTPLUG-LOG---\n'
printf 'tail -80 /var/log/xen/xen-hotplug.log 2>&1\n'
printf 'echo ---HOTPLUG-END---\n'

sleep "$HOLD"
