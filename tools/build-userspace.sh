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
# Resolve every path before the first cd/mkdir: the script later does
# `cd "$WORK"`, and a relative $OUT or $0 would then point inside the build
# tree instead of the staging tree / the checkout.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}
case $WORK in /*) ;; *) WORK=$PWD/$WORK ;; esac
case $OUT in /*) ;; *) OUT=$PWD/$OUT ;; esac
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"/{sbin,lib,bin,units,include}

PKGS=(
  build-essential gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
  libc6-dev-arm64-cross liblzma-dev:arm64
  # iio-sensor-proxy needs libudev itself in addition to libgudev, plus the
  # systemd and polkit .pc files (dependency('systemd'), dependency(
  # 'polkit-gobject-1')), all of which are hard requirements in its meson.build.
  libglib2.0-dev:arm64 libgudev-1.0-dev:arm64 libudev-dev:arm64
  libsystemd-dev:arm64 libpolkit-gobject-1-dev:arm64
  # qmi-glib.pc Requires: mbim-glib, so libqmi is not enough on its own.
  libqmi-glib-dev:arm64 libmbim-glib-dev:arm64
  libprotobuf-c-dev:arm64
  # protoc-c is a native tool but libssc regenerates its protobuf sources.
  protobuf-compiler protobuf-c-compiler
  meson ninja-build pkg-config
  libqmi-utils curl git patch xz-utils
)
# rmtfs and tqftpserv come from the Debian packages already installed by
# build_debian_rootfs.sh; only pd-mapper is missing there (no Debian package).
# Building it statically needs libqrtr.a but not libudev, avoiding the
# unavailable static libudev on Ubuntu.
if [ "${INSTALL_DEPS:-1}" = 1 ]; then
  # Ubuntu's native archive (archive/security.ubuntu.com) has no binary-arm64
  # index: enabling arm64 makes `apt update` 404.  Pin every existing source
  # to amd64, then add ports.ubuntu.com for the arm64 dev packages.
  PORTS_SUITE=${PORTS_SUITE:-$(. /etc/os-release 2>/dev/null && echo "$VERSION_CODENAME")}
  [ -n "$PORTS_SUITE" ] || PORTS_SUITE=noble
  sudo mkdir -p /etc/apt/sources.list.d
  # deb822 .sources files -> insert Architectures after the Types line.
  for f in /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    if ! grep -q '^Architectures:' "$f"; then
      sudo sed -i '/^Types:/a Architectures: amd64' "$f"
    fi
  done
  # Legacy one-line sources in /etc/apt/sources.list, if any.
  if [ -s /etc/apt/sources.list ]; then
    # Idempotent: drop any existing [arch=...] before adding ours, otherwise a
    # re-run yields "deb [arch=amd64] [arch=amd64] http://..." and apt dies
    # with "Malformed entry ... (URI parse)".
    sudo sed -i -E 's/^deb (\[[^]]*\] )?/deb [arch=amd64] /' /etc/apt/sources.list
  fi
  cat <<EOF | sudo tee /etc/apt/sources.list.d/arm64-ports.list
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports $PORTS_SUITE main universe
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports $PORTS_SUITE-updates main universe
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports $PORTS_SUITE-security main universe
EOF
  sudo dpkg --add-architecture arm64
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends "${PKGS[@]}"

  # iio-sensor-proxy's meson asks for dependency('udev').  That .pc file is
  # shipped by the udev package in the arch-independent /usr/share/pkgconfig,
  # where libdir points at the *native* (x86_64) lib directory.  libudev-dev:
  # arm64 has the correct layout, so expose it under the name meson looks for
  # (the search path below keeps this copy ahead of /usr/share/pkgconfig).
  sudo cp /usr/lib/aarch64-linux-gnu/pkgconfig/libudev.pc \
          /usr/lib/aarch64-linux-gnu/pkgconfig/udev.pc
  # meson.build also reads udev_dep.get_pkgconfig_variable('udevdir') to place
  # the rules; that variable only exists in udev.pc, so restore it.
  echo 'udevdir=/lib/udev' | \
    sudo tee -a /usr/lib/aarch64-linux-gnu/pkgconfig/udev.pc >/dev/null
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
EOF
# No [properties] sys_root here: the arm64 -dev packages are installed
# multiarch-style under the real /usr/include and /usr/lib/aarch64-linux-gnu,
# so the paths from pkg-config are already correct.  Setting sys_root would
# make meson prepend it again and gcc would miss glib.h.

# --- qrtr (provides libqrtr.a, needed by all three radio tools) ------------
gitclone https://github.com/andersson/qrtr.git qrtr
meson setup qrtr-build qrtr --cross-file aarch64.ini \
  -Ddefault_library=static
meson compile -C qrtr-build
# Find the static lib wherever meson placed it.
QRTR_LIB=$(find "$WORK/qrtr-build" -name 'libqrtr.a' | head -1)
[ -n "$QRTR_LIB" ] || { echo "libqrtr.a not built" >&2; exit 1; }
# Absolute path: make -C <subdir> changes cwd, so a relative -L breaks.
QRTR_A_DIR=$(cd "$(dirname "$QRTR_LIB")" && pwd)
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
# rmtfs/tqftpserv are intentionally NOT built here: Debian ships both, and
# hotdogb-radio.sh prefers those services (rmtfs with the correct -r -P -s).
gitclone https://github.com/andersson/pd-mapper.git pd-mapper
build_static pd-mapper pd-mapper "" "-lqrtr -llzma"

# --- libssc (pmOS-tested commit) -------------------------------------------
SSC_COMMIT=5e699fc97d92684c6882741fc9f71cb57a33e25b
git clone https://codeberg.org/DylanVanAssche/libssc.git libssc
git -C libssc checkout "$SSC_COMMIT"
# Apply the vendored series in order: 0001 makes the test suite and its Python
# mocking server optional, 20251205-PR103 is the pmOS threading fix.
for p in "$REPO"/userspace-patches/libssc/*.patch; do
  [ -f "$p" ] || continue
  echo "applying $p"
  patch -d libssc -p1 --batch --forward < "$p"
done
# -Dtests=false: the test suite needs a Python installation for the build
# machine (python3-embed), which a cross build cannot resolve.
PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig \
  meson setup libssc-build libssc --cross-file aarch64.ini \
    -Dprefix=/usr -Dlibdir=lib/aarch64-linux-gnu -Dtests=false
meson compile -C libssc-build
DESTDIR="$OUT/root" meson install -C libssc-build --no-rebuild
# The generated .pc has prefix=/usr, but the staged library lives under
# $OUT/root/usr.  Rewrite prefix so iio-sensor-proxy's dependency('libssc')
# resolves the headers/libs from the staging tree, not the host root.
SSC_PC="$OUT/root/usr/lib/aarch64-linux-gnu/pkgconfig/libssc.pc"
[ -f "$SSC_PC" ] || { echo "libssc.pc not found at $SSC_PC" >&2; exit 1; }
sed -i "s|^prefix=.*|prefix=$OUT/root/usr|" "$SSC_PC"
cp -a "$OUT/root"/usr/lib/aarch64-linux-gnu/libssc* "$OUT/lib/" 2>/dev/null || true
cp -a "$OUT/root"/usr/include/libssc* "$OUT/include/" 2>/dev/null || true
cp "$SSC_PC" "$OUT/lib/"

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

PKG_CONFIG_LIBDIR="$OUT/root/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig" \
  meson setup isp-build iio-sp --cross-file aarch64.ini \
    -Dprefix=/usr -Dssc-support=true
meson compile -C isp-build
install -m 0755 isp-build/iio-sensor-proxy "$OUT/bin/" 2>/dev/null || \
  cp isp-build/iio-sensor-proxy "$OUT/bin/"
cp iio-sp/data/80-iio-sensor-proxy*.rules "$OUT/units/" 2>/dev/null || true

( cd "$OUT" && tar czf userspace-tools.tar.gz sbin lib bin units include )
sha256sum "$OUT/userspace-tools.tar.gz"
