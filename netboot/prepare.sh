#!/usr/bin/env bash
# Unpack a Raspberry Pi OS image into ../srv/tftp (boot partition) and ../srv/rootfs (root partition).
# Runs the mounting inside a privileged container so no host sudo is needed.
set -euo pipefail
IMG=$(realpath "${1:?usage: prepare.sh <image.img>}")
SRV=$(realpath "$(dirname "$0")/../srv")
# Partition start/size in bytes, from the image's partition table
read -r BOOT_OFF BOOT_LEN ROOT_OFF ROOT_LEN < <(/usr/sbin/sfdisk -d "$IMG" |
  sed -n 's/.*start= *\([0-9]*\), size= *\([0-9]*\).*/\1 \2/p' | awk '{printf "%d %d ", $1*512, $2*512} END{print ""}')
mkdir -p "$SRV"
docker run --rm --privileged -e DEBIAN_FRONTEND=noninteractive \
  -v "$IMG":/image.img:ro -v "$SRV":/srv debian:trixie bash -euc "
  apt-get -qq update >/dev/null && apt-get -qq install -y rsync >/dev/null
  mkdir -p /mnt/boot /mnt/root /srv/tftp /srv/rootfs
  # One at a time: the container only sees the loop devices that existed when it started
  mount -o loop,ro,offset=$BOOT_OFF,sizelimit=$BOOT_LEN /image.img /mnt/boot
  rsync -a --delete /mnt/boot/ /srv/tftp/
  umount /mnt/boot
  mount -o loop,ro,offset=$ROOT_OFF,sizelimit=$ROOT_LEN /image.img /mnt/root
  rsync -aHAX --numeric-ids --delete /mnt/root/ /srv/rootfs/
  umount /mnt/root
"
echo "Unpacked into $SRV/tftp and $SRV/rootfs"
