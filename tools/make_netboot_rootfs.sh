#!/bin/sh
# Build a raw ext4 image for netboot from a root filesystem.
#
#   make_netboot_rootfs.sh <rootfs-dir | rootfs.tar.*> <out.img> [size]
#
# The image is a plain ext4 filesystem without a partition table, which is
# what initramfs/init expects on /dev/nbd0.
#
# mke2fs -d copies the tree into the image without root, but ownership is
# only preserved when running as root.  For the throwaway netboot images we
# use (Alpine minirootfs, Debian container rootfs) that is fine: system files
# keep their modes, they are just owned by the building user.
set -eu

SRC=${1:?rootfs directory or tarball}
OUT=${2:?output image}
SIZE=${3:-2G}

[ -e "$SRC" ] || { echo "missing rootfs: $SRC" >&2; exit 1; }

TMP=
cleanup() {
	[ -n "$TMP" ] && rm -rf "$TMP"
}
trap cleanup EXIT

case "$SRC" in
*.tar|*.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar.zst)
	TMP=$(mktemp -d)
	echo "extracting $SRC"
	tar xf "$SRC" -C "$TMP"
	DIR=$TMP
	;;
*)
	DIR=$SRC
	;;
esac

[ -d "$DIR/etc" ] || { echo "$DIR does not look like a rootfs" >&2; exit 1; }

rm -f "$OUT"
echo "creating $OUT ($SIZE)"
truncate -s "$SIZE" "$OUT"
mke2fs -q -t ext4 -F -L hotdogb-root -d "$DIR" "$OUT"
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
