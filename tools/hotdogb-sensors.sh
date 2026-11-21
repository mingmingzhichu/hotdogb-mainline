#!/bin/sh
# Bring up the SSC (Snapdragon Sensor Core) sensor stack for hotdogb.
#
# The sensors live behind the SLPI.  Its sensor PD reads the sensor registry and
# the board configuration through a FastRPC reverse tunnel: it asks the
# application processor for files such as
#
#   /persist/sensors/registry/registry/*      sensor registry + calibration
#   /vendor/etc/sensors/config/*.json         board sensor configuration
#   /vendor/etc/sensors/sns_reg_config        registry load list
#   /sys/devices/soc0/*                       platform identification
#
# and hexagonrpcd answers those requests from a directory tree (HexagonFS).
# Without that server the registry stays empty, libssc's SUID lookup returns
# zero sensors, and iio-sensor-proxy gives up with
#   'registry' sensor unavailable, retrying... (10/10)
#
# Only the registry is shipped here, not the vendor JSONs: it is per-device
# calibration data that already exists on the phone's persist partition, so it
# is copied into a tmpfs tree at start instead of ending up in the image.
#
# Ordering matters twice:
#   - hexagonrpcd can only attach once SLPI is running (/dev/fastrpc-sdsp), and
#     it must attach *before* anything talks to the sensor PD, because the
#     attach is what starts the PD and makes it read the registry;
#   - iio-sensor-proxy therefore has to be (re)started after the attach, since
#     its unit runs long before this one.
#
# This needs patches/0014 in the kernel: the sm8150 fastrpc node has to look
# like the sdm845 one, i.e. a reserved 16 MiB pool, a qcom,vmids list and a
# single compute context bank without iommus.  With the translated context
# banks the DSP faults on its first access and remoteproc has to recover it:
#   arm-smmu: Unhandled context fault: iova=0x1fffff000, cbfrsynra=0x5a1
#   qcom_q6v5_pas: fatal error received: EX:sensor_process:0x1:frpck_0_0
# The sensor process is hypervisor-bypassed on the SMMU and works with physical
# addresses, so the registry files also have to be readable by hexagonrpcd.

set -eu

HEXAGONFS=${HEXAGONFS:-/run/hotdogb-hexagonfs}
PERSIST_MNT=${PERSIST_MNT:-/run/hotdogb-persist}
PARTLABEL=${PARTLABEL:-persist}
FASTRPC=${FASTRPC:-/dev/fastrpc-sdsp}
DSP=${DSP:-adsp}
RPC_PIDFILE=${RPC_PIDFILE:-/run/hexagonrpcd.pid}

say() { echo "hotdogb-sensors: $*" >&2; }

mount_persist() {
	mkdir -p "$PERSIST_MNT"
	mountpoint -q "$PERSIST_MNT" && return 0
	dev=$(readlink -f "/dev/disk/by-partlabel/$PARTLABEL" 2>/dev/null || true)
	if [ -z "$dev" ] || [ ! -e "$dev" ]; then
		# udev does not always create by-partlabel links for UFS partitions.
		dev=$(blkid -l -t "PARTLABEL=$PARTLABEL" -o device 2>/dev/null || true)
	fi
	if [ -z "$dev" ] || [ ! -e "$dev" ]; then
		say "partition '$PARTLABEL' not found"
		return 1
	fi
	mount -o ro "$dev" "$PERSIST_MNT"
}

populate_hexagonfs() {
	mkdir -p "$HEXAGONFS/sensors/registry" "$HEXAGONFS/sensors/config" \
		"$HEXAGONFS/acdb" "$HEXAGONFS/dsp"
	src="$PERSIST_MNT/sensors/registry/registry"
	if [ -d "$src" ] && [ -z "$(ls -A "$HEXAGONFS/sensors/registry" 2>/dev/null)" ]; then
		cp -a "$src"/. "$HEXAGONFS/sensors/registry/"
	fi
	if [ ! -e "$HEXAGONFS/socinfo" ] && [ -d /sys/devices/soc0 ]; then
		ln -s /sys/devices/soc0 "$HEXAGONFS/socinfo"
	fi
	# The registry is copied from persist, where it is root-only; the DSP asks
	# hexagonrpcd for those calibration files and gets EACCES if they are not
	# readable by the user the daemon runs as.
	chmod -R a+rX "$HEXAGONFS" 2>/dev/null || true
	say "registry: $(ls "$HEXAGONFS/sensors/registry" 2>/dev/null | wc -l) files"
}

wait_for_fastrpc() {
	i=0
	while [ ! -e "$FASTRPC" ]; do
		i=$((i + 1))
		if [ "$i" -gt 40 ]; then
			say "$FASTRPC never appeared (is SLPI running?)"
			return 1
		fi
		sleep 1
	done
}

start_rpcd() {
	if [ -f "$RPC_PIDFILE" ] && kill -0 "$(cat "$RPC_PIDFILE")" 2>/dev/null; then
		say "hexagonrpcd already running"
		return 0
	fi
	setsid /usr/local/sbin/hexagonrpcd -f "$FASTRPC" -d "$DSP" -s \
		-R "$HEXAGONFS" >/var/log/hexagonrpcd.log 2>&1 </dev/null &
	echo $! > "$RPC_PIDFILE"
	sleep 2
	if ! kill -0 "$(cat "$RPC_PIDFILE")" 2>/dev/null; then
		say "hexagonrpcd died: $(tail -3 /var/log/hexagonrpcd.log 2>/dev/null | tr '\n' ' ')"
		return 1
	fi
	say "hexagonrpcd attached to $FASTRPC"
}

do_start() {
	mount_persist || say "continuing without the persist registry"
	populate_hexagonfs
	wait_for_fastrpc
	start_rpcd
	# iio-sensor-proxy starts at boot, before SLPI and this daemon exist, and
	# exits when it finds no sensors; restart it now that the PD is attached.
	systemctl try-restart iio-sensor-proxy 2>/dev/null || \
		systemctl start iio-sensor-proxy 2>/dev/null || true
	say "started"
}

do_stop() {
	if [ -f "$RPC_PIDFILE" ]; then
		pkill -x hexagonrpcd 2>/dev/null || true
		rm -f "$RPC_PIDFILE"
	fi
	mountpoint -q "$PERSIST_MNT" && umount "$PERSIST_MNT" 2>/dev/null || true
	say "stopped"
}

do_status() {
	echo "fastrpc: $(ls "$FASTRPC" 2>/dev/null || echo missing)"
	printf 'hexagonrpcd: '
	pgrep -x hexagonrpcd >/dev/null && echo running || echo stopped
	echo "registry: $(ls "$HEXAGONFS/sensors/registry" 2>/dev/null | wc -l) files"
	printf 'iio-sensor-proxy: '
	systemctl is-active iio-sensor-proxy 2>/dev/null || true
	gdbus call --system -d net.hadess.SensorProxy \
		-o /net/hadess/SensorProxy \
		-m org.freedesktop.DBus.Properties.GetAll net.hadess.SensorProxy \
		2>/dev/null | head -c 300 || true
	echo
}

case "${1:-start}" in
start) do_start ;;
stop) do_stop ;;
status) do_status ;;
*) echo "usage: $0 [start|stop|status]" >&2; exit 2 ;;
esac
