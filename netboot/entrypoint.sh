#!/usr/bin/env bash
# DHCP + TFTP (dnsmasq) and NFS root for a network-booting Raspberry Pi, bound to one dedicated NIC.
set -euo pipefail

# Safety: a DHCP server on the wrong interface hands out addresses on your LAN
ip link show "$IFACE" >/dev/null 2>&1 || { echo "IFACE=$IFACE does not exist (set it in .env)"; exit 1; }
if ip route show default | grep -qw "dev $IFACE"; then
  echo "Refusing: $IFACE has a default route, so it looks like your LAN, not a direct Pi link"; exit 1
fi
ip link set "$IFACE" up
ip -4 addr show dev "$IFACE" | grep -q "inet $SERVER_IP/" || ip addr add "$SERVER_IP/$PREFIX" dev "$IFACE"

# Boot tree: the selected directory is bind-mounted over /srv/tftp, so the TFTP root, the NFS
# export and the Pi's /boot/firmware fstab entry (10.42.0.1:/srv/tftp) all follow it.
BOOT_TREE=${BOOT_TREE:-tftp}
case "$BOOT_TREE" in
  tftp) ;;
  tftp-uboot)
    [ -f /srv/tftp-uboot/u-boot.bin ] || { echo "BOOT_TREE=tftp-uboot but /srv/tftp-uboot/u-boot.bin is missing"; exit 1; }
    mount --bind /srv/tftp-uboot /srv/tftp ;;
  *) echo "BOOT_TREE must be tftp or tftp-uboot, got '$BOOT_TREE'"; exit 1 ;;
esac
echo "Boot tree: srv/$BOOT_TREE"

# Kernel NFS server (host kernel; rpcbind is the host's, already on :111)
modprobe nfsd
mountpoint -q /proc/fs/nfsd || mount -t nfsd nfsd /proc/fs/nfsd
NET="${SERVER_IP%.*}.0/$PREFIX"
cat > /etc/exports <<EXP
/srv/rootfs $NET(rw,sync,no_root_squash,no_subtree_check,fsid=1)
/srv/tftp   $NET(rw,sync,no_root_squash,no_subtree_check,fsid=2)
EXP
exportfs -ra
rpc.mountd
rpc.nfsd -H "$SERVER_IP" 8

cleanup() { rpc.nfsd 0; exportfs -ua; pkill rpc.mountd || true; ip addr del "$SERVER_IP/$PREFIX" dev "$IFACE" 2>/dev/null || true; }
trap cleanup EXIT

echo "Serving Pi netboot on $IFACE ($SERVER_IP)"
dnsmasq --no-daemon --log-dhcp --log-queries \
  --port=0 --interface="$IFACE" --bind-interfaces --except-interface=lo \
  --dhcp-range="$DHCP_RANGE,12h" --dhcp-option=3 --dhcp-option=6 \
  --enable-tftp --tftp-root=/srv/tftp \
  --pxe-service=0,"Raspberry Pi Boot"
