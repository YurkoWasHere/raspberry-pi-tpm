#!/usr/bin/env bash
# Adapt the unpacked image in ../srv for network boot: NFS root, no SD resize/initramfs,
# a "pi" user with your SSH key, TPM overlay enabled. Re-run safely after prepare.sh.
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
SRV=$(realpath ../srv)
PUBKEY=$(cat "${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}")
[ -f pi-password.txt ] || (umask 077; openssl rand -base64 12 > pi-password.txt)
PASSWORD=$(cat pi-password.txt)
export PUBKEY PASSWORD

docker run --rm -v "$SRV":/srv -e SERVER_IP -e PUBKEY -e PASSWORD debian:trixie bash -euc '
  T=/srv/tftp R=/srv/rootfs

  # Kernel mounts / over NFS itself; no initramfs, no partition resize
  echo "console=serial0,115200 console=tty1 root=/dev/nfs nfsroot=$SERVER_IP:/srv/rootfs,vers=3,tcp,nolock ip=dhcp rw rootwait" > $T/cmdline.txt
  sed -i "s/^auto_initramfs=1/auto_initramfs=0/" $T/config.txt
  sed -i "/# --- netboot ---/,\$d" $T/config.txt
  cat >> $T/config.txt <<CFG
# --- netboot ---
[all]
enable_uart=1
dtparam=spi=on
dtoverlay=tpm-slb9670
dtoverlay=tpm-eventlog
dtoverlay=tpm-rst-guard
CFG

  # /boot/firmware is the TFTP dir over NFS, so kernel updates on the Pi land where TFTP serves them
  # addr= lets the kernel mount without nfs-common, which Lite does not ship
  cat > $R/etc/fstab <<FSTAB
proc  /proc  proc  defaults  0  0
$SERVER_IP:/srv/tftp  /boot/firmware  nfs  vers=3,tcp,nolock,addr=$SERVER_IP,_netdev  0  0
FSTAB

  # Kernel already configured eth0 via ip=dhcp; if NetworkManager or cloud-init re-DHCP it, the NFS root drops
  echo -e "[keyfile]\nunmanaged-devices=interface-name:eth0" > $R/etc/NetworkManager/conf.d/90-netboot.conf
  echo "network: {config: disabled}" > $R/etc/cloud/cloud.cfg.d/90-netboot.cfg
  echo "nameserver $SERVER_IP" > $R/etc/resolv.conf.netboot

  # Set up the placeholder "pi" account directly. cloud-init cannot be used here: its
  # generator looks for user-data before /boot/firmware is NFS-mounted, and disables itself.
  apt-get -qq update >/dev/null && apt-get -qq install -y openssl >/dev/null
  HASH=$(openssl passwd -6 "$PASSWORD")
  sed -i "s|^pi:[^:]*:|pi:$HASH:|" $R/etc/shadow
  sed -i "s|^\(pi:.*:\)/usr/sbin/nologin$|\1/bin/bash|" $R/etc/passwd
  for g in sudo adm dialout gpio spi i2c tss video plugdev; do
    grep -q "^$g:" $R/etc/group || continue
    grep -qE "^$g:.*[:,]pi(,|$)" $R/etc/group || sed -i -E "s/^($g:[^:]*:[^:]*:)(.+)$/\1\2,pi/; s/^($g:[^:]*:[^:]*:)$/\1pi/" $R/etc/group
  done
  echo "pi ALL=(ALL) NOPASSWD: ALL" > $R/etc/sudoers.d/010_pi-nopasswd && chmod 0440 $R/etc/sudoers.d/010_pi-nopasswd
  install -d -m 700 -o 1000 -g 1000 $R/home/pi/.ssh
  echo "$PUBKEY" > $R/home/pi/.ssh/authorized_keys
  chown 1000:1000 $R/home/pi/.ssh/authorized_keys && chmod 600 $R/home/pi/.ssh/authorized_keys
  [ -e $R/home/pi/.bashrc ] || install -o 1000 -g 1000 -m 644 $R/etc/skel/.bashrc $R/etc/skel/.profile $R/home/pi/
  # First-boot user prompt and cloud-init are no longer needed
  rm -f $R/etc/ssh/sshd_config.d/rename_user.conf $R/etc/systemd/system/multi-user.target.wants/userconfig.service
  touch $R/etc/cloud/cloud-init.disabled
  echo "pi3-tpm" > $R/etc/hostname
  sed -i "s/raspberrypi/pi3-tpm/g" $R/etc/hosts
  rm -f $T/user-data
'
echo "Configured. Login: pi / $(cat pi-password.txt) (also your SSH key)"
