#!/bin/sh
# Build a Debian arm64 rootfs image for the netboot path.
#
# Run as root on a host that can execute arm64 binaries (the CI uses
# qemu-user-static + binfmt-support on an x86_64 runner).
#
#   build_debian_rootfs.sh [rootdir] [output.img] [size]
set -eu

ROOT=${1:-/tmp/debroot}
IMG=${2:-out/netboot-debian.img}
SIZE=${3:-2G}
SUITE=${SUITE:-trixie}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
export DEBIAN_FRONTEND=noninteractive

rm -rf "$ROOT"
mkdir -p "$ROOT" "$(dirname "$IMG")"

debootstrap --arch=arm64 --foreign "$SUITE" "$ROOT" "$MIRROR"

# qemu is only needed for the second stage; it is removed from the image later.
cp /usr/bin/qemu-aarch64-static "$ROOT/usr/bin/"
chroot "$ROOT" /debootstrap/debootstrap --second-stage

cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
chroot "$ROOT" /bin/bash -c '
set -e
apt-get update
apt-get install -y --no-install-recommends openssh-server systemd-sysv
apt-get clean
'

chroot "$ROOT" /bin/bash -c '
set -e
echo hotdogb > /etc/hostname
printf "127.0.0.1 localhost\n127.0.1.1 hotdogb\n" > /etc/hosts
echo "root:root" | chpasswd

mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-usb0.network <<EOF
[Match]
Type=ether
Driver=u_ether

[Network]
Address=172.16.42.1/24
EOF

mkdir -p /etc/ssh/sshd_config.d
printf "PermitRootLogin yes\nPasswordAuthentication yes\n" \
	> /etc/ssh/sshd_config.d/00-hotdogb.conf
ssh-keygen -A

mkdir -p /etc/systemd/system/getty.target.wants
ln -sf /lib/systemd/system/serial-getty@.service \
	/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service

cat > /etc/fstab <<EOF
/dev/nbd0  /      ext4  defaults,noatime  0 1
proc       /proc  proc  defaults          0 0
sysfs      /sys   sysfs defaults          0 0
devtmpfs   /dev   devtmpfs mode=0755,nosuid 0 0
EOF

chmod 644 /etc/systemd/network/10-usb0.network \
	/etc/ssh/sshd_config.d/00-hotdogb.conf /etc/fstab /etc/hostname

# The device kernel has no binfmt_misc; mask the units instead of leaving
# systemd degraded at every boot.
ln -sf /dev/null /etc/systemd/system/proc-sys-fs-binfmt_misc.mount
ln -sf /dev/null /etc/systemd/system/systemd-binfmt.service

rm -f /usr/bin/qemu-aarch64-static
rm -rf /var/lib/apt/lists/*
'

truncate -s "$SIZE" "$IMG"
mke2fs -q -t ext4 -F -L hotdogb-root -d "$ROOT" "$IMG"
echo "wrote $IMG ($(du -h "$IMG" | cut -f1))"
