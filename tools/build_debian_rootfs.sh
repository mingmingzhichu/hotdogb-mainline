#!/bin/sh
# Build a Debian arm64 rootfs image for the netboot path.
#
# Run as root on a host that can execute arm64 binaries (the CI uses
# qemu-user-static + binfmt-support on an x86_64 runner).
#
#   build_debian_rootfs.sh [rootdir] [output.img] [size]
#
# USERSPACE_TOOLS points at the directory produced by tools/build-userspace.sh
# (its sbin/lib/bin/units subdirs).  CI cross-builds those helpers instead of
# shipping prebuilt binaries in the repo.
set -eu

ROOT=${1:-/tmp/debroot}
IMG=${2:-out/netboot-debian.img}
SIZE=${3:-6G}
SUITE=${SUITE:-trixie}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
# Locale of the graphical session.  Override with ROOTFS_LANG=C.UTF-8 for
# an English desktop.
ROOTFS_LANG=${ROOTFS_LANG:-zh_CN.UTF-8}
USERSPACE_TOOLS=${USERSPACE_TOOLS:-}
case "$ROOTFS_LANG" in
*.*) ;;
*) echo "ROOTFS_LANG must look like zh_CN.UTF-8" >&2; exit 1 ;;
esac
export DEBIAN_FRONTEND=noninteractive

rm -rf "$ROOT"
mkdir -p "$ROOT" "$(dirname "$IMG")"

debootstrap --arch=arm64 --foreign "$SUITE" "$ROOT" "$MIRROR"

# qemu is only needed for the second stage; it is removed from the image later.
cp /usr/bin/qemu-aarch64-static "$ROOT/usr/bin/"
chroot "$ROOT" /debootstrap/debootstrap --second-stage

# Give the chroot a real /proc, /sys and /dev so apt and the maintainer
# scripts do not warn (and behave like a normal system).
mount -t proc proc "$ROOT/proc"
mount -t sysfs sysfs "$ROOT/sys"
mount --bind /dev "$ROOT/dev"
cleanup() {
	umount "$ROOT/dev" 2>/dev/null || true
	umount "$ROOT/sys" 2>/dev/null || true
	umount "$ROOT/proc" 2>/dev/null || true
}
trap cleanup EXIT

cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
mkdir -p "$ROOT/etc/apt/sources.list.d"
printf 'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] %s %s non-free-firmware\n' \
	"$MIRROR" "$SUITE" > "$ROOT/etc/apt/sources.list.d/non-free-firmware.list"
ROOTFS_LANG="$ROOTFS_LANG" chroot "$ROOT" /bin/bash -c '
set -e
apt-get update
apt-get install -y --no-install-recommends \
	openssh-server systemd-sysv \
	phosh squeekboard gnome-console greetd zram-tools \
	phosh-mobile-settings phosh-plugins phosh-mobile-tweaks \
	gnome-session-bin gnome-settings-daemon libglib2.0-bin \
	mesa-utils libgl1-mesa-dri mesa-vulkan-drivers vulkan-tools \
	libegl-mesa0 libgles2 libgbm1 \
	wpasupplicant iw wireless-regdb firmware-atheros \
	alsa-ucm-conf alsa-utils \
	iio-sensor-proxy \
	locales fonts-noto-cjk fonts-noto-color-emoji \
	ibus ibus-libpinyin ibus-gtk3 ibus-gtk4 \
	sudo dconf-cli \
	ca-certificates \
	rmtfs tqftpserv
apt-get clean
'

ROOTFS_LANG="$ROOTFS_LANG" chroot "$ROOT" /bin/bash -c '
set -e
echo hotdogb > /etc/hostname
printf "127.0.0.1 localhost\n127.0.1.1 hotdogb\n" > /etc/hosts
echo "root:root" | chpasswd

# Normal desktop account.  Phosh runs as this user; root keeps the serial
# console and the SSH login the test scripts use.
useradd -m -s /bin/bash \
	-G sudo,video,render,audio,input,netdev,plugdev mmzc
echo "mmzc:0717" | chpasswd

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

# The initramfs already assigned 172.16.42.1 to usb0.  Letting networkd
# reconfigure the link flaps it and kills the NBD connection that carries
# the root filesystem.
ln -sf /dev/null /etc/systemd/system/systemd-networkd.service
ln -sf /dev/null /etc/systemd/system/systemd-networkd.socket
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service

# Phosh on the panel, started by greetd on tty1.  Phosh is much lighter
# than Plasma Mobile, which is unusable when the root filesystem lives on
# NBD over USB 2.0.
mkdir -p /etc/greetd
cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
command = "phosh-session"
user = "mmzc"
EOF
systemctl enable greetd
systemctl enable zramswap 2>/dev/null || true
systemctl set-default graphical.target

# --- locale and input method -------------------------------------------
# The shipped session runs in Chinese; ROOTFS_LANG=C.UTF-8 gives an
# English desktop instead.
if [ "$ROOTFS_LANG" != "C.UTF-8" ]; then
	loc=${ROOTFS_LANG%%.*}
	enc=${ROOTFS_LANG#*.}
	sed -i "s/^# *${loc}\.${enc} ${enc}/${loc}.${enc} ${enc}/" /etc/locale.gen
	grep -q "^${loc}\.${enc} ${enc}" /etc/locale.gen || \
		echo "${loc}.${enc} ${enc}" >> /etc/locale.gen
	locale-gen
fi
printf 'LANG=%s\n' "$ROOTFS_LANG" > /etc/locale.conf
update-locale LANG="$ROOTFS_LANG"

# PAM reads /etc/environment for every session, including the one greetd
# starts, so the IM variables reach Phosh without a shell profile.
cat > /etc/environment <<EOF
LANG=$ROOTFS_LANG
GTK_IM_MODULE=ibus
QT_IM_MODULE=ibus
XMODIFIERS=@im=ibus
EOF

# IBus has to be started by the session.  squeekboard commits text
# directly and never goes through an IM context, so this is what makes
# pinyin work on an external keyboard.
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/ibus-daemon.desktop <<EOF
[Desktop Entry]
Type=Application
Name=IBus
Comment=Start the IBus input method daemon
Exec=ibus-daemon -drx
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
chmod 644 /etc/xdg/autostart/ibus-daemon.desktop

# Make libpinyin a system-wide input source, otherwise it only shows up
# after adding it by hand in the settings dialog.
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
cat > /etc/dconf/db/local.d/00-input-sources <<EOF
[org/gnome/desktop/input-sources]
sources=[("xkb", "us"), ("ibus", "libpinyin")]
EOF
dconf update

# The image is built against the upstream mirror (debootstrap is fastest
# there on the CI runner), but it ships pointing at the Tsinghua mirror:
# the phone reaches the network through the USB link and often has to
# install packages on a slow, high-latency connection.
mkdir -p /etc/apt/sources.list.d
cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/debian
Suites: trixie trixie-updates
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/debian-security
Suites: trixie-security
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
rm -f /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/non-free-firmware.list

rm -f /usr/bin/qemu-aarch64-static
rm -rf /var/lib/apt/lists/*
'

install -m 0755 "$(dirname "$0")/hotdogb-audio.sh" \
	"$ROOT/usr/local/sbin/hotdogb-audio"

# Adreno 640 firmware for the msm/freedreno stack.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FIRMWARE="$SCRIPT_DIR/../firmware"
install -d "$ROOT/lib/firmware/qcom/sm8150"
install -m 0644 "$FIRMWARE/qcom/a630_sqe.fw" "$ROOT/lib/firmware/qcom/"
install -m 0644 "$FIRMWARE/qcom/a640_gmu.bin" "$ROOT/lib/firmware/qcom/"
install -m 0644 "$FIRMWARE/qcom/sm8150/a640_zap.mbn" \
	"$ROOT/lib/firmware/qcom/sm8150/"

# Device-specific firmware is kept locally in this Git-ignored directory.
# Set HOTDOGB_FIRMWARE_BACKUP to use another directory containing firmware_mnt/.
FIRMWARE_BACKUP=${HOTDOGB_FIRMWARE_BACKUP:-"$SCRIPT_DIR/../firmware"}
LOCAL_FIRMWARE="$FIRMWARE_BACKUP/firmware_mnt"
if [ -d "$LOCAL_FIRMWARE" ]; then
	for file in modem.mdt modem.b00 modem.b31 wlanmdsp.mbn bdwlan.bin \
		slpi.mdt adsp.mdt; do
		if [ ! -f "$LOCAL_FIRMWARE/$file" ]; then
			echo "missing local firmware: $LOCAL_FIRMWARE/$file" >&2
			exit 1
		fi
	done

	MODEM_FW="$ROOT/lib/firmware/qcom/sm8150/oneplus7"
	ATH10K_FW="$ROOT/lib/firmware/ath10k/WCN3990/hw1.0"
	install -d "$MODEM_FW" "$ATH10K_FW"
	install -m 0644 "$LOCAL_FIRMWARE"/modem.mdt \
		"$LOCAL_FIRMWARE"/modem.b* "$MODEM_FW/"
	install -m 0644 "$LOCAL_FIRMWARE"/wlanmdsp.mbn \
		"$LOCAL_FIRMWARE"/slpi.* "$LOCAL_FIRMWARE"/*.jsn "$MODEM_FW/"
	install -m 0644 "$LOCAL_FIRMWARE"/adsp.* "$ROOT/lib/firmware/qcom/sm8150/"
	install -m 0644 "$LOCAL_FIRMWARE"/wlanmdsp.mbn "$ATH10K_FW/"
	install -m 0644 "$LOCAL_FIRMWARE/bdwlan.bin" "$ATH10K_FW/board.bin"
	echo "included local OnePlus 7T modem, WLAN, SLPI and ADSP firmware"

	# Radio service chain.  The initramfs radio section is skipped under
	# hotdogb.netboot=1, so on a netbooted Debian nothing starts MPSS unless
	# hotdogb-radio.service is started explicitly.  The Debian packages rmtfs
	# and tqftpserv are already installed (with the correct -r -P -s flags for
	# rmtfs); the only missing piece is pd-mapper, which Debian does not
	# package, so ship the statically linked aarch64 binary.  The ordered
	# start script prefers the distro services and only falls back to the
	# static binaries.  The unit is manual-only and guarded by
	# ConditionPathExists on modem.mdt, so it cannot start MPSS at boot.
	install -d "$ROOT/usr/local/sbin"
	if [ -n "$USERSPACE_TOOLS" ]; then
		# CI cross-builds these; see tools/build-userspace.sh.
		for t in pd-mapper rmtfs tqftpserv; do
			install -m 0755 "$USERSPACE_TOOLS/sbin/$t" \
				"$ROOT/usr/local/sbin/$t"
		done
		# libssc + SSC-enabled iio-sensor-proxy (sensor data via SLPI).
		[ -d "$USERSPACE_TOOLS/lib" ] && \
			cp -a "$USERSPACE_TOOLS/lib"/. "$ROOT/usr/lib/aarch64-linux-gnu/"
		[ -f "$USERSPACE_TOOLS/bin/iio-sensor-proxy" ] && \
			install -m 0755 "$USERSPACE_TOOLS/bin/iio-sensor-proxy" \
				"$ROOT/usr/bin/iio-sensor-proxy"
		[ -d "$USERSPACE_TOOLS/units" ] && \
			cp -a "$USERSPACE_TOOLS/units"/. "$ROOT/usr/lib/udev/rules.d/"
		ldconfig -r "$ROOT" 2>/dev/null || true
	else
		echo "USERSPACE_TOOLS not set: radio helpers and sensor stack omitted" >&2
	fi
	install -m 0755 "$SCRIPT_DIR/hotdogb-radio.sh" \
		"$ROOT/usr/local/sbin/hotdogb-radio.sh"
	install -m 0644 "$SCRIPT_DIR/hotdogb-radio.service" \
		"$ROOT/etc/systemd/system/hotdogb-radio.service"
	echo "installed hotdogb-radio (manual start) + userspace tools"
elif [ -n "${HOTDOGB_FIRMWARE_BACKUP:-}" ]; then
	echo "firmware backup not found: $FIRMWARE_BACKUP" >&2
	exit 1
else
	echo "warning: local device firmware omitted; populate firmware/firmware_mnt or set HOTDOGB_FIRMWARE_BACKUP" >&2
fi

# The mounts must be gone before mke2fs walks the tree.
cleanup
trap - EXIT

truncate -s "$SIZE" "$IMG"
mke2fs -q -t ext4 -F -L hotdogb-root -d "$ROOT" "$IMG"

# The script runs with sudo; give the image back to the invoking user so
# the later xz/sha256sum steps (which run unprivileged) can own the output.
if [ -n "${SUDO_UID:-}" ]; then
	chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$IMG"
fi
echo "wrote $IMG ($(du -h "$IMG" | cut -f1))"
