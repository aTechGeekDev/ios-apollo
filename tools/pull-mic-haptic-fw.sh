#!/bin/bash
# The vibration motor's waveforms and the microphone's calibration for apollo's iOS root (xnu 0146:
# sweet_haptic.c, sweet_mic.c), from the phone's Android vendor partition into research/.
#
#   fastboot boot recovery/recovery.img && adb wait-for-recovery && tools/pull-mic-haptic-fw.sh
#   python3 tools/mkadt.py ... --files-from research/apollo-audio/files-mic-haptic.txt      (one boot)
#
# - /vendor/firmware/aw8697_haptic.bin: Android's waveforms for the AW8697 motor driver (needed for
#   apollo_haptic=3 and up) -> research/apollo-haptic/
# - /vendor/etc/acdbdata/Tutu/Tutu_{Handset,Global}_cal.acdb: Xiaomi's audio calibration; out of it
#   tools/acdb-mic.py (hakios-apollo's) writes the microphone's device-path topology and calibration
#   (mic_topology_v2/v1/legacy.bin, mic_audproc.bin) -> research/apollo-mic/. Without them the
#   microphone keeps to its plain path (apollo_mic_path=0): it works, without Xiaomi's processing.
#
# As tools/pull-gpu-fw.sh: the phone in recovery (OrangeFox) with /vendor readable; nothing on the phone is
# changed. The files are Xiaomi's/Qualcomm's and stay out of git (research/ is gitignored). The kernel reads
# them from /usr/local/fw/ on the iOS root; this writes the list that puts them there
# (research/apollo-audio/files-mic-haptic.txt) for ONE boot; they stay on the root afterwards.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
haptic=$here/research/apollo-haptic
mic=$here/research/apollo-mic
list=$here/research/apollo-audio/files-mic-haptic.txt

command -v adb >/dev/null 2>&1 || { echo "pull-mic-haptic-fw.sh: adb is not installed" >&2; exit 1; }
state=$(adb get-state 2>/dev/null | tr -d '\r' || true)
[ "$state" = recovery ] || { echo "pull-mic-haptic-fw.sh: the phone is not in recovery (adb get-state: ${state:-none}); fastboot boot recovery/recovery.img, wait, run again" >&2; exit 1; }

# /vendor may need mounting in recovery.
if [ "$(adb shell '[ -e /vendor/firmware/aw8697_haptic.bin ] && echo yes' 2>/dev/null | tr -d '\r')" != yes ]; then
	adb shell 'mount /vendor 2>/dev/null; mount -o ro /vendor 2>/dev/null' >/dev/null 2>&1 || true
fi

mkdir -p "$haptic" "$mic/acdb" "$(dirname "$list")"
rm -f "$haptic/aw8697_haptic.bin" "$mic"/mic_*.bin
if adb pull /vendor/firmware/aw8697_haptic.bin "$haptic/aw8697_haptic.bin" >/dev/null 2>&1 && [ -s "$haptic/aw8697_haptic.bin" ]; then
	printf 'aw8697_haptic.bin   %6s bytes\n' "$(stat -c %s "$haptic/aw8697_haptic.bin")"
else
	rm -f "$haptic/aw8697_haptic.bin"
	echo "pull-mic-haptic-fw.sh: no /vendor/firmware/aw8697_haptic.bin on the phone (is /vendor mounted? adb shell mount /vendor)" >&2
	exit 1
fi

acdb_ok=1
for f in Tutu_Handset_cal.acdb Tutu_Global_cal.acdb; do
	if ! adb pull "/vendor/etc/acdbdata/Tutu/$f" "$mic/acdb/$f" >/dev/null 2>&1 || [ ! -s "$mic/acdb/$f" ]; then
		echo "pull-mic-haptic-fw.sh: no /vendor/etc/acdbdata/Tutu/$f (what there is: adb shell ls -R /vendor/etc/acdbdata)" >&2
		acdb_ok=0
	fi
done
if [ "$acdb_ok" = 1 ] && python3 -I "$here/tools/acdb-mic.py" "$mic/acdb/Tutu_Handset_cal.acdb" \
	"$mic/acdb/Tutu_Global_cal.acdb" "$mic"; then
	:
else
	rm -f "$mic"/mic_*.bin
	echo "pull-mic-haptic-fw.sh: no calibration for the microphone: it keeps to its plain path (apollo_mic_path=0)" >&2
fi

{
	echo "# the vibration motor's waveforms and the microphone's calibration for /usr/local/fw/ (tools/pull-mic-haptic-fw.sh): for one boot"
	echo "/usr/local/fw/aw8697_haptic.bin=research/apollo-haptic/aw8697_haptic.bin 0:0:0644"
	for f in "$mic"/mic_*.bin; do
		[ -e "$f" ] || continue
		echo "/usr/local/fw/$(basename "$f")=research/apollo-mic/$(basename "$f") 0:0:0644"
	done
} > "$list"
echo "pull-mic-haptic-fw.sh: research/apollo-audio/files-mic-haptic.txt lists what goes to /usr/local/fw/ ($(grep -c "^/usr" "$list") files), for mkadt.py --files-from (one boot)"
