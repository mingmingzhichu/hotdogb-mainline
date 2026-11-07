#!/bin/sh
# Set the ALSA routes for the OnePlus 7T (hotdogb).
#
#   hotdogb-audio headphones|earpiece|speaker
#
# The codecs have to be loaded already (wcd934x, tfa9874 and the q6 stack);
# see docs/userspace.md.
set -eu

CARD=${CARD:-0}

sset() {
	amixer -q -c "$CARD" sset "$1" "$2" >/dev/null
	printf '%s <- %s\n' "$1" "$2"
}

case "${1:-}" in
headphones)
	sset "SLIMBUS_6_RX Audio Mixer MultiMedia1" on
	sset "SLIM RX2 MUX" "AIF4_PB"
	sset "SLIM RX3 MUX" "AIF4_PB"
	sset "RX INT1_1 MIX1 INP0" "RX2"
	sset "RX INT2_1 MIX1 INP0" "RX3"
	sset "RX INT1_1 INTERP" "RX INT1_1 MIX1"
	sset "RX INT2_1 INTERP" "RX INT2_1 MIX1"
	sset "RX INT1 DEM MUX" "CLSH_DSM_OUT"
	sset "RX INT2 DEM MUX" "CLSH_DSM_OUT"
	sset "HPHL Switch" on
	sset "HPHR Switch" on
	sset "HPHL Volume" 20
	sset "HPHR Volume" 20
	;;
earpiece)
	sset "SLIMBUS_6_RX Audio Mixer MultiMedia1" on
	sset "SLIM RX1 MUX" "AIF4_PB"
	sset "RX INT0_1 MIX1 INP0" "RX1"
	sset "RX INT0_1 INTERP" "RX INT0_1 MIX1"
	sset "RX INT0 DEM MUX" "CLSH_DSM_OUT"
	sset "EAR PA Volume" 4
	;;
speaker)
	sset "QUAT_MI2S_RX Audio Mixer MultiMedia1" on
	;;
*)
	echo "usage: $0 headphones|earpiece|speaker" >&2
	exit 1
	;;
esac
