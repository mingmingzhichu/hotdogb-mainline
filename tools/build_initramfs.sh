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
# ramdisk.  The only firmware that goes in is the Adreno set (~43 KB
# compressed, see below); everything bigger (ath10k modules, modem.mbn,
# board-2.bin) is staged from the USB LUN at runtime by /bin/wifi_up.sh.
set -eu

BB=${1:?path to a static aarch64 busybox}
OUT=${2:?output cpio.gz}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../initramfs

[ -x "$BB" ] || { echo "busybox not executable: $BB" >&2; exit 1; }
[ -f "$SRC/init" ] || { echo "init script missing: $SRC/init" >&2; exit 1; }

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

# The msm/adreno driver is built in and asks for the GPU firmware while the
# rootfs (NBD or otherwise) is not mounted yet.  The three blobs are only
# ~43 KB compressed, so they fit in the ramdisk even with the ~48 MiB
# `fastboot boot` limit; the Debian rootfs still ships its own copy for
# later loads.  Do not add the DSP/WiFi firmware here: wlanmdsp.mbn + slpi.*
# + adsp.* are ~12 MB compressed and would push the boot image over the
# limit, so /init copies those from modem_a at runtime.
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
