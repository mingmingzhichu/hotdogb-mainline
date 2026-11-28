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
# Usage: hotdogb-radio.sh [start|wifi|slpi|stop|status|diag]
#   start  - bring up rmtfs/tqftpserv/pd-mapper and MPSS (never probes ath10k)
#   wifi   - probe ath10k_snoc, but only once MPSS publishes the WLFW service
#   slpi   - start only SLPI + pd-mapper (what the SSC sensor stack needs)
#   stop   - stop MPSS and the services
#   status - print the state of each piece
#   diag   - dump everything needed to explain a failure (states, logs, QRTR)
#
# ath10k must NOT be probed from start: on a freshly booted MPSS the WCN3990
# is not ready, the probe takes an SMMU context fault and drops the SoC into
# EDL (verified 2026-11-27).  `wifi` waits for WLFW via qrtr-lookup first.
set -u

FW=/lib/firmware/qcom/sm8150/oneplus7
# EFS: baked copy in the rootfs, staged into tmpfs and served writable.
EFS_SRC=/var/lib/hotdogb/rmtfs
EFS_RUN=/run/hotdogb/rmtfs
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

# Stop whatever rmtfs is running, systemd unit included.
#
# The Debian unit is `rmtfs -r -P -s`: read-only on the real partitions, and it
# is enabled at boot.  Keeping it because "a rmtfs is already running" is how a
# read-only EFS store survives into the modem bring-up, which is exactly what we
# do not want (see the EFS comment in do_start).
stop_rmtfs() {
	command -v systemctl >/dev/null 2>&1 && \
		systemctl stop rmtfs >/dev/null 2>&1
	pkill -x rmtfs 2>/dev/null
	n=0
	while [ $n -lt 50 ] && pgrep -x rmtfs >/dev/null; do
		sleep 0.1
		n=$((n + 1))
	done
	! pgrep -x rmtfs >/dev/null
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
	# The verified MPSS image is the single-file modem.mbn (the split
	# modem.mdt + bXX crash-loops every ~40 s, verified 2026-11-27).
	if [ -f "$FW/modem.mbn" ]; then
		say "MPSS image: modem.mbn (verified)"
	elif [ -f "$FW/modem.mdt" ]; then
		say "warning: only split modem.mdt present - MPSS may crash-loop"
	else
		say "no modem firmware in $FW"
		return 1
	fi
	MPSS=$(find_rproc mpss) || { say "mpss remoteproc not found"; return 1; }

	# Restarting the EFS service under a live modem would pull the store out
	# from under it, so make the caller stop the radio first.
	if [ "$(rproc_state "$MPSS")" = running ]; then
		say "MPSS is already running; '$0 stop' first to change the EFS store"
		return 0
	fi

	# 1. rmtfs (EFS).  Two properties matter, and both were wrong before:
	#
	#    - The store has to be WRITABLE.  The modem syncs NV items into EFS
	#      while it brings itself up; rmtfs -r answers those writes with
	#      EROFS and the modem is left with a wlan_process that never
	#      finishes its init ("grace timer expired", then a fatal error
	#      every ~40 s).  Serving a read-only EFS is a debugging mode, not a
	#      way to boot a phone.
	#    - It must be OUR rmtfs.  The Debian unit runs `rmtfs -r -P -s` and
	#      is enabled at boot, so "pgrep found one" says nothing about
	#      whether it serves anything useful.
	#
	# So stage the baked EFS dump into tmpfs and serve that: writable, no
	# NBD traffic while the modem boots, and the UFS partitions stay
	# untouched.
	if [ -f "$EFS_SRC/modem_fs1" ]; then
		mkdir -p "$EFS_RUN" || { say "cannot create $EFS_RUN"; return 1; }
		for f in modem_fs1 modem_fs2 modem_fsg modem_fsc; do
			[ -f "$EFS_SRC/$f" ] || { say "missing $EFS_SRC/$f"; return 1; }
			cp -f "$EFS_SRC/$f" "$EFS_RUN/$f" || {
				say "cannot stage $f into $EFS_RUN"
				return 1
			}
		done
		RMTFS_BIN=/usr/bin/rmtfs
		[ -x "$RMTFS_BIN" ] || RMTFS_BIN=/usr/local/sbin/rmtfs
		[ -x "$RMTFS_BIN" ] || { say "rmtfs binary missing"; return 1; }

		stop_rmtfs || { say "a rmtfs is still running, cannot take over"; return 1; }
		# No -r (writable) and no -s (that flag needs the mss rproc fd).
		"$RMTFS_BIN" -o "$EFS_RUN" >/run/hotdogb/rmtfs.log 2>&1 &
		sleep 1
		if ! pgrep -x rmtfs >/dev/null; then
			say "rmtfs died: $(tail -n 3 /run/hotdogb/rmtfs.log 2>/dev/null | tr '\n' ' ')"
			return 1
		fi
		say "rmtfs serving a writable copy of the baked EFS ($EFS_RUN)"
	elif command -v systemctl >/dev/null 2>&1 && \
	     systemctl start rmtfs >/dev/null 2>&1 && pgrep -x rmtfs >/dev/null; then
		say "warning: no baked EFS, using the Debian unit (-P, read-only)"
	else
		mkdir -p "$EFS_RUN"
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
				dd if="/dev/${d##*/}" of="$EFS_RUN/$out" bs=1M 2>/dev/null
		done
		RMTFS_BIN=/usr/bin/rmtfs
		[ -x "$RMTFS_BIN" ] || RMTFS_BIN=/usr/local/sbin/rmtfs
		if [ ! -f "$EFS_RUN/modem_fs1" ] || [ ! -x "$RMTFS_BIN" ]; then
			say "no EFS source and no rmtfs - MPSS will assert"
			return 1
		fi
		stop_rmtfs
		"$RMTFS_BIN" -o "$EFS_RUN" >/run/hotdogb/rmtfs.log 2>&1 &
		sleep 1
		pgrep -x rmtfs >/dev/null || { say "rmtfs died"; return 1; }
		say "rmtfs started from runtime-copied EFS"
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

	# 3. PD maps: pd-mapper needs the *.jsn files in the firmware dir.  It
	#    must be up before MPSS so WLFW can be published; keep going even if
	#    SLPI is offline (MPSS itself does not depend on it - verified 2026-11-27).
	if ! pgrep -x pd-mapper >/dev/null; then
		if ls "$FW"/*.jsn >/dev/null 2>&1; then
			/usr/local/sbin/pd-mapper >/run/hotdogb/pd-mapper.log 2>&1 &
			say "pd-mapper started"
		else
			say "no *.jsn in $FW; pd-mapper would exit"
		fi
	fi

	sleep 2

	# 4. MPSS.  With all three services above up it boots and stays running.
	if [ "$(rproc_state "$MPSS")" = running ]; then
		say "MPSS already running"
	else
		rproc_start "$MPSS" || { say "MPSS failed to start"; return 1; }
		say "MPSS running"
	fi

	# Deliberately do NOT probe ath10k here.  MPSS has only just booted; the
	# WLFW service appears a few seconds later.  Probing before then makes
	# ath10k_snoc touch 18800000.wifi while the WLAN subsystem is unclaimed,
	# an SMMU context fault resets the SoC into EDL.  Use `wifi` instead.
	say "radio up; run '$0 wifi' to wait for WLFW and probe ath10k"
}

# Probe ath10k only once MPSS has published the WLFW QMI service.  The original
# AEE/ath10k bring-up script used `qrtr-lookup | grep ATH` with a 30 s timeout
# for exactly this reason.  Probing early resets the whole SoC into EDL.
do_wifi() {
	mkdir -p /run/hotdogb
	MPSS=$(find_rproc mpss) || { say "mpss remoteproc not found"; return 1; }
	if [ "$(rproc_state "$MPSS")" != running ]; then
		say "MPSS is not running - run '$0 start' first"
		return 1
	fi
	pgrep -x rmtfs >/dev/null || { say "rmtfs not running - run '$0 start' first"; return 1; }
	pgrep -x tqftpserv >/dev/null || { say "tqftpserv not running - run '$0 start' first"; return 1; }
	pgrep -x pd-mapper >/dev/null || say "warning: pd-mapper not running"

	QLOOK=$(command -v qrtr-lookup 2>/dev/null)
	[ -n "$QLOOK" ] || QLOOK=/usr/local/sbin/qrtr-lookup
	[ -x "$QLOOK" ] || QLOOK=

	# Wait for the WLFW service before touching 18800000.wifi.  Without
	# qrtr-lookup there is no way to tell, and a blind probe is exactly what
	# drops the SoC into EDL, so refuse unless the caller insists.
	if [ -n "$QLOOK" ]; then
		n=0
		while [ $n -lt 30 ]; do
			if "$QLOOK" 2>/dev/null | grep -qiE 'ATH10k|WLFW'; then
				say "WLFW service present after ${n}s"
				break
			fi
			n=$((n + 1))
			sleep 1
		done
		if [ $n -ge 30 ]; then
			say "WLFW did not appear in 30s - refusing to probe ath10k (would crash SoC)"
			do_diag
			return 1
		fi
	elif [ "${HOTDOGB_WIFI_BLIND:-0}" = 1 ]; then
		say "warning: no qrtr-lookup, probing blindly (HOTDOGB_WIFI_BLIND=1)"
		sleep 20
	else
		say "no qrtr-lookup: cannot verify WLFW, refusing to probe ath10k"
		do_diag
		return 1
	fi

	if lsmod 2>/dev/null | grep -q '^ath10k_snoc'; then
		say "ath10k_snoc already loaded"
		return 0
	fi
	# Load in the exact order of the verified initramfs path (wifi_up.sh):
	# cfg80211 -> mac80211 -> ath -> ath10k_core -> ath10k_snoc.  These are the
	# modules from the running kernel's own build ($MODDIR), which is the only
	# set whose vermagic matches; insmod by path rather than modprobe so a
	# module from elsewhere on the system cannot be picked up by accident.
	# The insmod failures are printed, not swallowed: "version magic ... should
	# be ..." here means the rootfs carries modules from another kernel build.
	# modules_install scatters these over three directories: cfg80211 under
	# kernel/net/wireless, mac80211 under kernel/net/mac80211, the ath ones
	# under kernel/drivers/net/wireless/ath.  Look them up by name instead of
	# assuming a layout - the flat ath/ directory this used to expect only
	# existed because a hand-copied module set was dropped there.
	find_module() {
		found=$(find "$MODDIR/kernel" -type f -name "$1.ko" 2>/dev/null | head -n 1)
		[ -n "$found" ] || return 1
		echo "$found"
	}
	for m in cfg80211 mac80211 ath ath10k_core ath10k_snoc; do
		path=$(find_module "$m") || { say "missing $m.ko under $MODDIR"; return 1; }
		err=$(insmod "$path" 2>&1) || say "insmod $m failed: $err"
	done
	[ -d /sys/module/ath10k_core ] && \
		echo 3145760 > /sys/module/ath10k_core/parameters/debug_mask 2>/dev/null

	# ath10k registers the netdev a few seconds after probe returns; a probe
	# that succeeds but never produces wlan0 is a different failure from a
	# probe that faults, and the two need different answers.
	n=0
	while [ $n -lt 40 ] && [ ! -d /sys/class/net/wlan0 ]; do
		sleep 1
		n=$((n + 1))
	done
	if [ -d /sys/class/net/wlan0 ]; then
		say "wlan0 up after ${n}s: $(cat /sys/class/net/wlan0/address 2>/dev/null)"
	else
		say "no wlan0 after 40s; dmesg has the ath10k story"
		do_diag
		return 1
	fi
}

# One-shot explanation of the radio chain: what is running, what the
# services log, and what QRTR can see.  "WLFW is missing" has half a dozen
# causes and this is what tells them apart.
do_diag() {
	say "=== remoteproc ==="
	for p in /sys/class/remoteproc/remoteproc*; do
		[ -r "$p/name" ] || continue
		printf '%s: %s  fw=%s\n' "$(cat "$p/name")" "$(rproc_state "$p")" \
			"$(cat "$p/firmware" 2>/dev/null)"
	done

	say "=== services ==="
	for b in rmtfs tqftpserv pd-mapper; do
		if pgrep -x "$b" >/dev/null; then
			printf '%s: %s\n' "$b" "$(ps -o args= -C "$b" 2>/dev/null | head -n 1)"
		else
			printf '%s: (not running)\n' "$b"
		fi
	done

	say "=== EFS store ($EFS_RUN) ==="
	ls -l "$EFS_RUN" 2>/dev/null

	say "=== firmware ==="
	ls -l "$FW/modem.mbn" "$FW/wlanmdsp.mbn" 2>/dev/null
	ls "$FW"/*.jsn 2>/dev/null | tr '\n' ' '
	echo

	say "=== QRTR services ==="
	QL=$(command -v qrtr-lookup 2>/dev/null)
	[ -n "$QL" ] || QL=/usr/local/sbin/qrtr-lookup
	if [ -x "$QL" ]; then
		"$QL" 2>&1 | head -n 30
	else
		echo "(qrtr-lookup missing)"
	fi

	say "=== service logs ==="
	for l in rmtfs tqftpserv pd-mapper; do
		echo "--- $l"
		tail -n 8 "/run/hotdogb/$l.log" 2>/dev/null
	done

	say "=== dmesg (modem/wlan) ==="
	dmesg 2>/dev/null | \
		grep -iE 'remoteproc|q6v5|mpss|wlan|ath10k|crash|subsys' | tail -n 30
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
	printf 'efs: '; ls "$EFS_RUN" 2>/dev/null | tr '\n' ' '; echo
}

case "${1:-start}" in
start) do_start ;;
wifi) do_wifi ;;
slpi) do_start_slpi ;;
stop) do_stop ;;
status) do_status ;;
diag) do_diag ;;
*) echo "usage: $0 [start|wifi|slpi|stop|status]"; exit 2 ;;
esac
