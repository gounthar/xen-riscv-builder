nproc ?= $(shell nproc)

LINUX_ROOT?=$(BUILD_DIR)/linux
OPENSBI_ROOT?=$(BUILD_DIR)/opensbi
KERNEL?=$(LINUX_ROOT)/arch/riscv/boot/Image.gz
# dom0 and domU use different kernels. KERNEL is dom0's (loaded by QEMU at
# line 38); DOMU_KERNEL is the one copied into the initrd for xl to boot a
# guest with. They defaulted to the same file, which conflated the two.
DOMU_KERNEL?=$(KERNEL)
KERNEL_SYMBOL?=$(LINUX_ROOT)/vmlinux

QEMU?=$(BINARIES_DIR)/qemu-system-riscv64
OPENSBI?=$(BINARIES_DIR)/opensbi-riscv64-generic-fw_dynamic.bin
INITRD?=$(BUILD_DIR)/initrd.img
DTB_SCRIPT?=$(DTB_DIR)/generate_dtb.sh

XEN_ROOT?=$(BUILD_DIR)/xen
XEN_BIN?=$(XEN_ROOT)/xen/xen
XEN_SYMBOL?=$(XEN_ROOT)/xen/xen-syms

GDB?=/usr/bin/gdb-multiarch
LIBCHECK?=$(BUILD_DIR)/check-initrd-libs.sh

INITRD_STAMP := .stamp_initrd_with_tools
XEN_MAKE := $(MAKE) -C $(XEN_ROOT) -j$(nproc)

TOOLS_CONFIG = \
	$(XEN_CONFIG) && \
	cp $(CONFIGS_DIR)/config_tools.status $(XEN_ROOT)/tools/config.status && \
	cd $(XEN_ROOT)/tools && bash ./config.status

XEN_CONFIG = \
	cp $(CONFIGS_DIR)/config_xen.status $(XEN_ROOT)/config.status && \
	cd $(XEN_ROOT) && bash ./config.status

QEMU_BASE_FLAGS = \
	-M virt,aclint=off,aia=aplic-imsic,aia-guests=7 \
	-cpu rv64,smstateen=on \
	-bios $(OPENSBI) \
	-smp 4 \
	-nographic \
	-m 6g \
	-kernel $(XEN_BIN) \
	-device loader,file=$(KERNEL),addr=0x808ef000 \
	-device loader,file=$(INITRD),addr=0x90400000 \
	-dtb $(DTB_DIR)/dom0-qemu-virt.dtb

QEMU_DEBUG_FLAGS = -s -S

GDB_FLAGS?=
GDB_ARGS = \
	-ex "set confirm off" \
	-ex "set architecture riscv:rv64" \
	-ex "directory $(XEN_ROOT)" \
	-ex "directory $(LINUX_ROOT)" \
	-ex "target remote localhost:1234" \
	-ex "file $(KERNEL_SYMBOL)" \
	-ex "add-symbol-file $(XEN_SYMBOL)" \
	-ex "b start_xen" \
	-ex "c"

.PHONY: all clean help initrd-tools dist-tools dist-xen dist build-tools build-xen build go go-debug gdb initrd create-common-dirs create-tools-dirs

help:
	@echo "Available targets:"
	@echo "  build-tools      - Build Xen tools"
	@echo "  build-xen        - Build Xen hypervisor"
	@echo "  build            - Build both tools and Xen"
	@echo "  dist-tools       - Build and install tools to /dist"
	@echo "  dist-xen         - Build and install Xen to /dist"
	@echo "  dist             - Build and install tools and Xen to /dist"
	@echo "  initrd           - Create basic initrd image"
	@echo "  initrd-tools     - Create initrd with Xen tools included"
	@echo "  go               - Launch Xen with dom0 in QEMU"
	@echo "  go-debug         - Launch Xen with dom0 on QEMU with GDB server, waiting on port 1234"
	@echo "  clean            - Clean build artifacts (distclean)"
	@echo "  help             - Display this help message"

# Dist Targets build and install inside the `/dist` directory of the Xen source tree.
dist-tools:
	$(TOOLS_CONFIG)
	$(XEN_MAKE) dist-tools

dist-xen:
	$(XEN_CONFIG)
	$(XEN_MAKE) dist-xen

dist: dist-tools dist-xen

clean:
	$(XEN_MAKE) distclean

$(INITRD_STAMP): 
	touch $(INITRD_STAMP)

create-tools-dirs: create-common-dirs
	mkdir -p $(INITRD_DIR)/var/run/xenstored
	mkdir -p $(INITRD_DIR)/var/run/xen
	mkdir -p $(INITRD_DIR)/var/lib/xen
	mkdir -p $(INITRD_DIR)/var/lock
	mkdir -p $(INITRD_DIR)/domu
# xen-hotplug-common.sh:23 does exec 2>>/var/log/xen/xen-hotplug.log, and
# a failed exec redirect kills a non-interactive bash outright, so the
# directory has to exist or every hotplug script dies before doing
# anything. locking.sh:22 wants the second one.
	mkdir -p $(INITRD_DIR)/var/log/xen
	mkdir -p $(INITRD_DIR)/var/run/xen-hotplug
# hotplugpath.sh points bindir/sbindir/LIBEXEC_BIN at /usr/local/{bin,sbin}
# and /usr/local/lib/xen/bin, none of which exist; the tools live under
# /dist, and initrd-tools moves usr/local/lib/* into /lib. Link rather
# than patch their PATH, so the stock scripts run unmodified.
	mkdir -p $(INITRD_DIR)/usr/local
	ln -sfn /dist/install/usr/local/bin $(INITRD_DIR)/usr/local/bin
	ln -sfn /dist/install/usr/local/sbin $(INITRD_DIR)/usr/local/sbin
	ln -sfn /lib $(INITRD_DIR)/usr/local/lib
# libxl's compiled-in XEN_SCRIPT_DIR is /etc/xen/scripts (tools/config.h).
	ln -sfn /dist/install/etc/xen/scripts $(INITRD_DIR)/etc/xen/scripts
	cp $(CONFIGS_DIR)/xl.conf $(INITRD_DIR)/etc/xen/
# domu.cfg is the single-node run; domu-mn.cfg and domu2.cfg the two-node one.
	cp $(CONFIGS_DIR)/domu*.cfg $(INITRD_DIR)/domu/
	cp $(DOMU_KERNEL) $(INITRD_DIR)/domu/Image.gz
	cp $(DOMU_INITRD_IMG) $(INITRD_DIR)/domu/initrd.img

create-common-dirs:
	mkdir -p $(INITRD_DIR)/dev
# Mount point for a run-time tmpfs. The ext2 rootfs IS the ramdisk, so a
# file written under /domu spends the filesystem's own free blocks; a disk
# image belongs on a tmpfs, which costs dom0 RAM instead.
	mkdir -p $(INITRD_DIR)/mnt
	mkdir -p $(INITRD_DIR)/dist
	mkdir -p $(INITRD_DIR)/proc
	mkdir -p $(INITRD_DIR)/sys
	mkdir -p $(INITRD_DIR)/etc/init.d
	mkdir -p $(INITRD_DIR)/etc/xen

initrd : $(INITRD_STAMP) create-common-dirs
	echo "Building initrd image"
	printf '%s\n' \
	'#!/bin/sh' \
	'echo "Hello RISC-V World!"' \
	'mount -t proc proc /proc' \
	'mount -t xenfs xenfs /proc/xen' \
	'mount -t sysfs sysfs /sys' \
	'exec /bin/sh' \
	> $(RCS_FILE) && \
	chmod +x $(RCS_FILE)
	cp $(RCS_FILE) $(INITRD_DIR)/etc/init.d/
	sh $(LIBCHECK) $(INITRD_DIR)
	genext2fs -b 6500 -N 1024 -U -d $(INITRD_DIR)/ $(INITRD)

# The kernel mounts a bare devtmpfs on /dev, which has neither the
# /dev/fd family (udev or mdev would create those) nor devpts, and it
# hides anything placed under /dev in the image, so both are made at
# boot. locking.sh's claim_lock stats /dev/stdin to check it holds the
# lock; without the link it retries forever and every block hotplug
# times out. xenconsoled calls openpty(), which needs a mounted devpts.
initrd-tools: dist-tools create-tools-dirs
	echo "Building initrd with tools image"
	cd $(XEN_ROOT)/dist && tar --exclude='*.a' -cf - . \
	    | (cd $(INITRD_DIR)/dist && tar -xf -)
	mv $(INITRD_DIR)/dist/install/usr/local/lib/* $(INITRD_DIR)/lib/
	printf '%s\n' \
	'#!/bin/sh' \
	'echo "Hello RISC-V World!"' \
	'mount -t proc proc /proc' \
	'mount -t xenfs xenfs /proc/xen' \
	'mount -t sysfs sysfs /sys' \
	'ln -sfn /proc/self/fd /dev/fd' \
	'ln -sf /proc/self/fd/0 /dev/stdin' \
	'ln -sf /proc/self/fd/1 /dev/stdout' \
	'ln -sf /proc/self/fd/2 /dev/stderr' \
	'mkdir -p /dev/pts' \
	'mount -t devpts devpts /dev/pts' \
	'./dist/install/usr/local/sbin/xenstored' \
	'sleep 1' \
	'./lib/xen/bin/xen-init-dom0' \
	'exec /bin/sh' \
	> $(RCS_FILE) && \
	chmod +x $(RCS_FILE)
	cp $(RCS_FILE) $(INITRD_DIR)/etc/init.d/
	sh $(LIBCHECK) $(INITRD_DIR)
	genext2fs -b 250000 -N 1444 -U -d $(INITRD_DIR)/ $(INITRD)
	
# Build targets
build-tools:
	$(TOOLS_CONFIG)
	$(XEN_MAKE) build-tools

build-xen:
	$(XEN_CONFIG)
	$(XEN_MAKE) build-xen

build: build-tools build-xen


go: $(INITRD) $(KERNEL) $(QEMU) $(OPENSBI) $(XEN_BIN) $(DTB_SCRIPT)
	cd $(DTB_DIR) && \
	bash $(DTB_SCRIPT) dom0-test $(DTB_DIR) $(OPENSBI) $(QEMU) $(XEN_BIN) $(KERNEL) $(INITRD)
	$(QEMU) $(QEMU_BASE_FLAGS)

go-debug: $(INITRD) $(KERNEL) $(QEMU) $(OPENSBI) $(XEN_BIN) $(DTB_SCRIPT)
	cd $(DTB_DIR) && \
	bash $(DTB_SCRIPT) dom0-test $(DTB_DIR) $(OPENSBI) $(QEMU) $(XEN_BIN) $(KERNEL) $(INITRD)
	$(QEMU) $(QEMU_BASE_FLAGS) $(QEMU_DEBUG_FLAGS)

gdb: $(GDB)
	$(GDB) $(GDB_FLAGS) $(GDB_ARGS)
