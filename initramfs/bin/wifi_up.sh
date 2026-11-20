#!/bin/busybox.static sh
# Bring the WCN3990 up from a fresh boot:
#
#   /bin/wifi_up.sh
#
# Stages the kernel modules and ath10k files from the USB LUN into RAM, then
# starts MPSS and loads the modules. The split image and handset-specific
# wlanmdsp.mbn come from modem_a.
FWQ=/lib/firmware/qcom/sm8150/oneplus7
BOARD=/lib/firmware/ath10k/WCN3990/hw1.0

mkdir -p /mnt/lun /lib/modules "$FWQ" "$BOARD"

if ! grep -q ' /mnt/lun ' /proc/mounts; then
	mount -t vfat -o ro,loop /tmp/lun.img /mnt/lun || {
		echo "cannot mount /tmp/lun.img"
		exit 1
	}
fi

cp -f /mnt/lun/*.ko /lib/modules/ 2>/dev/null
cp -f /mnt/lun/board-2.bin /mnt/lun/firmware-5.bin "$BOARD/" 2>/dev/null
[ -f /mnt/lun/wifiscan ] && cp -f /mnt/lun/wifiscan /bin/wifiscan
[ -f /mnt/lun/qrtr-lookup ] && cp -f /mnt/lun/qrtr-lookup /bin/qrtr-lookup
umount /mnt/lun
chmod +x /bin/wifiscan /bin/qrtr-lookup 2>/dev/null

echo "staged:"
ls /lib/modules
ls "$FWQ" "$BOARD"

# The split MPSS image and wlanmdsp.mbn are extracted from the handset's own
# modem partition by /init.
if [ ! -f "$FWQ/modem.mdt" ]; then
	echo "no modem.mdt, stopping before MPSS"
	exit 1
fi

if [ "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" = offline ]; then
	echo start > /sys/class/remoteproc/remoteproc0/state
fi

n=0
while [ $n -lt 15 ]; do
	/bin/qrtr-lookup 2>/dev/null | grep -q ATH && break
	sleep 2
	n=$((n + 1))
done
echo "mpss: $(cat /sys/class/remoteproc/remoteproc0/state) after $((n * 2))s"
/bin/qrtr-lookup 2>/dev/null | grep ATH

for m in cfg80211 mac80211 ath ath10k_core ath10k_snoc; do
	insmod "/lib/modules/$m.ko" || echo "insmod $m failed: $?"
done

# ath10k registers the netdev a few seconds after probe returns; on a slow boot
# it can take noticeably longer than the module load itself.
n=0
while [ $n -lt 40 ]; do
	[ -d /sys/class/net/wlan0 ] && break
	sleep 1
	n=$((n + 1))
done
echo "net: $(ls /sys/class/net) after ${n}s"

# ath10k gets no MAC address here: device_get_mac_address() finds no
# local-mac-address in the DT and the firmware/QMI does not hand one out, so
# ath10k_mac_register() logs "invalid MAC address; choosing random" and installs
# a random one.  The real address is in persist's wlan_mac.bin, which /init
# copies to /var/lib/tqftpserv so tqftpserv can serve it to MPSS.
MACFILE=/var/lib/tqftpserv/wlan_mac.bin
if [ -d /sys/class/net/wlan0 ] && [ -f "$MACFILE" ]; then
	HEX=$(sed -n 's/^Intf0MacAddress=//p' "$MACFILE" | tr -d '\r' | tr 'A-F' 'a-f')
	if [ ${#HEX} -eq 12 ]; then
		MAC=$(echo "$HEX" | cut -c1-2):$(echo "$HEX" | cut -c3-4):$(echo "$HEX" \
			| cut -c5-6):$(echo "$HEX" | cut -c7-8):$(echo "$HEX" \
			| cut -c9-10):$(echo "$HEX" | cut -c11-12)
		ip link set wlan0 down
		ip link set wlan0 address "$MAC" || echo "set mac $MAC failed"
		ip link set wlan0 up
		echo "mac: $(cat /sys/class/net/wlan0/address)"
	fi
fi
