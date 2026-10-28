#!/bin/bash
# Pull the QCA6390 Bluetooth firmware from the phone into research/apollo-bt/.
#
# The files are Qualcomm's, on the phone's bluetooth partition (a FAT image; Android mounts it at
# /vendor/bt_firmware, files in image/): htbtfw20.tlv (the patch for the chip's ROM) and htnv20.bin
# (its NVM: settings), as the Mi 10 port uses them (devices/xiaomi-mi-10/README.md). They are not
# in git (research/ is gitignored).
#
# As tools/pull-wifi-fw.sh: nothing on the phone is mounted or changed; the partition is read
# whole (adb exec-out dd) to research/apollo-bt/bluetooth.img and the files are taken out of that
# copy with tools/fatcopy.py. A copy already there is used again (FRESH=1: read it again).
#
#   fastboot boot recovery/recovery.img && adb wait-for-recovery && tools/pull-bt-fw.sh
#   python3 tools/mkadt.py ... --bt-fw research/apollo-bt
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
out=$here/research/apollo-bt
img=$out/bluetooth.img

command -v adb >/dev/null 2>&1 || { echo "pull-bt-fw.sh: adb is not installed" >&2; exit 1; }
mkdir -p "$out"

if [ -n "${FRESH:-}" ] || [ ! -s "$img" ]; then
	state=$(adb get-state 2>/dev/null | tr -d '\r' || true)
	[ "$state" = recovery ] || { echo "pull-bt-fw.sh: the phone is not in recovery (adb get-state: ${state:-none}); fastboot boot recovery/recovery.img, wait, run again" >&2; exit 1; }
	dev=$(adb shell 'for d in /dev/block/by-name/bluetooth /dev/block/by-name/bluetooth_a /dev/block/bootdevice/by-name/bluetooth; do [ -e $d ] && readlink -f $d && break; done' 2>/dev/null | tr -d '\r')
	[ -n "$dev" ] || { echo "pull-bt-fw.sh: no bluetooth partition on the phone (adb shell ls /dev/block/by-name shows them)" >&2; exit 1; }
	size=$(adb shell "blockdev --getsize64 $dev 2>/dev/null || cat /sys/class/block/${dev##*/}/size" | tr -d '\r')
	echo "reading the bluetooth partition $dev ($((size / 1024)) KiB, read only) ..."
	adb exec-out "dd if=$dev bs=1048576 2>/dev/null" > "$img.part"
	got=$(stat -c %s "$img.part")
	# (blockdev gives bytes; the /sys fallback gives 512-byte sectors)
	if [ "$got" != "$size" ] && [ "$got" != "$((size * 512))" ]; then
		echo "pull-bt-fw.sh: got $got bytes of the partition, expected $size: run again" >&2
		exit 1
	fi
	mv "$img.part" "$img"
else
	echo "using the copy of the bluetooth partition already there ($img; FRESH=1 reads it again)"
fi

F="python3 -I $here/tools/fatcopy.py"
dir=image
$F "$img" list "$dir" > "$out/LISTING.txt" 2>/dev/null || { dir=/; $F "$img" list / > "$out/LISTING.txt"; }
rm -f "$out"/htbtfw*.tlv "$out"/htnv*
for p in 'htbtfw*.tlv' 'htnv*'; do
	$F "$img" get "$dir" "$p" "$out" > /dev/null || true
done
for f in htbtfw20.tlv htnv20.bin; do
	if [ -s "$out/$f" ]; then
		printf '%-14s %9s bytes  sha256 %s\n' "$f" "$(stat -c %s "$out/$f")" "$(sha256sum "$out/$f" | cut -c1-16)"
	else
		echo "pull-bt-fw.sh: $f is not in $dir of the bluetooth partition (research/apollo-bt/LISTING.txt has what is)" >&2
		exit 1
	fi
done
echo "pull-bt-fw.sh: the Bluetooth firmware is in research/apollo-bt/ (mkadt.py --bt-fw research/apollo-bt)"
