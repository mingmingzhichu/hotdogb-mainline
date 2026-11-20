#!/bin/bash
# Cross-build the aarch64 userspace helpers that Debian does not package:
#   - pd-mapper, rmtfs, tqftpserv  (Qualcomm radio service chain)
#   - libssc + iio-sensor-proxy with SSC support (sensor data via SLPI)
#
# Intended to run on ubuntu-24.04 in GitHub Actions.  Produces a tarball
# rooted at ./out/ with:
#   sbin/     pd-mapper, rmtfs, tqftpserv
#   lib/      libssc.so*, and iio-sensor-proxy's libssc drivers
#   bin/      iio-sensor-proxy
#   units/    systemd units + udev rules
set -euxo pipefail

CROSS=${CROSS:-aarch64-linux-gnu-}
WORK=${WORK:-/tmp/hotdogb-userspace}
OUT=${OUT:-out}
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"/{sbin,lib,bin,units}

PKGS=(
  build-essential gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
  libc6-dev-arm64-cross libudev-dev:arm64 liblzma-dev:arm64
  libglib2.0-dev:arm64 libgudev-1.0-dev:arm64 libqmi-glib-dev:arm64
  libprotobuf-c-dev:arm64 libqrtr-dev:arm64
  protobuf-compiler meson ninja-build pkg-config
  libqmi-utils curl git patch xz-utils
)
if [ "${INSTALL_DEPS:-1}" = 1 ]; then
  sudo dpkg --add-architecture arm64
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends "${PKGS[@]}"
fi

cd "$WORK"
gitclone() { git clone --depth 1 "$1" "$2"; }

# Meson cross file used by qrtr, tqftpserv, libssc and iio-sensor-proxy.
cat > aarch64.ini <<EOF
[binaries]
c = '${CROSS}gcc'
ar = '${CROSS}ar'
strip = '${CROSS}strip'
pkgconfig = 'pkg-config'
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
sys_root = '/usr/aarch64-linux-gnu'
EOF

# --- qrtr (provides libqrtr.a, needed by all three radio tools) ------------
gitclone https://github.com/andersson/qrtr.git qrtr
meson setup qrtr-build qrtr --cross-file aarch64.ini \
  -Ddefault_library=static
meson compile -C qrtr-build
# Find the static lib wherever meson placed it.
QRTR_LIB=$(find qrtr-build -name 'libqrtr.a' | head -1)
[ -n "$QRTR_LIB" ] || { echo "libqrtr.a not built" >&2; exit 1; }
QRTR_A_DIR=$(dirname "$QRTR_LIB")
QRTR_INC="$WORK/qrtr/include"

build_static() { # $1=dir  $2=binary  $3=extra CFLAGS  $4=extra LDLIBS
  local d=$1 bin=$2 cflags=$3 ldlibs=$4
  make -C "$d" clean >/dev/null 2>&1 || true
  make -C "$d" CC="${CROSS}gcc" AR="${CROSS}ar" \
    CFLAGS="-O2 -I$QRTR_INC $cflags" \
    LDFLAGS="-static -L$QRTR_A_DIR $ldlibs" "$bin"
  file "$d/$bin" | grep -q 'aarch64'
  install -m 0755 "$d/$bin" "$OUT/sbin/$bin"
}

# pd-mapper needs libqrtr + liblzma; its .qmi is pre-generated in-tree.
gitclone https://github.com/andersson/pd-mapper.git pd-mapper
build_static pd-mapper pd-mapper "" "-lqrtr -llzma"

# rmtfs needs libudev + pthread.  Static libudev is awkward, so link qrtr
# static but udev dynamically is not acceptable for initramfs-free rootfs;
# Debian ships rmtfs as a package, so these static copies are only fallbacks
# and are linked with the same static flags where possible.
gitclone https://github.com/andersson/rmtfs.git rmtfs
build_static rmtfs rmtfs "" "-lqrtr -ludev -lpthread"

# tqftpserv uses meson with the cross file created above.
gitclone https://github.com/andersson/tqftpserv.git tqftpserv
PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig \
  meson setup tqftpserv-build tqftpserv --cross-file aarch64.ini \
    -Dsystemd-unit-prefix=/lib/systemd/system
meson compile -C tqftpserv-build
file tqftpserv-build/tqftpserv | grep -q aarch64
install -m 0755 tqftpserv-build/tqftpserv "$OUT/sbin/tqftpserv"

# --- libssc (pmOS-tested commit) -------------------------------------------
SSC_COMMIT=5e699fc97d92684c6882741fc9f71cb57a33e25b
REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
git clone https://codeberg.org/DylanVanAssche/libssc.git libssc
git -C libssc checkout "$SSC_COMMIT"
# Threading fix from the pmOS SSC series, applied before compiling libssc.
[ -f "$REPO"/userspace-patches/libssc/20251205-PR103.patch ] && \
  patch -d libssc -p1 --batch --forward \
    < "$REPO"/userspace-patches/libssc/20251205-PR103.patch
PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig \
  meson setup libssc-build libssc --cross-file aarch64.ini \
    -Dprefix=/usr -Dlibdir=lib/aarch64-linux-gnu
meson compile -C libssc-build
DESTDIR="$OUT/root" meson install -C libssc-build --no-rebuild
cp -a "$OUT/root"/usr/lib/aarch64-linux-gnu/libssc* "$OUT/lib/" 2>/dev/null || true
cp -a "$OUT/root"/usr/include/libssc* "$OUT/include/" 2>/dev/null || true

# --- iio-sensor-proxy + SSC patches ----------------------------------------
# The SSC patch series (11 patches) is vendored in userspace-patches/ so the
# build is reproducible and does not depend on pmaports history.  They apply
# in order to the pinned upstream commit.
ISP_COMMIT=fe56bdba1243cc5f6a652eb75d11ae1d1957ff7e
git clone https://gitlab.freedesktop.org/hadess/iio-sensor-proxy.git iio-sp
git -C iio-sp checkout "$ISP_COMMIT"
for p in "$REPO"/userspace-patches/iio-sensor-proxy/0*.patch; do
  [ -f "$p" ] || continue
  patch -d iio-sp -p1 --batch --forward < "$p"
done

PKG_CONFIG_LIBDIR="$OUT/root/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig" \
  meson setup isp-build iio-sp --cross-file aarch64.ini \
    -Dprefix=/usr -Dssc-support=true
meson compile -C isp-build
install -m 0755 isp-build/iio-sensor-proxy "$OUT/bin/" 2>/dev/null || \
  cp isp-build/iio-sensor-proxy "$OUT/bin/"
cp iio-sp/data/80-iio-sensor-proxy*.rules "$OUT/units/" 2>/dev/null || true

( cd "$OUT" && tar czf userspace-tools.tar.gz sbin lib bin units include )
sha256sum "$OUT/userspace-tools.tar.gz"
