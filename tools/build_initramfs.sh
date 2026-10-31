#!/bin/sh
# Build the initramfs cpio.gz.
#
#   build_initramfs.sh <busybox-binary> <output.cpio.gz>
#
# The busybox must be a *static aarch64* build (see .github/workflows/build.yml,
# which cross-compiles one).  The init script comes from ../initramfs/init.
set -eu

BB=${1:?path to a static aarch64 busybox}
OUT=${2:?output cpio.gz}
HERE=$(cd "$(dirname "$0")" && pwd)
INIT=$HERE/../initramfs/init

[ -x "$BB" ] || { echo "busybox not executable: $BB" >&2; exit 1; }
[ -f "$INIT" ] || { echo "init script missing: $INIT" >&2; exit 1; }

D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT

mkdir -p "$D/bin" "$D/dev" "$D/proc" "$D/sys" "$D/tmp" "$D/mnt" "$D/lib/firmware"
cp "$BB" "$D/bin/busybox.static"
cp "$INIT" "$D/init"
chmod +x "$D/init" "$D/bin/busybox.static"

( cd "$D" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$OUT"
echo "wrote $OUT ($(stat -c%s "$OUT") bytes)"
