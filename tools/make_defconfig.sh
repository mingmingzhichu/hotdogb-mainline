#!/bin/sh
# Regenerate configs/hotdogb_defconfig from the kernel tree you are standing in.
#
#   cd <linux tree>
#   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig   # 改点东西
#   /path/to/hotdogb-mainline/tools/make_defconfig.sh
#
# The committed file is exactly `make savedefconfig` output - no hand-written
# header, no merge step - so this script is just: run it, copy it over.
set -e

here=$(cd "$(dirname "$0")" && pwd)
out=$here/../configs/hotdogb_defconfig

if [ ! -f Makefile ] || [ ! -d arch/arm64 ]; then
	echo "run this from the configured kernel tree" >&2
	exit 1
fi
if [ ! -f .config ]; then
	echo "no .config here; configure the tree first" >&2
	exit 1
fi

make ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}" \
	savedefconfig >/dev/null
[ -f defconfig ] || { echo "savedefconfig produced nothing" >&2; exit 1; }

cp defconfig "$out"
echo "$out: $(grep -c '' "$out") lines"
