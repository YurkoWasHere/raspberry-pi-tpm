#!/usr/bin/env bash
# Build the payload and overlays (Docker: the vc4-binutils image from tools/vc4, debian for dtc).
#   firmware/build.sh                  -> tpm-measure.blob, overlays/*.dtbo, and tpm-measure.bootcode.bin
#                                         if a stock bootcode.bin is found (netboot rootfs or $STOCK)
set -euo pipefail
cd "$(dirname "$0")"

docker run --rm -v "$PWD":/work vc4-binutils sh -euc '
  vc4-elf-as -o tpm-measure.o tpm-measure.s
  vc4-elf-objcopy -O binary tpm-measure.o tpm-measure.blob
  vc4-elf-objdump -d tpm-measure.o > tpm-measure.lst'
echo "tpm-measure.blob: $(stat -c %s tpm-measure.blob) bytes"

docker run --rm -v "$PWD/overlays":/o debian:trixie sh -euc '
  apt-get -qq update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y device-tree-compiler >/dev/null
  for d in /o/*.dts; do dtc -q -@ -I dts -O dtb -o "${d%.dts}.dtbo" "$d"; done
  chown '"$(id -u):$(id -g)"' /o/*.dtbo'
ls overlays/*.dtbo

STOCK=${STOCK:-../srv/rootfs/usr/lib/raspi-firmware/bootcode.bin}
if [ -r "$STOCK" ]; then
  python3 -I apply.py "$STOCK" tpm-measure.blob tpm-measure.bootcode.bin
else
  echo "no stock bootcode.bin at $STOCK: run ./make-bootcode.py to produce one"
fi
