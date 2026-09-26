#!/usr/bin/env bash
# Run N of the Xen domU payload test, same driver and knobs as run 19/20 on the laptop.
# Usage: bash ~/xen-run/run.sh <N> <initrd.img>
set -u
N=$1; IMG=$2; R=$HOME/xen-run
cd "$R"
{ echo "host: $(hostname) $(lscpu | sed -n "s/^Model name: *//p")"; date -Is; } > "$R/xen-domu-run$N.log"
{ time timeout 8000 bash -c "TRACE=0 WITH_DISK=${WITH_DISK:-0} DISK_MB=${DISK_MB:-64} K3S_DISK=${K3S_DISK:-0} NO_BOOTCON=1 SETTLE=150 GAP=5 \
  POSTCREATE=${POSTCREATE:-7200} HOLD=${HOLD:-30} bash $R/${DRIVER:-xen-run2.sh} | podman run --rm -i --name xen-run$N \
  --security-opt label=disable -e DOM0_MEM=${DOM0_MEM:-1024M} \
  -v $R/xen:/build/xen:ro \
  -v $R/dom0-Image.gz:/build/dom0-Image.gz:ro \
  -v $IMG:/build/initrd.img:ro \
  -v $R/Makefile:/build/Makefile:ro \
  -v $R/generate_dtb.sh:/build/dtb/generate_dtb.sh:ro \
  docker.io/local/trixie-riscv64:latest make go KERNEL=/build/dom0-Image.gz" ; } >> "$R/xen-domu-run$N.log" 2>&1
echo "exit=$?" >> "$R/xen-domu-run$N.log"
