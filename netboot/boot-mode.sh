#!/usr/bin/env bash
# Switch the netboot tree between stock firmware and the measured-boot build.
#   ./boot-mode.sh stock      # stock bootcode.bin from the rootfs raspi-firmware package, no event-log overlay
#   ./boot-mode.sh measured   # patched bootcode.bin + overlays from firmware/ (run firmware/build.sh first)
#   ./boot-mode.sh status
# Stock files come from the Debian packages inside the rootfs, not from backups:
#   /usr/lib/raspi-firmware/{bootcode.bin,start.elf,fixup.dat}            (raspi-firmware)
#   /usr/lib/linux-image-<ver>/{broadcom/*.dtb,overlays/*.dtbo}           (linux-image-<ver>)
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:-status}
STOCK_BOOTCODE=4245ec23b58158dc3e55f3e065eb4ecc0c0705d76c8db506e9f824941feee32e

run() { docker run --rm -v "$PWD/srv":/srv -v "$PWD/firmware":/p:ro debian:trixie sh -euc "$1"; }

case $mode in
  stock)
    run '
      cp /srv/rootfs/usr/lib/raspi-firmware/bootcode.bin /srv/tftp/bootcode.bin
      cp /srv/rootfs/usr/lib/raspi-firmware/start.elf    /srv/tftp/start.elf
      cp /srv/rootfs/usr/lib/raspi-firmware/fixup.dat    /srv/tftp/fixup.dat
      sed -i "/^dtoverlay=tpm-eventlog$/d; /^dtoverlay=tpm-rst-guard$/d; /^uart_2ndstage=1$/d" /srv/tftp/config.txt
      rm -f /srv/tftp/overlays/tpm-eventlog.dtbo /srv/tftp/overlays/tpm-rst-guard.dtbo'
    ;;
  measured)
    [ -f firmware/tpm-measure.bootcode.bin ] || { echo "build it first: firmware/build.sh"; exit 1; }
    for o in tpm-eventlog tpm-rst-guard; do
      [ -f firmware/overlays/$o.dtbo ] || { echo "missing firmware/overlays/$o.dtbo: run firmware/build.sh"; exit 1; }
    done
    run '
      cmp -s /srv/rootfs/usr/lib/raspi-firmware/start.elf /srv/tftp/start.elf || cp /srv/rootfs/usr/lib/raspi-firmware/start.elf /srv/tftp/
      cmp -s /srv/rootfs/usr/lib/raspi-firmware/fixup.dat /srv/tftp/fixup.dat || cp /srv/rootfs/usr/lib/raspi-firmware/fixup.dat /srv/tftp/
      cp /p/tpm-measure.bootcode.bin /srv/tftp/bootcode.bin
      cp /p/overlays/tpm-eventlog.dtbo /p/overlays/tpm-rst-guard.dtbo /srv/tftp/overlays/
      grep -q "^uart_2ndstage=1$" /srv/tftp/config.txt || sed -i "s/^enable_uart=1$/enable_uart=1\nuart_2ndstage=1/" /srv/tftp/config.txt
      grep -q "^dtoverlay=tpm-eventlog$" /srv/tftp/config.txt || sed -i "s/^dtoverlay=tpm-slb9670$/dtoverlay=tpm-slb9670\ndtoverlay=tpm-eventlog/" /srv/tftp/config.txt
      grep -q "^dtoverlay=tpm-rst-guard$" /srv/tftp/config.txt || sed -i "s/^dtoverlay=tpm-eventlog$/dtoverlay=tpm-eventlog\ndtoverlay=tpm-rst-guard/" /srv/tftp/config.txt'
    ;;
  status) ;;
  *) echo "usage: $0 stock|measured|status"; exit 1 ;;
esac

h=$(sha256sum srv/tftp/bootcode.bin | cut -d' ' -f1)
if [ "$h" = "$STOCK_BOOTCODE" ]; then echo "bootcode.bin: stock ($h)"; else echo "bootcode.bin: patched ($h)"; fi
grep -E '^(dtoverlay=tpm|uart_2ndstage)' srv/tftp/config.txt | sed 's/^/config.txt: /'
echo "power-cycle the Pi to boot it: netboot/pi-power.sh cycle"
