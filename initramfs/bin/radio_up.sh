#!/bin/busybox.static sh
# Bring up MPSS and then the WCN3990 wireless stack.
#
# Run from the console once /lib/firmware/qcom/sm8150/oneplus7/modem.mbn is in
# place.  Nothing here touches a partition.
say() { echo "<6>radio: $*" > /dev/kmsg 2>/dev/null; }

FW=/lib/firmware/qcom/sm8150/oneplus7
MPSS=/sys/class/remoteproc/remoteproc0

if [ ! -f "$FW/modem.mbn" ]; then
	echo "modem.mbn missing in $FW"
	exit 1
fi

say "starting MPSS"
echo start > "$MPSS/state"

n=0
while [ $n -lt 45 ]; do
	[ "$(cat "$MPSS/state")" = running ] && break
	sleep 1
	n=$((n + 1))
done
say "MPSS $(cat "$MPSS/state") after ${n}s"

# ath10k waits for the WLFW QMI service MPSS publishes, so the stack is loaded
# only once the modem is actually running.
for m in cfg80211 mac80211 ath ath10k_core; do
	[ -f "/lib/modules/$m.ko" ] || continue
	echo "insmod $m"
	insmod "/lib/modules/$m.ko"
done
[ -d /sys/module/ath10k_core ] && \
	echo 3145760 > /sys/module/ath10k_core/parameters/debug_mask

[ -f /lib/modules/ath10k_snoc.ko ] && {
	echo "insmod ath10k_snoc"
	insmod /lib/modules/ath10k_snoc.ko
}

sleep 5
echo "net: $(ls /sys/class/net)"
echo "mpss: $(cat "$MPSS/state")"
