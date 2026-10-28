#!/bin/bash
# The audio DSP's firmware for apollo's iOS root (xnu 0138, sweet_adsp.c), into research/apollo-audio/.
#
# The firmware is Qualcomm's signed image on the phone's modem partition (Android mounts it at
# /vendor/firmware_mnt, files in image/): adsp.mdt and its segments adsp.b00, adsp.b01, ... The
# copy of that partition tools/pull-wifi-fw.sh made (research/apollo-wifi/modem.img) has them; if
# it is not there yet, run that first (in recovery). Nothing on the phone is changed. Not in git.
#
# The kernel reads them from /usr/local/fw/ on the iOS root, once the root is mounted. They get
# there the way other files do (mkadt.py --files-from, xnu 0120): this writes the list,
# research/apollo-audio/files-adsp.txt, for ONE boot; after it the files stay on the root and the
# list is left out again (every boot with it writes them anew, and the boot image carries them).
#
#   tools/pull-audio-fw.sh
#   python3 tools/mkadt.py ... --files-from research/apollo-audio/files-adsp.txt      (one boot)
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
img=$here/research/apollo-wifi/modem.img
out=$here/research/apollo-audio

[ -s "$img" ] || { echo "pull-audio-fw.sh: no $img: run tools/pull-wifi-fw.sh first (the phone in recovery)" >&2; exit 1; }
mkdir -p "$out"
F="python3 -I $here/tools/fatcopy.py"
rm -f "$out"/adsp.mdt "$out"/adsp.b[0-9][0-9]
$F "$img" get image 'adsp.*' "$out" > /dev/null
[ -s "$out/adsp.mdt" ] || { echo "pull-audio-fw.sh: no adsp.mdt in image/ of the modem partition" >&2; exit 1; }

list=$out/files-adsp.txt
{
	echo "# the audio DSP's firmware for /usr/local/fw/ (tools/pull-audio-fw.sh): for one boot"
	for f in "$out"/adsp.mdt "$out"/adsp.b[0-9][0-9]; do
		[ -e "$f" ] || continue
		echo "/usr/local/fw/$(basename "$f")=research/apollo-audio/$(basename "$f") 0:0:0644"
	done
} > "$list"
count=$(grep -c '^/usr' "$list")
bytes=$(cat "$out"/adsp.mdt "$out"/adsp.b[0-9][0-9] 2>/dev/null | wc -c)
printf 'adsp.mdt and %u segments, %u bytes (%u MiB)\n' "$((count - 1))" "$bytes" "$((bytes / 1048576))"
if [ "$bytes" -gt $((48 * 1048576)) ]; then
	echo "pull-audio-fw.sh: more than mkadt.py's 48 MiB of files for one boot: split $list in two boots" >&2
fi
echo "pull-audio-fw.sh: research/apollo-audio/files-adsp.txt lists them for mkadt.py --files-from (one boot)"
