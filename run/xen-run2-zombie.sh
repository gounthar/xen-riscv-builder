#!/bin/bash
# COPY of xen-run2-restart.sh's setup steps for the 2026-09-24 zombie-domU and
# 2-vCPU narrowing runs (119+), not committed. Same one-command-at-a-time
# console driving and STEP<n>:<name>:rc=<status> markers, plus sendw(), which
# waits on the host until that marker is back in WAIT_LOG (required) before
# typing the next line, so no step is typed into a busy console.
#
# MODE=zombie  guests run test=identity (no test, powers off in about a
#              minute). domu (disk + vif) powers itself off; watch it for 2
#              min; z2 is held up (net.hold) and stopped with xl shutdown;
#              z3 powers itself off; z4 (memory 512) is created with every
#              pCPU taken; then xl destroy domu and look again.
# MODE=smp     one guest, VCPUS (default 2), test=identity debug=1, console
#              attached. Once the guest drops to its shell, dump what it sees
#              of its CPUs and IMSICs, then detach.
# MODE=smpd    (test 1, runs 130+) the same guest created paused (xl create
#              -p), xl vcpu-list before unpause, then xl vcpu-list sampled
#              from dom0 every 2 s through the guest's CPU bring-up. Use with
#              KEEPBC=1 so the guest's kernel lines reach the serial log.
set -u
GAP="${GAP:-5}"
SETTLE="${SETTLE:-150}"
HOLD="${HOLD:-3600}"
MODE="${MODE:-zombie}"
: "${WAIT_LOG:?WAIT_LOG is required}"

send() { # send <n> <name> <command...>
  local n=$1 name=$2
  shift 2
  printf '%s\n' "$*"
  printf 'echo STEP%s:%s:rc=$?\n' "$n" "$name"
  sleep "$GAP"
}
waitfor() { # waitfor <ERE> <count> <timeout-s>
  local t=0
  until [ "$(grep -acE -- "$1" "$WAIT_LOG" 2>/dev/null)" -ge "$2" ] || [ "$t" -ge "$3" ]; do
    sleep 5
    t=$((t + 5))
  done
}
sendw() { # like send, then wait for the marker (cap 300 s)
  local n=$1 name=$2
  send "$@"
  if [ "${NUDGE:-0}" = 1 ]; then
    # Run 121: after a detached create, typed lines sat unechoed until the
    # next line was typed. Wait 60 s at a time, then send a bare newline.
    local k=0
    while [ "$k" -lt $((${SENDW_CAP:-300} / 60)) ]; do
      waitfor "^STEP$n:$name:rc=" 1 60
      grep -aqE "^STEP$n:$name:rc=" "$WAIT_LOG" && return 0
      k=$((k + 1))
      echo "HOSTNOTE: $(date +%T) no STEP$n marker after ${k}x60s, sent a newline" >&2
      printf '\n'
    done
  else
    waitfor "^STEP$n:$name:rc=" 1 "${SENDW_CAP:-300}"
  fi
}
srst() { grep -ac 'extension id 0x53525354' "$WAIT_LOG" 2>/dev/null; }

sleep "$SETTLE"
waitfor '^~ #|^/ #|# $' 1 900

sendw 0 shell 'echo DOM0_SHELL_MARKER'
sendw 1 path 'PATH=$PATH:/dist/install/usr/local/sbin:/dist/install/usr/local/bin'
sendw 2 addbr 'brctl addbr xenbr0'
sendw 3 brup 'ip link set xenbr0 up'
sendw 4 braddr 'ip addr add 192.168.128.1/24 dev xenbr0'
sendw 6 tmpfs 'mount -t tmpfs -o size=96m tmpfs /mnt'
sendw 7 diskimg 'dd if=/dev/zero of=/mnt/disk.img bs=1M count=64 2>/dev/null'
sendw 9 xlinfo 'xl info | grep -E "nr_cpus|total_mem|free_mem|xen_cha"'
sendw 10 settype "grep -q '^type' /domu/domu.cfg || echo 'type = \"pvh\"' >> /domu/domu.cfg"
# KEEPBC=1 keeps keep_bootcon, so detached guests print on the serial too
# (run 119 went silent after z2's console moved to hvc0).
[ "${KEEPBC:-0}" = 1 ] || sendw 12c nobootc "sed -i 's/ keep_bootcon//' /domu/domu.cfg"
sendw 12i ident "sed -i 's/test=all/test=identity/' /domu/domu.cfg"
sendw 12j identc 'grep -c test=identity /domu/domu.cfg'
if [ "$MODE" = smp ] || [ "$MODE" = smpd ]; then
  sendw 12v1 vcpus "sed -i 's/^vcpus = .*/vcpus = ${VCPUS:-2}/' /domu/domu.cfg"
  sendw 12v2 vcpusc "grep -c '^vcpus = ${VCPUS:-2}\$' /domu/domu.cfg"
  sendw 12d dbg "sed -i 's/test=identity/test=identity debug=1/' /domu/domu.cfg"
  sendw 12e dbgc 'grep -c debug=1 /domu/domu.cfg'
  # AFFINITY=1 pins vCPU 0 to pCPU 2 and vCPU 1 to pCPU 3, so the two
  # cannot share a pCPU when vCPU 0 asks for vCPU 1 (vsbi.c HART_START).
  if [ "${AFFINITY:-0}" = 1 ]; then
    sendw 12f aff "echo 'cpus = [\"2\", \"3\"]' >> /domu/domu.cfg"
    sendw 12g affc "grep -c '^cpus' /domu/domu.cfg"
  fi
fi
sendw 13 showcfg 'cat /domu/domu.cfg'
sendw 13v devfdc 'ls -l /dev/stdin /dev/fd'
sendw 14b ptschk 'ls -ld /dev/pts && ls -l /dev/ptmx'
sendw 15 consd 'mkdir -p /var/log/xen/console'
sendw 15b consd2 'xenconsoled --log=guest --log-dir=/var/log/xen/console'
sendw 16 psxen 'ps | grep -c xenconsole'

if [ "$MODE" = smpd ]; then
  sendw 30 cpause 'xl create -p /domu/domu.cfg'
  sendw 31 lp 'xl list'
  sendw 32 vp 'xl vcpu-list'
  sendw 33 unp 'xl unpause domu; echo UNPAUSED'
  # Test 2 (run 133+): VLN/VLS/VLCAP stretch the sampling; VLXL=1 adds xl list.
  if [ "${VLXL:-0}" = 1 ]; then
    SENDW_CAP=${VLCAP:-900} sendw 34 vloop "for i in \$(seq ${VLN:-90}); do echo VL\$i; xl list domu; xl vcpu-list domu; sleep ${VLS:-2}; done"
  else
    SENDW_CAP=${VLCAP:-900} sendw 34 vloop "for i in \$(seq ${VLN:-90}); do echo VL\$i; xl vcpu-list domu; sleep ${VLS:-2}; done"
  fi
  sendw 35 gsmp 'grep -a -E "smp:|CPU1|SBI.*detected" /var/log/xen/console/guest-domu.log'
  sendw 40 xllist 'xl list'
  sendw 41 vcpul 'xl vcpu-list'
  printf 'E=END; echo ---SMP-$E---\n'
  sleep "$HOLD"
  exit 0
fi

if [ "$MODE" = smp ]; then
  printf 'echo ---CREATE---\n'
  sleep "$GAP"
  printf 'xl create -c /domu/domu.cfg\n'
  # dom0 printed one "smp: Brought up" at boot; the guest's is the second.
  waitfor 'smp: Brought up' 2 900
  waitfor 'dropping to a shell|debug=1: not powering off' 1 900
  sleep 20
  for c in 'echo ---GUEST-SHELL---' \
    'cat /sys/devices/system/cpu/possible' \
    'cat /sys/devices/system/cpu/online' \
    'dmesg | grep -i -E "imsic|smp|CPU1|hart|sbi"' \
    'ls /proc/device-tree/cpus' \
    'cat /proc/device-tree/cpus/cpu@*/reg | od -An -tx1' \
    'P=/proc/device-tree/cpus/cpu@*/interrupt-controller' \
    'cat $P/phandle | od -An -tx1' \
    'find /proc/device-tree -iname "*imsic*"' \
    'I=$(find /proc/device-tree -iname "imsic*" | head -1)' \
    'echo $I; ls $I' \
    'od -An -tx1 $I/reg' \
    'od -An -tx1 $I/interrupts-extended' \
    'od -An -tx1 $I/riscv,guest-index-bits' \
    'od -An -tx1 $I/riscv,hart-index-bits' \
    'head -12 /proc/interrupts' \
    'echo ---GUEST-SHELL-END---'; do
    printf '%s\n' "$c"
    sleep 8
  done
  printf '\035'
  sleep 3
  printf '\n'
  sleep 3
  sendw 40 xllist 'xl list'
  sendw 41 vcpul 'xl vcpu-list'
  printf 'E=END; echo ---SMP-$E---\n'
  sleep "$HOLD"
  exit 0
fi

# --------------------------------------------------------------- zombie2 --
# Runs 119 and 120 stopped responding right after a second guest was created
# next to a powered-off one. zombie2 reorders: the held guest first (zh, with
# the disk and vif), then xl shutdown, then xl destroy, and only then more
# guests, so (b) and (d) are measured before the step that hung.
if [ "$MODE" = zombie2 ]; then
    sendw 20a zh    "sed 's/^name = .*/name = \"zh\"/' /domu/domu.cfg > /mnt/zh.cfg"
    sendw 20b zhh   "sed -i 's/test=identity/test=identity net.hold=900/' /mnt/zh.cfg"
    sendw 20c zc    "sed -e '/^disk/d' -e '/^vif/d' /domu/domu.cfg > /mnt/z.cfg"
    sendw 20d z3    "sed 's/^name = .*/name = \"z3\"/' /mnt/z.cfg > /mnt/z3.cfg"
    sendw 20e z4    "sed 's/^name = .*/name = \"z4\"/' /mnt/z.cfg > /mnt/z4.cfg"
    sendw 20f z4m   "sed -i 's/^memory = .*/memory = 512/' /mnt/z4.cfg"
    sendw 20g zchk  'grep -h -E "^name|^memory|^vcpus|^disk|^vif" /mnt/z*.cfg'
    sendw 20h zhchk 'grep -c net.hold=900 /mnt/zh.cfg'
    sendw 20i cvar  'C=/var/log/xen/console'
    sendw 20j wfun  'W() { grep -q "$1" $C/guest-$2.log; }'
    sendw 21 czh    'xl create /mnt/zh.cfg'
    SENDW_CAP=900 sendw 22 wzh 'for i in $(seq 150); do W holding zh && break; sleep 5; done'
    sendw 23 l0     'xl list'
    sendw 24 v0     'xl vcpu-list'
    sendw 25 mem0   'xl info | grep free_mem'
    # (d) xl shutdown of a live guest
    s1=$(srst)
    sendw 30 shut   'xl shutdown zh'
    waitfor 'extension id 0x53525354' $((s1 + 1)) 240
    sleep 15
    sendw 31 l1     'xl list'
    sendw 32 v1     'xl vcpu-list'
    sendw 33 zhlog  'tail -6 $C/guest-zh.log'
    sleep 60
    sendw 34 l2     'xl list'
    sendw 35 loop2  'losetup -a'
    sendw 36 vbd2   'xenstore-ls -f /local/domain/0/backend/vbd | head -14'
    sendw 37 br2    'brctl show xenbr0'
    # (b) xl destroy, in the background in case it blocks
    sendw 40 dest   'xl destroy zh > /mnt/destroy.out 2>&1 &'
    sleep 30
    sendw 41 dout   'cat /mnt/destroy.out; jobs'
    sendw 42 l3     'xl list'
    sendw 43 v3     'xl vcpu-list'
    sendw 44 loop3  'losetup -a'
    sendw 45 vbd3   'xenstore-ls -f /local/domain/0/backend/vbd | head -14'
    sendw 46 br3    'brctl show xenbr0'
    sendw 47 mem3   'xl info | grep free_mem'
    sleep 60
    sendw 48 l4     'xl list'
    sendw 49 v4     'xl vcpu-list'
    sendw 49b dout2 'cat /mnt/destroy.out'
    # (c) more guests, each powering itself off
    s2=$(srst)
    sendw 50 cz3    'xl create /mnt/z3.cfg'
    sendw 51 alive1 'echo dom0 alive after z3 create'
    waitfor 'extension id 0x53525354' $((s2 + 1)) 900
    sleep 15
    sendw 52 l5     'xl list'
    sendw 53 v5     'xl vcpu-list'
    sendw 54 mem5   'xl info | grep free_mem'
    sendw 55 cz4    'xl create /mnt/z4.cfg'
    sendw 56 alive2 'echo dom0 alive after z4 create'
    sleep 120
    sendw 57 l6     'xl list'
    sendw 58 v6     'xl vcpu-list'
    sendw 59 hot    'tail -20 /var/log/xen/xen-hotplug.log'
    printf 'E=END; echo ---ZOMBIE-$E---\n'
    sleep "$HOLD"
    exit 0
fi

# --------------------------------------------------------------- zombie3 --
# (c) with nothing else present first: z3 alone (the control for the input
# stall of runs 119-121), then 512 MiB guests until a fifth vCPU has no pCPU.
if [ "$MODE" = zombie3 ]; then
  sendw 20c zc "sed -e '/^disk/d' -e '/^vif/d' /domu/domu.cfg > /mnt/z.cfg"
  sendw 20d z3 "sed 's/^name = .*/name = \"z3\"/' /mnt/z.cfg > /mnt/z3.cfg"
  sendw 20e zs "sed 's/^memory = .*/memory = 512/' /mnt/z.cfg > /mnt/zs.cfg"
  for x in a b c; do
    sendw 20f$x z$x "sed 's/^name = .*/name = \"z$x\"/' /mnt/zs.cfg > /mnt/z$x.cfg"
  done
  sendw 20g zchk 'grep -h -E "^name|^memory|^vcpus|^disk|^vif" /mnt/z?.cfg'
  n=60
  for g in z3 za zb zc; do
    s1=$(srst)
    sendw $n c$g "xl create /mnt/$g.cfg"
    sendw $((n + 1)) alive$g "echo dom0 alive after $g create"
    waitfor 'extension id 0x53525354' $((s1 + 1)) 600
    sleep 15
    sendw $((n + 2)) l$g 'xl list'
    sendw $((n + 3)) v$g 'xl vcpu-list'
    sendw $((n + 4)) m$g 'xl info | grep free_mem'
    n=$((n + 10))
  done
  sleep 60
  sendw 99 lend 'xl list'
  sendw 99b vend 'xl vcpu-list'
  printf 'E=END; echo ---ZOMBIE-$E---\n'
  sleep "$HOLD"
  exit 0
fi

# ---------------------------------------------------------------- zombie --
# Zombie configs: no disk, no vif, so only domu holds a loop device. z2 is
# held up by net.hold so xl shutdown has a live guest to act on. z4 is small
# enough to fit in memory next to three 1344 MiB guests.
sendw 20a zc "sed -e '/^disk/d' -e '/^vif/d' /domu/domu.cfg > /mnt/z.cfg"
sendw 20b z2 "sed 's/^name = .*/name = \"z2\"/' /mnt/z.cfg > /mnt/z2.cfg"
sendw 20c z2h "sed -i 's/test=identity/test=identity net.hold=900/' /mnt/z2.cfg"
sendw 20d z3 "sed 's/^name = .*/name = \"z3\"/' /mnt/z.cfg > /mnt/z3.cfg"
sendw 20e z4 "sed 's/^name = .*/name = \"z4\"/' /mnt/z.cfg > /mnt/z4.cfg"
sendw 20f z4m "sed -i 's/^memory = .*/memory = 512/' /mnt/z4.cfg"
sendw 20g zchk 'grep -h -E "^name|^memory|^vcpus|^disk|^vif" /mnt/z?.cfg'
sendw 20h z2chk 'grep -c net.hold=900 /mnt/z2.cfg'

# (a) domu powers itself off.
sendw 21 cdomu 'xl create /domu/domu.cfg'
s0=$(srst)
waitfor 'extension id 0x53525354' $((s0 + 1)) 900
sleep 15
sendw 22 pdown 'grep -c "Power down" /var/log/xen/console/guest-domu.log'
sendw 23 l0 'xl list'
sendw 24 v0 'xl vcpu-list'
sendw 25 loop0 'losetup -a'
sendw 26 vbd0 'xenstore-ls -f /local/domain/0/backend/vbd | head -14'
sendw 27 br0 'brctl show xenbr0'
sendw 28 mem0 'xl info | grep free_mem'
sleep 60
sendw 29 l1 'xl list'
sendw 30 v1 'xl vcpu-list'
sleep 60
sendw 31 l2 'xl list'
sendw 32 v2 'xl vcpu-list'

# (d) z2 held up, then xl shutdown.
sendw 33 cz2 'xl create /mnt/z2.cfg'
waitfor 'holding 900s' 1 900
sleep 10
sendw 34 l3 'xl list'
s1=$(srst)
sendw 35 shut 'xl shutdown z2'
waitfor 'extension id 0x53525354' $((s1 + 1)) 180
sleep 15
sendw 36 l4 'xl list'
sendw 37 z2log 'tail -8 /var/log/xen/console/guest-z2.log'
sleep 45
sendw 38 l5 'xl list'
sendw 39 v5 'xl vcpu-list'

# (c) z3 powers itself off; then z4 with every pCPU held.
sendw 40 mem1 'xl info | grep free_mem'
s2=$(srst)
sendw 41 cz3 'xl create /mnt/z3.cfg'
waitfor 'extension id 0x53525354' $((s2 + 1)) 900
sleep 15
sendw 42 l6 'xl list'
sendw 43 v6 'xl vcpu-list'
sendw 44 mem2 'xl info | grep free_mem'
sendw 45 cz4 'xl create /mnt/z4.cfg'
sleep 90
sendw 46 l7 'xl list'
sendw 47 v7 'xl vcpu-list'
sleep 60
sendw 48 l8 'xl list'
sendw 49 z4log 'wc -c /var/log/xen/console/guest-z4.log'

# (b) xl destroy domu, in the background in case it blocks.
sendw 50 dest 'xl destroy domu > /mnt/destroy.out 2>&1 &'
sleep 30
sendw 51 destout 'cat /mnt/destroy.out; jobs'
sendw 52 l9 'xl list'
sendw 53 v9 'xl vcpu-list'
sendw 54 loop9 'losetup -a'
sendw 55 vbd9 'xenstore-ls -f /local/domain/0/backend/vbd | head -14'
sendw 56 br9 'brctl show xenbr0'
sendw 57 mem9 'xl info | grep free_mem'
sleep 90
sendw 58 l10 'xl list'
sendw 59 v10 'xl vcpu-list'
sendw 60 z4log2 'wc -c /var/log/xen/console/guest-z4.log'
sendw 61 destout2 'cat /mnt/destroy.out'
sendw 62 hotplug 'tail -30 /var/log/xen/xen-hotplug.log'
printf 'E=END; echo ---ZOMBIE-$E---\n'
sleep "$HOLD"
