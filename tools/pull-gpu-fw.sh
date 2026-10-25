#!/usr/bin/env bash
# Pull the Adreno firmware the boot image needs from the phone into research/apollo-gpu/.
#
#   tools/pull-gpu-fw.sh            (phone in recovery: fastboot boot recovery/recovery.img)
#
# These files are Qualcomm's, already on the phone (/vendor/firmware/); they are not in git
# (research/ is gitignored). mkadt.py reads them with --gmu-fw / --sqe-fw / --zap-mdt / --zap-seg.
# A fresh PC that does not have research/apollo-gpu/ (e.g. one restored from an older backup) can
# get them back this way without touching the main machine.
#
# Needs adb, with the phone booted into recovery (OrangeFox) so /vendor is readable.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
out=$here/research/apollo-gpu
files=(a650_gmu.bin a650_sqe.fw a650_zap.mdt a650_zap.b00 a650_zap.b01 a650_zap.b02)
src=/vendor/firmware

command -v adb >/dev/null 2>&1 || { echo "pull-gpu-fw.sh: adb is not installed" >&2; exit 1; }
state=$(adb get-state 2>/dev/null | tr -d '\r' || true)
[ "$state" = recovery ] || { echo "pull-gpu-fw.sh: the phone is not in recovery (adb get-state: ${state:-none}); fastboot boot recovery/recovery.img, wait, run again" >&2; exit 1; }

# /vendor may need mounting in recovery.
if [ "$(adb shell "[ -e $src/${files[0]} ] && echo yes" 2>/dev/null | tr -d '\r')" != yes ]; then
	adb shell 'mount /vendor 2>/dev/null; mount -o ro /vendor 2>/dev/null' >/dev/null 2>&1 || true
fi

mkdir -p "$out"
missing=0
for f in "${files[@]}"; do
	if adb pull "$src/$f" "$out/$f" >/dev/null 2>&1 && [ -s "$out/$f" ]; then
		printf 'pulled %-14s %s bytes\n' "$f" "$(stat -c %s "$out/$f")"
	else
		printf 'MISSING %-14s (not at %s/%s on the phone)\n' "$f" "$src" "$f"
		rm -f "$out/$f"
		missing=1
	fi
done

if [ "$missing" -ne 0 ]; then
	echo "pull-gpu-fw.sh: some files were not found. If /vendor is not mounted in this recovery, try:" >&2
	echo "  adb shell mount /vendor   # then run again" >&2
	exit 1
fi
echo "pull-gpu-fw.sh: Adreno firmware is in ${out#"$here"/}/ (reboot the phone: adb reboot bootloader)"
