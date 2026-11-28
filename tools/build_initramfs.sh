#!/bin/sh
# Build the initramfs cpio.gz.
#
#   build_initramfs.sh <busybox-binary> <output.cpio.gz>
#
# The busybox must be a *static aarch64* build (see .github/workflows/build.yml,
# which cross-compiles one).  The init script and the shell tools come from
# ../initramfs/.
#
# The image is deliberately tiny: `fastboot boot` refuses anything above
# ~48 MiB on this bootloader, so the 46 MB kernel leaves roughly 2.7 MB for the
# ramdisk. The only firmware that goes in is the Adreno set (~43 KB
# compressed, see below). The larger modem, WLAN, and DSP firmware is
# extracted from modem_a at runtime or preinstalled in a local rootfs build.
set -eu

BB=${1:?path to a static aarch64 busybox}
OUT=${2:?output cpio.gz}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../initramfs

[ -x "$BB" ] || { echo "busybox not executable: $BB" >&2; exit 1; }
[ -f "$SRC/init" ] || { echo "init script missing: $SRC/init" >&2; exit 1; }

# A wrong file here fails silently and completely: /init is a shell script, so
# without a real /bin/sh the kernel finds no init, panics, and never brings up
# the USB gadget - the handset just sits there scrolling boot messages.
# Debian's busybox-static package ships a 16-byte config file that is also
# called "busybox" (usr/share/initramfs-tools/conf-hooks.d/busybox), and
# `find -name busybox | head -1` can return that one instead of the binary.
size=$(stat -c%s "$BB")
[ "$size" -gt 500000 ] || {
	echo "busybox is only $size bytes, that cannot be the binary: $BB" >&2
	exit 1
}
# `echo` without quotes folds the newlines od puts between bytes.
magic=$(echo $(od -An -tx1 -N4 "$BB") | tr -d ' ')
[ "$magic" = "7f454c46" ] || {
	echo "busybox is not an ELF file: $BB" >&2
	exit 1
}
machine=$(echo $(od -An -tx1 -j18 -N2 "$BB") | tr -d ' ')
[ "$machine" = "b700" ] || {
	echo "busybox is not aarch64 (e_machine=0x$machine): $BB" >&2
	exit 1
}

D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT

mkdir -p "$D/bin" "$D/dev" "$D/proc" "$D/sys" "$D/tmp" "$D/mnt" "$D/lib/firmware"
cp "$BB" "$D/bin/busybox.static"
cp "$SRC/init" "$D/init"
chmod +x "$D/init" "$D/bin/busybox.static"

# Shell helpers that live in the ramdisk.
if [ -d "$SRC/bin" ]; then
	for f in "$SRC"/bin/*; do
		[ -f "$f" ] || continue
		cp "$f" "$D/bin/"
		chmod +x "$D/bin/${f##*/}"
	done
fi

# The msm/adreno driver is built in and asks for GPU firmware before the
# rootfs (NBD or otherwise) is mounted. The three blobs fit in the ramdisk;
# the Debian rootfs also ships its own copies. Keep the larger modem, WLAN,
# and DSP firmware out of initramfs; /init extracts it from modem_a when
# booting without netboot, while local rootfs builds can preinstall it.
FW=$HERE/../firmware
if [ -f "$FW/qcom/a630_sqe.fw" ] && [ -f "$FW/qcom/a640_gmu.bin" ] && \
   [ -f "$FW/qcom/sm8150/a640_zap.mbn" ]; then
	mkdir -p "$D/lib/firmware/qcom/sm8150"
	cp "$FW/qcom/a630_sqe.fw" "$D/lib/firmware/qcom/"
	cp "$FW/qcom/a640_gmu.bin" "$D/lib/firmware/qcom/"
	cp "$FW/qcom/sm8150/a640_zap.mbn" "$D/lib/firmware/qcom/sm8150/"
fi

# Prebuilt static aarch64 binaries that are not part of this repository
# (rmtfs, pd-mapper, tqftpserv, con, qrtr-lookup, wifiscan) go next to these
# sources: place them in initramfs/bin/ and they are picked up above, or copy
# them into $D/bin before this runs.

( cd "$D" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$OUT"
echo "wrote $OUT ($(stat -c%s "$OUT") bytes)"
