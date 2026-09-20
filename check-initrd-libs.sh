#!/bin/sh
# Verify that every ELF in the initrd staging tree can resolve its DT_NEEDED
# entries from the libraries present in that same tree.
#
# The runtime library list in trixie-riscv64.dockerfile is maintained by hand.
# When the tools gain a new runtime dependency the list does not follow, and
# nothing reports it: the image builds, the initrd builds, and the failure
# appears only at dom0 boot as "error while loading shared libraries".
#
# Dependencies are resolved transitively by the loader, so checking the
# binaries alone is not enough. Every ELF is scanned, libraries included.

set -eu

root=${1:?usage: check-initrd-libs.sh <initrd-dir>}

have=$(mktemp)
need=$(mktemp)
trap 'rm -f "$have" "$need"' EXIT

find "$root" -name '*.so*' | sed 's|.*/||' | sort -u >"$have"

find "$root" -type f -exec readelf -d {} + 2>/dev/null |
  sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | sort -u >"$need"

missing=$(comm -23 "$need" "$have")

if [ -n "$missing" ]; then
  echo "error: unresolved shared libraries under $root" >&2
  for soname in $missing; do
    echo "  $soname, needed by:" >&2
    find "$root" -type f | while read -r elf; do
      if readelf -d "$elf" 2>/dev/null |
        grep -q "\[$soname\]"; then
        echo "    ${elf#"$root"}" >&2
      fi
    done
  done
  echo "add the missing libraries to the copy list in" \
    "trixie-riscv64.dockerfile" >&2
  exit 1
fi

echo "initrd library check: $(wc -l <"$need") sonames, all resolved"
