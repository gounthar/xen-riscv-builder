# trixie-riscv64

This Dockerfile provides a Docker environment to build `xen`, `xen/tools`, and an `initrd` for dom0 to boot on RISC-V architecture.

The environment is a Linux/amd64 Debian Trixie.

## Getting started

Some dependencies are cross-compiled for RISC-V (e.g., `python3-dev:riscv64`) using `dpkg`'s multi-arch feature. Since some must execute during post-installation, we need to use [`qemu-user-static`](https://github.com/multiarch/qemu-user-static) emulates the RISC-V architecture on the host. 

To install `qemu-user-static` on your host:
```sh
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
docker run --rm -t --platform=linux/riscv64 riscv64/debian uname -m
riscv64 # The docker is successfully in a riscv environment
```

## Usage

The trixie-riscv64 image is available on Docker Hub. Mount your `xen/` directory:
```sh
docker run --rm -t -u $(id -u):$(id -g) -v /path/to/xen/:/build/xen baptleduc/trixie-riscv64:latest
```

View available Make targets:
```sh
docker run --rm -t -u $(id -u):$(id -g) -v /path/to/xen/:/build/xen baptleduc/trixie-riscv64:latest make help
```

### Build `initrd`

To build basic initrd that going to be mounted in dom0 at boot time :
```sh
docker run --rm -t -u $(id -u):$(id -g) -v /path/to/xen/:/build/xen baptleduc/trixie-riscv64:latest make initrd
```

To build `xen/tools` and include them in `initrd`:
```sh
docker run --rm -t -u $(id -u):$(id -g) -v /path/to/xen/:/build/xen baptleduc/trixie-riscv64:latest make initrd-tools
```

### Xen compile commands

Xen `build-*` and `dist-*` commands are available: 
```sh
docker run --rm -t -u $(id -u):$(id -g) -v /path/to/xen/:/build/xen baptleduc/trixie-riscv64:latest make build-xen
docker run --rm -t -u $(id -u):$(id -g) -v /path/to/xen/:/build/xen baptleduc/trixie-riscv64:latest make build-tools
docker run --rm -t -u $(id -u):$(id -g) -v /path/to/xen/:/build/xen baptleduc/trixie-riscv64:latest make build
```

```sh
docker run --rm -t -u $(id -u):$(id -g) -v /path/to/xen/:/build/xen baptleduc/trixie-riscv64:latest make dist-xen
docker run --rm -t -u $(id -u):$(id -g) -v /path/to/xen/:/build/xen baptleduc/trixie-riscv64:latest make dist-tools
docker run --rm -t -u $(id -u):$(id -g) -v /path/to/xen/:/build/xen baptleduc/trixie-riscv64:latest make dist
```

### Launch Xen with dom0

**With initrd:**
```sh
docker run --rm -t baptleduc/trixie-riscv64:latest sh -c "make initrd && make go"
```

**With initrd containing tools:**
```sh
docker run --rm -t baptleduc/trixie-riscv64:latest sh -c "make initrd-tools && make go"
```

Note: These commands require a built `xen`

### Custom binaries

Default pre-compiled binaries (Linux Kernel, QEMU, OpenSBI) are provided. Use environment variables to override them:

```sh
docker run --rm -t -u $(id -u):$(id -g) -v /path/to/xen/:/build/xen -e KERNEL=/path/to/your/Image.gz baptleduc/trixie-riscv64:latest sh -c "make initrd-tools && make go"
```

Configurable flags: `KERNEL`, `OPENSBI`, `QEMU`, `XEN_BIN`





