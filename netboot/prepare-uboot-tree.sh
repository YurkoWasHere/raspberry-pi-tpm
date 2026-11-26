#!/usr/bin/env bash
# Build ../srv/tftp-uboot: the live boot tree with start.elf loading U-Boot instead of the kernel.
# Reads ../srv/tftp (never modifies it). Stock bootcode.bin; u-boot.bin from ../tools/uboot/out.
#   ./prepare-uboot-tree.sh            then switch with BOOT_TREE=tftp-uboot in .env
set -euo pipefail
cd "$(dirname "$0")"
SRV=$(realpath ../srv)
UBOOT=$(realpath ../tools/uboot/out)/u-boot.bin
[ -f "$UBOOT" ] || echo "warning: $UBOOT not built yet; tree prepared without it"
docker run --rm -v "$SRV":/srv -v "$(dirname "$UBOOT")":/uboot:ro debian:trixie bash -euc '
  apt-get -qq update >/dev/null && apt-get -qq install -y rsync >/dev/null
  rsync -a --delete --exclude bootcode.bin --exclude bootcode.bin.orig /srv/tftp/ /srv/tftp-uboot/
  cp -p /srv/tftp/bootcode.bin.orig /srv/tftp-uboot/bootcode.bin      # stock, unpatched
  [ -f /uboot/u-boot.bin ] && cp /uboot/u-boot.bin /srv/tftp-uboot/u-boot.bin
  C=/srv/tftp-uboot/config.txt
  sed -i "/# --- netboot ---/,\$d" $C
  cat >> $C <<CFG
# --- netboot ---
[all]
enable_uart=1
uart_2ndstage=1
dtparam=spi=on
dtoverlay=tpm-slb9670
# --- u-boot ---
kernel=u-boot.bin
CFG
'
echo "Prepared $SRV/tftp-uboot"
