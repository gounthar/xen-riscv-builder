# syntax=docker/dockerfile:1
FROM --platform=linux/amd64 debian:trixie-slim AS busybox-builder

ARG BUSYBOX_VER=1.36.1
ENV DEBIAN_FRONTEND=noninteractive
ENV CROSS_COMPILE=riscv64-linux-gnu-

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        gcc-riscv64-linux-gnu \
        libc6-dev-riscv64-cross \
        make \
        curl \
        ca-certificates \
        bzip2 && \
    rm -rf /var/lib/apt/lists/*

# Build busybox
WORKDIR /busybox
RUN \
    curl -fsSLO https://busybox.net/downloads/busybox-$BUSYBOX_VER.tar.bz2 && \
    tar -xf busybox-$BUSYBOX_VER.tar.bz2 -C /busybox --strip-components=1 && \
    cd /busybox && \
    make defconfig && \
    sed "/CONFIG_STATIC\b/s/.*/CONFIG_STATIC=y/" -i .config && \
    sed -i 's/CONFIG_TC=y/# CONFIG_TC is not set/' .config && \
    make -j$(grep -c '^processor' /proc/cpuinfo) && \
    make install CONFIG_PREFIX=/busybox-install

FROM --platform=linux/amd64 debian:trixie-slim

LABEL maintainer.name="Baptiste Le Duc"
LABEL maintainer.email="baptiste.leduc38@gmail.com"

# Directory layout
ENV BINARIES_DIR=/bin
ENV BUILD_DIR=/build
ENV DTB_DIR=/build/dtb
ENV CONFIGS_DIR=/build/configs
ENV RCS_FILE=/build/rcS
ENV INITRD_DIR=/build/initrd
ENV XEN_DIST_DIR=/build/xen/dist
ARG DOMU_INITRD_DIR=/build/domu-initrd
ENV DOMU_INITRD_IMG=${DOMU_INITRD_DIR}/domu-initrd.img
ARG TMP_DOMU_INITRD_DIR=/tmp/domu-initrd

# Cross-compilation settings
ENV DEBIAN_FRONTEND=noninteractive
ENV CROSS_COMPILE=riscv64-linux-gnu-
ENV XEN_TARGET_ARCH=riscv64

WORKDIR ${BUILD_DIR}

# Install dependencies
RUN <<EOF
#!/bin/bash
set -e
dpkg --add-architecture riscv64
useradd --create-home user
apt-get -y update

DEPS=(
    # Xen build
    bison build-essential checkpolicy flex gcc-riscv64-linux-gnu
    # Cross-compiled libs
    zlib1g-dev:riscv64 libyajl-dev:riscv64 uuid-dev:riscv64
    libncurses-dev:riscv64 python3-dev:riscv64 python3-setuptools:riscv64
    # libxl links -lfdt and compiles libxl_libfdt_compat.o for CONFIG_RISCV
    # (tools/libs/light/Makefile:62,169), so the riscv64 libfdt headers and
    # library are required. Upstream's DEPS list omitted this.
    libfdt-dev:riscv64
    # Tools
    wget curl ca-certificates automake genext2fs
    # QEMU phase
    device-tree-compiler libpixman-1-dev libglib2.0-0t64 gdb-multiarch
)

apt-get -y --no-install-recommends install "${DEPS[@]}"
rm -rf /var/lib/apt/lists/*
EOF

# Copy riscv64 runtime libs to initrd
WORKDIR ${INITRD_DIR}
COPY --from=busybox-builder /busybox-install .
# This list is a hand-maintained dependency closure and has to match what the
# tools actually link against at run time:
#   libfdt.so.1   - libxenlight.so.4.18.0 (and so xl, transitively)
#   libm.so.6     - xentop
#   libtinfo.so.6 - libncurses.so.6 (already listed) and xentop
# Verify with: readelf -d <elf> | grep NEEDED, over every ELF in the initrd.
RUN mkdir -p lib && \
    for lib in /usr/lib/ld-linux-riscv64-lp64d.so.1 \
               /usr/lib/riscv64-linux-gnu/libc.so.6 \
               /usr/lib/riscv64-linux-gnu/libuuid.so.1 \
               /usr/lib/riscv64-linux-gnu/libncurses.so.6 \
               /usr/lib/riscv64-linux-gnu/libz.so.1 \
               /usr/lib/riscv64-linux-gnu/libyajl.so.2 \
               /usr/lib/riscv64-linux-gnu/libfdt.so.1 \
               /usr/lib/riscv64-linux-gnu/libm.so.6 \
               /usr/lib/riscv64-linux-gnu/libtinfo.so.6; do \
        cp "$lib" ./lib/; \
    done

# The hotplug scripts libxl execs are #!/bin/bash and use bash-only syntax on
# paths that always run (>&/dev/null, trap ERR, [[ ]], arrays, fd 200), so the
# busybox ash is not a substitute. Unpack the riscv64 package into the initrd
# rather than installing it into the builder, where bash is not Multi-Arch and
# would collide with the host's own amd64 bash.
RUN cd /tmp && \
    apt-get -y update && \
    apt-get -y download bash:riscv64 && \
    dpkg-deb -x bash_*_riscv64.deb /tmp/bash-riscv64 && \
    cp -a /tmp/bash-riscv64/usr/bin/bash ${INITRD_DIR}/bin/bash && \
    rm -rf /tmp/bash-riscv64 /tmp/bash_*_riscv64.deb && \
    rm -rf /var/lib/apt/lists/*

# Catch drift in the list above at image build time. This sees only what the
# image itself provides, which is enough for the libncurses/libtinfo class of
# omission. It cannot see a dependency introduced by the Xen tools, since those
# are built later against a mounted tree, so the Makefile runs the same check
# again once the initrd is fully staged.
COPY check-initrd-libs.sh ${BUILD_DIR}/
RUN sh ${BUILD_DIR}/check-initrd-libs.sh ${INITRD_DIR}


WORKDIR ${BUILD_DIR}

# Build minimal domU initrd from busybox
RUN mkdir -p ${TMP_DOMU_INITRD_DIR}/bin ${TMP_DOMU_INITRD_DIR}/sbin \
             ${TMP_DOMU_INITRD_DIR}/proc ${TMP_DOMU_INITRD_DIR}/sys \
             ${TMP_DOMU_INITRD_DIR}/dev ${TMP_DOMU_INITRD_DIR}/etc/init.d && \
    cp -a ${INITRD_DIR}/bin/busybox ${TMP_DOMU_INITRD_DIR}/bin/ && \
    ${TMP_DOMU_INITRD_DIR}/bin/busybox --install -s ${TMP_DOMU_INITRD_DIR}/bin/ && \
    printf '%s\n' \
        '#!/bin/sh' \
        'mount -t proc proc /proc' \
        'mount -t sysfs sysfs /sys' \
        'echo "domU booted!"' \
        'exec /bin/sh' \
    > ${TMP_DOMU_INITRD_DIR}/etc/init.d/rcS && \
    chmod +x ${TMP_DOMU_INITRD_DIR}/etc/init.d/rcS && \
    mkdir -p ${DOMU_INITRD_DIR} && \
    genext2fs -b 4096 -N 512 -U -d ${TMP_DOMU_INITRD_DIR}/ ${DOMU_INITRD_IMG} && \
    rm -rf ${TMP_DOMU_INITRD_DIR}

# External binaries
# Upstream copied a prebuilt riscv64 guest kernel out of the private image
# baptleduc/riscv64-linux-guest-support, which we cannot pull. We build the
# guest kernel ourselves, outside this image. Create an empty placeholder so
# any Makefile prerequisite on ${BINARIES_DIR}/Image.gz still resolves, and
# pass the real kernel at runtime with -e KERNEL=/path/to/Image.gz
# (e.g. docker run -e KERNEL=/build/linux/arch/riscv/boot/Image.gz ...).
RUN touch ${BINARIES_DIR}/Image.gz

COPY --from=registry.gitlab.com/xen-project/people/olkur/xen/tests-artifacts/qemu-system-riscv64:8.2.0-aia-riscv64 \
    /qemu-system-riscv64 /opensbi-riscv64-generic-fw_dynamic.bin ${BINARIES_DIR}/

# Local files
COPY config_tools.status config_xen.status xl.conf domu.cfg ${CONFIGS_DIR}/
COPY Makefile .
COPY generate_dtb.sh ${DTB_DIR}/

# Set permissions
RUN chmod -R 755 ${BINARIES_DIR} && chown -R user:user ${BUILD_DIR}

USER user
