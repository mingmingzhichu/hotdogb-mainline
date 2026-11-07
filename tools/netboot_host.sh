#!/bin/sh
# Host side of the hotdogb netboot, for a Linux machine.
#
#   sudo IFACE=usb0 tools/netboot_host.sh netboot-debian.img
#
# The USB gadget exposes CDC-NCM by default (or RNDIS with
# hotdogb.netboot.net=rndis on the kernel command line).  Both are handled
# by the in-kernel Linux drivers.  The script gives the interface the host
# address of the pmOS USB network and then serves the root image over NBD.
set -eu

IMG=${1:?path to the rootfs image}
HOSTIP=${HOSTIP:-172.16.42.2}
PORT=${PORT:-9999}
HERE=$(cd "$(dirname "$0")" && pwd)

IFACE=${IFACE:-}
if [ -z "$IFACE" ]; then
	for n in /sys/class/net/*; do
		name=${n##*/}
		drv=$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)" 2>/dev/null || true)
		case "$drv" in
		cdc_ncm|rndis_host|cdc_ether)
			IFACE=$name
			break
			;;
		esac
	done
fi

[ -n "$IFACE" ] || {
	echo "no USB network interface found; pass IFACE=<name>" >&2
	exit 1
}

echo "using $IFACE ($(basename "$(readlink -f "/sys/class/net/$IFACE/device/driver")"))"
ip link set "$IFACE" up
ip addr replace "$HOSTIP/24" dev "$IFACE"

exec python3 "$HERE/nbd_server.py" --image "$IMG" --bind "$HOSTIP" --port "$PORT"
