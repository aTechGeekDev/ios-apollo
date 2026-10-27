#!/usr/bin/env bash
# Pull the QCA6390 Wi-Fi firmware from the phone into research/apollo-wifi/.
#
#   tools/pull-wifi-fw.sh            (phone in recovery: fastboot boot recovery/recovery.img)
#
# The files are Qualcomm's, already on the phone (Android's vendor partition or the modem
# partition); they are not in git (research/ is gitignored). Where exactly they are and what
# Xiaomi named the board file differs between ROMs, so this looks for them: the firmware image
# (amss20.bin or amss.bin), m3.bin, the board data (bdwlan* / bd_*), regdb.bin. It prints every
# candidate it finds, pulls them, and writes research/apollo-wifi/found.txt.
#
# mkadt.py --wifi-fw research/apollo-wifi/amss20.bin (or amss.bin) carries the firmware image
# for sweet_wifi.c (sweetwifi=4 and up). The other files are for the next stages.
#
# Needs adb, with the phone booted into recovery (OrangeFox) so /vendor is readable.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
out=$here/research/apollo-wifi

command -v adb >/dev/null 2>&1 || { echo "pull-wifi-fw.sh: adb is not installed" >&2; exit 1; }
state=$(adb get-state 2>/dev/null | tr -d '\r' || true)
[ "$state" = recovery ] || { echo "pull-wifi-fw.sh: the phone is not in recovery (adb get-state: ${state:-none}); fastboot boot recovery/recovery.img, wait, run again" >&2; exit 1; }

# /vendor (and the modem partition) may need mounting in recovery.
adb shell 'mount /vendor 2>/dev/null; mount -o ro /vendor 2>/dev/null; mount /firmware 2>/dev/null; mount -o ro /firmware 2>/dev/null; mount /vendor/firmware_mnt 2>/dev/null; mount -o ro /vendor/firmware_mnt 2>/dev/null' >/dev/null 2>&1 || true

# The radio's firmware is in the modem partition (FAT; Android mounts it at /vendor/firmware_mnt), which a
# recovery often leaves unmounted: then it is mounted here, read-only, with lower-case names as Android has them.
adb shell 'if [ ! -d /vendor/firmware_mnt/image ]; then
	for p in /dev/block/bootdevice/by-name/modem /dev/block/by-name/modem; do
		[ -e "$p" ] || continue
		mkdir -p /mnt/sweet-modem
		mount -t vfat -o ro,shortname=lower "$p" /mnt/sweet-modem 2>/dev/null && break
	done
fi' >/dev/null 2>&1 || true
trap "adb shell 'umount /mnt/sweet-modem 2>/dev/null' >/dev/null 2>&1 || true" EXIT

rm -rf "$out"		# (only this script's pulls are there: a second run starts afresh)
mkdir -p "$out"
# One path a line; directories that do not exist are skipped quietly.
adb shell 'for d in /vendor/firmware /vendor/firmware_mnt /mnt/sweet-modem /firmware /vendor/etc/wifi /odm/firmware /system/vendor/firmware; do
	[ -d "$d" ] && find "$d" -type f \( -iname "amss*.bin" -o -iname "m3*.bin" -o -iname "bdwlan*" -o -iname "bd_*" \
		-o -iname "regdb*.bin" -o -ipath "*qca6390*" -o -iname "WCNSS_qcom_cfg.ini" \) 2>/dev/null
done' | tr -d '\r' | sort -u > "$out/found.txt"

if [ ! -s "$out/found.txt" ]; then
	echo "pull-wifi-fw.sh: no QCA6390 firmware found under /vendor/firmware, /vendor/firmware_mnt (or the modem partition), /firmware." >&2
	echo "  Look by hand:  adb shell 'find / -xdev -iname \"amss*\" 2>/dev/null'" >&2
	exit 1
fi

echo "found on the phone:"
sed 's/^/  /' "$out/found.txt"
while IFS= read -r path; do
	[ -n "$path" ] || continue
	name=$(basename "$path" | tr 'A-Z' 'a-z')	# (a FAT partition mounted without shortname=lower says AMSS20.BIN)
	# the same name in two places (e.g. qca6390/ and the top): keep both, the second with its folder
	dest=$out/$name
	[ -e "$dest" ] && dest=$out/$(basename "$(dirname "$path")")-$name
	if adb pull "$path" "$dest" >/dev/null 2>&1 && [ -s "$dest" ]; then
		printf 'pulled %-28s %9s bytes  sha256 %s\n' "${dest#"$out"/}" "$(stat -c %s "$dest")" "$(sha256sum "$dest" | cut -c1-16)"
	else
		printf 'could not pull %s\n' "$path"
		rm -f "$dest"
	fi
done < "$out/found.txt"

amss=$(ls "$out"/amss20.bin "$out"/amss.bin 2>/dev/null | head -1 || true)
if [ -z "$amss" ]; then
	echo "pull-wifi-fw.sh: no amss20.bin / amss.bin among them: send found.txt" >&2
	exit 1
fi
echo "pull-wifi-fw.sh: firmware image for the boot image: ${amss#"$here"/}  (mkadt.py --wifi-fw ${amss#"$here"/})"
echo "(reboot the phone afterwards: adb reboot bootloader)"
