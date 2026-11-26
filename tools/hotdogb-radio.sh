#!/bin/sh
# Bring up the modem (MPSS) and WCN3990 Wi-Fi on the Debian rootfs.
#
# This is the netboot/Debian counterpart of initramfs/bin/radio_up.sh.  The
# initramfs radio section is skipped when hotdogb.netboot=1, so on a netbooted
# Debian system nothing starts the radio unless this script is run.
#
# Order matters: MPSS asserts (and the SoC drops into EDL) when it starts
# without rmtfs (EFS), pd-mapper (protection domains) and tqftpserv (firmware
# download).  See docs/userspace.md.  Do NOT use qcom,msa-fixed-perm.
#
# Usage: hotdogb-radio.sh [start|slpi|stop|status]
#   start  - bring up the service chain, then MPSS and the ath10k stack
#   slpi   - start only SLPI + pd-mapper (what the SSC sensor stack needs)
#   stop   - stop MPSS and the services
#   status - print the state of each piece
set -u

FW=/lib/firmware/qcom/sm8150/oneplus7
MPSS_PATH=/sys/class/remoteproc/remoteproc_mpss
SLPI_PATH=/sys/class/remoteproc/remoteproc_slpi
# CI installs modules into /lib/modules/$(uname -r) and runs depmod there.
MODDIR=/lib/modules/$(uname -r)
LOG=/dev/kmsg

say() { echo "<6>hotdogb-radio: $*" > "$LOG" 2>/dev/null; echo "hotdogb-radio: $*"; }

find_rproc() {
	# On this kernel the sysfs `name` is "modem"/"slpi"/"adsp" (the DT node
	# is called remoteproc_mpss but pas_probe sets the name to "modem").
	# Accept both names so the script is robust either way.
	for p in /sys/class/remoteproc/remoteproc*; do
		[ -r "$p/name" ] || continue
		n=$(cat "$p/name" 2>/dev/null)
		want=$1
		match=0
		if [ "$want" = mpss ]; then
			if [ "$n" = mpss ] || [ "$n" = modem ]; then match=1; fi
		elif [ "$n" = "$want" ]; then
			match=1
		fi
		if [ "$match" = 1 ]; then echo "$p"; return 0; fi
	done
	return 1
}

rproc_state() { cat "$1/state" 2>/dev/null || echo unknown; }
rproc_start() {
	p=$1
	[ "$(rproc_state "$p")" = running ] && return 0
	echo start > "$p/state" 2>/dev/null || return 1
	n=0
	while [ $n -lt 45 ]; do
		[ "$(rproc_state "$p")" = running ] && return 0
		sleep 1
		n=$((n + 1))
	done
	return 1
}

# SSC only: the sensor PD lives on the SLPI, so the sensor stack needs SLPI and
# pd-mapper -- but not MPSS and definitely not ath10k_snoc.  Probing ath10k
# before MPSS has published the WLFW service takes the WCN3990 down (SMMU
# context fault, remoteproc recovery fails, SoC drops into EDL), and a sensor
# test has no reason to reset the modem.  See
# docs/evidence/2026-11-02-wifi-wcn3990.md.
do_start_slpi() {
	mkdir -p /run/hotdogb
	SLPI=$(find_rproc slpi) || { say "slpi remoteproc not found"; return 1; }
	[ -f "$FW/slpi.mdt" ] || { say "slpi.mdt missing in $FW"; return 1; }
	if ! rproc_start "$SLPI"; then
		say "slpi failed to start"
		return 1
	fi
	say "slpi running"
	if ! pgrep -x pd-mapper >/dev/null; then
		if ls "$FW"/*.jsn >/dev/null 2>&1; then
			/usr/local/sbin/pd-mapper >/run/hotdogb/pd-mapper.log 2>&1 &
			say "pd-mapper started"
		else
			say "no *.jsn in $FW; pd-mapper would exit"
		fi
	fi
}

do_start() {
	mkdir -p /run/hotdogb
	[ -f "$FW/modem.mdt" ] || { say "modem.mdt missing in $FW"; return 1; }
	MPSS=$(find_rproc mpss) || { say "mpss remoteproc not found"; return 1; }
	SLPI=$(find_rproc slpi) || { say "slpi remoteproc not found; refusing to start MPSS"; return 1; }
	# SLPI is a hard prerequisite for MPSS on this SoC: starting MPSS while
	# SLPI is offline (so pd-mapper has no protection domains) resets the
	# whole chip into EDL.  Verified on device 2026-11-20.
	[ -f "$FW/slpi.mdt" ] || { say "slpi.mdt missing in $FW; refusing to start MPSS"; return 1; }

	# 1. rmtfs (EFS).  The rootfs bakes the EFS partitions into
	#    /var/lib/hotdogb/rmtfs, so use rmtfs' directory mode (-o) and never
	#    rely on /dev/disk/by-partlabel (the netboot kernel's udev does not
	#    create those links reliably).  Only when that baked data is absent
	#    fall back to running the Debian service (-P finds partitions by GPT
	#    label) or copying the partitions at runtime.
	EFS_DIR=/var/lib/hotdogb/rmtfs
	if ! pgrep -x rmtfs >/dev/null; then
		if [ -f "$EFS_DIR/modem_fs1" ]; then
			# -o: baked EFS directory, -r: read-only.  No -s: that flag
			# opens the mss rproc control fd and aborts if it is missing;
			# it only syncs modem start/stop and is not needed for EFS.
			if [ -x /usr/bin/rmtfs ]; then
				/usr/bin/rmtfs -o "$EFS_DIR" -r \
					>/run/hotdogb/rmtfs.log 2>&1 &
			elif [ -x /usr/local/sbin/rmtfs ]; then
				/usr/local/sbin/rmtfs -o "$EFS_DIR" -r \
					>/run/hotdogb/rmtfs.log 2>&1 &
			else
				say "rmtfs binary missing - MPSS may assert"
				return 1
			fi
			say "rmtfs started from baked EFS ($EFS_DIR)"
		elif command -v systemctl >/dev/null && \
		     systemctl start rmtfs >/dev/null 2>&1 && pgrep -x rmtfs >/dev/null; then
			say "rmtfs started via systemd (-P)"
		else
			mkdir -p /run/hotdogb/rmtfs
			for d in /sys/block/sd*/sd*; do
				[ -r "$d/uevent" ] || continue
				case "$(sed -n 's/^PARTNAME=//p' "$d/uevent")" in
				modemst1) out=modem_fs1 ;;
				modemst2) out=modem_fs2 ;;
				fsg) out=modem_fsg ;;
				fsc) out=modem_fsc ;;
				*) continue ;;
				esac
				[ -b "/dev/${d##*/}" ] && \
					dd if="/dev/${d##*/}" of="/run/hotdogb/rmtfs/$out" bs=1M 2>/dev/null
			done
			if [ -x /usr/local/sbin/rmtfs ] || [ -x /usr/bin/rmtfs ]; then
				RMTFS_BIN=/usr/local/sbin/rmtfs
				[ -x "$RMTFS_BIN" ] || RMTFS_BIN=/usr/bin/rmtfs
				"$RMTFS_BIN" -o /run/hotdogb/rmtfs -r \
					>/run/hotdogb/rmtfs.log 2>&1 &
				say "rmtfs started from runtime-copied EFS"
			else
				say "rmtfs service unavailable - MPSS may assert"
				return 1
			fi
		fi
	fi

	# 2. tqftpserv (firmware download).  /var/lib/tqftpserv is baked into the
	#    rootfs with this handset's wlan_mac.bin + calibration (persist dump),
	#    which is what makes MPSS publish the WLFW QMI service ath10k waits on.
	#    tqftpserv's mkdir() is not recursive, so the parent must exist.
	mkdir -p /var/lib/tqftpserv
	if [ ! -f /var/lib/tqftpserv/wlan_mac.bin ]; then
		say "warning: /var/lib/tqftpserv has no wlan_mac.bin; WLFW may not appear"
	fi
	if ! pgrep -x tqftpserv >/dev/null; then
		if command -v systemctl >/dev/null && \
		   systemctl start tqftpserv >/dev/null 2>&1 && pgrep -x tqftpserv >/dev/null; then
			say "tqftpserv started via systemd"
		else
			if [ -x /usr/local/sbin/tqftpserv ]; then
				/usr/local/sbin/tqftpserv >/run/hotdogb/tqftpserv.log 2>&1 &
				say "tqftpserv started via static binary"
			else
				say "tqftpserv service unavailable - MPSS may assert"
				return 1
			fi
		fi
	fi

	# 3. SLPI must come up before pd-mapper can enumerate its PDs, and before
	#    MPSS is touched.  A failure here aborts the whole sequence.
	if ! rproc_start "$SLPI"; then
		say "slpi failed to start - aborting, NOT starting MPSS"
		return 1
	fi
	say "slpi running"

	# 4. PD maps: pd-mapper needs the *.jsn files in the firmware dir.
	if ! pgrep -x pd-mapper >/dev/null; then
		if ls "$FW"/*.jsn >/dev/null 2>&1; then
			/usr/local/sbin/pd-mapper >/run/hotdogb/pd-mapper.log 2>&1 &
			say "pd-mapper started"
		else
			say "no *.jsn in $FW; pd-mapper would exit"
		fi
	fi

	sleep 2

	# 5. Only now start MPSS.  Starting it before the services above is what
	#    makes it assert and reset the whole SoC into EDL.
	rproc_start "$MPSS" || { say "MPSS failed to start"; return 1; }
	say "MPSS running"

	# 6. Wi-Fi modules (ath10k waits for the WLFW QMI service MPSS publishes).
	#    CI runs depmod, so modprobe resolves dependencies; fall back to a
	#    fixed-order insmod if modprobe is unavailable.
	if command -v modprobe >/dev/null 2>&1; then
		modprobe ath10k_snoc 2>/dev/null || say "modprobe ath10k_snoc failed"
	else
		for m in cfg80211 mac80211 ath ath10k_core; do
			[ -f "$MODDIR/$m.ko" ] && insmod "$MODDIR/$m.ko" 2>/dev/null
		done
		[ -f "$MODDIR/ath10k_snoc.ko" ] && insmod "$MODDIR/ath10k_snoc.ko" 2>/dev/null
	fi
	[ -d /sys/module/ath10k_core ] && \
		echo 3145760 > /sys/module/ath10k_core/parameters/debug_mask 2>/dev/null

	sleep 5
	say "done: $(ls /sys/class/net 2>/dev/null | tr '\n' ' ')"
}

do_stop() {
	for p in /sys/class/remoteproc/remoteproc*; do
		[ -r "$p/state" ] || continue
		[ "$(rproc_state "$p")" = running ] && \
			echo stop > "$p/state" 2>/dev/null
	done
	pkill -x pd-mapper 2>/dev/null
	pkill -x tqftpserv 2>/dev/null
	pkill -x rmtfs 2>/dev/null
	say "stopped"
}

do_status() {
	for p in /sys/class/remoteproc/remoteproc*; do
		[ -r "$p/name" ] || continue
		echo "$(cat "$p/name"): $(rproc_state "$p")"
	done
	for b in rmtfs pd-mapper tqftpserv; do
		printf '%s: ' "$b"; pgrep -x "$b" >/dev/null && echo running || echo stopped
	done
}

case "${1:-start}" in
start) do_start ;;
slpi) do_start_slpi ;;
stop) do_stop ;;
status) do_status ;;
*) echo "usage: $0 [start|slpi|stop|status]"; exit 2 ;;
esac
