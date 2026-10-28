#!/bin/bash
# Pull the QCA6390 Wi-Fi firmware from the phone into research/apollo-wifi/.
#
# The files are Qualcomm's, on the phone's modem partition (a FAT image; Android mounts it at
# /vendor/firmware_mnt, files in image/qca6390/): amss20.bin (the radio's firmware), m3.bin,
# regdb.bin, and board files for several Xiaomi phones (apollo's: bd_j3sgl.elf). They are not in
# git (research/ is gitignored).
#
# Nothing on the phone is mounted or changed: the partition is read whole, as the kernel log is
# (tools/sweet-log-pull.sh: adb exec-out dd), to research/apollo-wifi/modem.img, and the files are
# taken out of that copy here with tools/fatcopy.py (as iOSPlus10's scripts/wifi/extract-fw.sh
# does for its phone). A copy already there is used again (FRESH=1: read the partition again).
#
#   fastboot boot recovery/recovery.img && adb wait-for-recovery && tools/pull-wifi-fw.sh
#   python3 tools/mkadt.py ... --wifi-fw research/apollo-wifi      (takes bd_j3sgl.elf by itself)
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
out=$here/research/apollo-wifi
img=$out/modem.img

command -v adb >/dev/null 2>&1 || { echo "pull-wifi-fw.sh: adb is not installed" >&2; exit 1; }
mkdir -p "$out"

if [ -n "${FRESH:-}" ] || [ ! -s "$img" ]; then
	state=$(adb get-state 2>/dev/null | tr -d '\r' || true)
	[ "$state" = recovery ] || { echo "pull-wifi-fw.sh: the phone is not in recovery (adb get-state: ${state:-none}); fastboot boot recovery/recovery.img, wait, run again" >&2; exit 1; }
	dev=$(adb shell 'for d in /dev/block/by-name/modem /dev/block/bootdevice/by-name/modem; do [ -e $d ] && readlink -f $d && break; done' 2>/dev/null | tr -d '\r')
	[ -n "$dev" ] || { echo "pull-wifi-fw.sh: no modem partition (/dev/block/by-name/modem) on the phone" >&2; exit 1; }
	size=$(adb shell "blockdev --getsize64 $dev 2>/dev/null || cat /sys/class/block/${dev##*/}/size" | tr -d '\r')
	echo "reading the modem partition $dev ($((size / 1048576)) MiB, read only) ..."
	adb exec-out "dd if=$dev bs=1048576 2>/dev/null" > "$img.part"
	got=$(stat -c %s "$img.part")
	# (blockdev gives bytes; the /sys fallback gives 512-byte sectors)
	if [ "$got" != "$size" ] && [ "$got" != "$((size * 512))" ]; then
		echo "pull-wifi-fw.sh: got $got bytes of the partition, expected $size: run again" >&2
		exit 1
	fi
	mv "$img.part" "$img"
else
	echo "using the copy of the modem partition already there ($img; FRESH=1 reads it again)"
fi

F="python3 -I $here/tools/fatcopy.py"
$F "$img" list image/qca6390 > "$out/LISTING.txt"
rm -f "$out"/amss*.bin "$out"/m3.bin "$out"/regdb*.bin "$out"/bd*.elf
for p in 'amss*.bin' 'm3.bin' 'regdb*.bin' 'bd*.elf'; do
	$F "$img" get image/qca6390 "$p" "$out" > /dev/null
done
for f in amss20.bin m3.bin regdb.bin bd_j3sgl.elf; do
	if [ -s "$out/$f" ]; then
		printf '%-14s %9s bytes  sha256 %s\n' "$f" "$(stat -c %s "$out/$f")" "$(sha256sum "$out/$f" | cut -c1-16)"
	else
		echo "pull-wifi-fw.sh: $f is not in image/qca6390 of the modem partition (research/apollo-wifi/LISTING.txt)" >&2
		exit 1
	fi
done
echo "pull-wifi-fw.sh: the Wi-Fi firmware is in research/apollo-wifi/ (mkadt.py --wifi-fw research/apollo-wifi)"
