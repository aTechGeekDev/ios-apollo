#!/usr/bin/env bash
# Write new builds of the libraries tools/sweet-root-install.sh pads (libsweet-gl, libsweet-ca,
# libOSMesa) straight over their blocks in the phone's iOS root, from recovery: no new root image
# and no flash of one. A minute instead of a rebuild.
#
#   tools/sweet-push.sh [-y] [FILE...]
#
# With no FILE: every sweet-userland/lib/ file that has a research/ios-root/push/NAME.extents
# (written when the root was built: only a root built since then can be pushed to).
# Start with the phone in recovery: fastboot boot recovery/recovery.img; adb wait-for-recovery.
# Before anything is written, for each file:
#   - the phone's userdata holds the volume the extents were taken from (HFS+ volume header,
#     same creation date),
#   - the file's first block there starts like a Mach-O (the library that is there now),
#   - the whole 64 MiB there reads back as exactly what was last put there (NAME.onphone: the
#     sha256 of the build installed or last pushed; so a root rebuilt on the PC but not flashed
#     is never written into by the wrong map),
#   - the new build fits in the 64 MiB it was given.
# Then it asks (-y: does not), writes every run with dd, drops the caches, reads the runs back
# and compares them with what was meant to go there. Afterwards: adb reboot bootloader.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
yes=
if [ "${1:-}" = -y ]; then
	yes=1
	shift
fi
if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
	sed -n '2,18p' "$0"
	exit 0
fi
die() { echo "sweet-push.sh: $*" >&2; exit 1; }

# a shell script for the phone: the runs of EXT read into /tmp/sweet-back.bin (in file order)
readback_script() {
	echo 'set -e'
	echo 'rm -f /tmp/sweet-back.bin'
	grep -v '^#' "$1" | while read -r logical phys bytes; do
		echo "dd if=$dev of=/tmp/sweet-back.bin bs=$2 skip=$((phys / $2)) seek=$((logical / $2)) count=$((bytes / $2)) conv=notrunc 2>/dev/null"
	done
	echo 'echo done'
}

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
	for lib in "$here"/sweet-userland/lib/*; do
		[ -f "$here/research/ios-root/push/${lib##*/}.extents" ] && files+=("$lib")
	done
	[ ${#files[@]} -gt 0 ] || die "no sweet-userland/lib/ file has research/ios-root/push/NAME.extents: build the root once with this version (tools/build-ios-root.sh --reuse), then push"
fi
command -v adb >/dev/null || die "adb is not installed"
adb get-state 2>/dev/null | grep -q recovery || die "the phone is not in recovery: fastboot boot recovery/recovery.img, adb wait-for-recovery, run again"
dev=$(adb shell 'for d in /dev/block/by-name/userdata /dev/block/bootdevice/by-name/userdata; do [ -e $d ] && readlink -f $d && break; done' | tr -d '\r')
[ -n "$dev" ] || die "no userdata block device on the phone"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
adb exec-out "dd if=$dev bs=512 skip=2 count=1 2>/dev/null" > "$tmp/header"
read -r signature created < <(python3 - "$tmp/header" <<'EOF'
import struct, sys
h = open(sys.argv[1], 'rb').read()
print(h[:2].decode('latin-1') if len(h) >= 0x14 else '--', '%#010x' % struct.unpack('>I', h[0x10:0x14])[0] if len(h) >= 0x14 else '-')
EOF
)
[ "$signature" = H+ ] || [ "$signature" = HX ] || die "$dev holds no HFS+ volume (signature '$signature')"

# each file: check, pad, plan
plan=()
for file in "${files[@]}"; do
	name=${file##*/}
	ext=$here/research/ios-root/push/$name.extents
	[ -f "$file" ] || die "no file $file"
	[ -f "$ext" ] || die "no $ext: $name was not installed padded (build the root once with this version)"
	read -r _ _ _ total _ _ _ was_created _ block < "$ext"
	[ "$was_created" = "$created" ] || die "$name: the phone's iOS root (created $created) is not the image $ext was taken from ($was_created): flash the root built with this version first"
	[ -f "${ext%.extents}.onphone" ] || die "no ${ext%.extents}.onphone"
	size=$(stat -c %s "$file")
	[ "$size" -le "$total" ] || die "$name is $size bytes, more than the $total it has on the phone"
	covered=$(grep -v '^#' "$ext" | awk '{ n += $3 } END { print n + 0 }')
	[ "$covered" = "$total" ] || die "$ext covers $covered bytes, not $total"
	first=$(grep -v '^#' "$ext" | head -1 | cut -d' ' -f2)
	adb exec-out "dd if=$dev bs=$block skip=$((first / block)) count=1 2>/dev/null" > "$tmp/first"
	magic=$(head -c 4 "$tmp/first" | od -An -tx1 | tr -d ' \n')
	[ "$magic" = cffaedfe ] || die "$name: its first block on the phone does not start like a Mach-O ($magic): not writing"
	readback_script "$ext" "$block" > "$tmp/read.sh"
	adb push "$tmp/read.sh" /tmp/sweet-push-read.sh >/dev/null
	[ "$(adb shell sh /tmp/sweet-push-read.sh | tr -d '\r' | tail -1)" = done ] || die "$name: reading it on the phone failed"
	adb pull /tmp/sweet-back.bin "$tmp/before" >/dev/null
	adb shell rm -f /tmp/sweet-back.bin /tmp/sweet-push-read.sh
	[ "$(sha256sum < "$tmp/before" | cut -d' ' -f1)" = "$(cat "${ext%.extents}.onphone")" ] ||
		die "$name: what the phone holds there is not what was last put there (${ext%.extents}.onphone): the map does not fit the phone; flash the root built with this version"
	{ cat "$file"; head -c $((total - size)) /dev/zero; } > "$tmp/$name"
	runs=$(grep -vc '^#' "$ext")
	printf '%s: %s bytes (of %s) into %s run(s) of %s on %s\n' "$name" "$size" "$total" "$runs" "${ext##*/}" "$dev"
	plan+=("$name")
done
if [ -z "$yes" ]; then
	printf 'Type yes to write them into the phone'"'"'s iOS root: '
	read -r answer
	[ "$answer" = yes ] || die "nothing was written"
fi

for name in "${plan[@]}"; do
	ext=$here/research/ios-root/push/$name.extents
	read -r _ _ _ total _ _ _ _ _ block < "$ext"
	{
		echo 'set -e'
		grep -v '^#' "$ext" | while read -r logical phys bytes; do
			echo "dd if=/tmp/sweet-push.bin of=$dev bs=$block skip=$((logical / block)) seek=$((phys / block)) count=$((bytes / block)) conv=notrunc 2>/dev/null"
		done
		echo 'sync; echo 3 > /proc/sys/vm/drop_caches'
		readback_script "$ext" "$block" | grep -v '^set -e'
	} > "$tmp/run.sh"
	adb push "$tmp/$name" /tmp/sweet-push.bin >/dev/null
	adb push "$tmp/run.sh" /tmp/sweet-push-run.sh >/dev/null
	[ "$(adb shell sh /tmp/sweet-push-run.sh | tr -d '\r' | tail -1)" = done ] || die "$name: writing on the phone failed"
	adb pull /tmp/sweet-back.bin "$tmp/back" >/dev/null
	adb shell rm -f /tmp/sweet-push.bin /tmp/sweet-back.bin /tmp/sweet-push-run.sh
	cmp -s "$tmp/back" "$tmp/$name" || die "$name: what the phone reads back is not what was written"
	sha256sum < "$tmp/$name" | cut -d' ' -f1 > "${ext%.extents}.onphone"
	printf '%s: written and read back the same (%s)\n' "$name" "$(sha256sum "$tmp/$name" | cut -c1-16)"
done
echo "sweet-push.sh: done; boot with: adb reboot bootloader, then fastboot boot shim/out/shim-boot.img"
