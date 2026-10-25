#!/usr/bin/env bash
# Put programs and libraries on the iOS root the phone has (keeping everything the phone wrote
# there, like its finished first-boot setup), each program run once at every boot.
#
#   tools/sweet-root-add.sh [PROGRAM LABEL]...
#   e.g. tools/sweet-root-add.sh sweet-userland/sweet-gpu-test com.sweet.gputest
#   With no PROGRAM: the test programs of sweet-userland/ that are there and its lib/ files
#   (libOSMesa.8.dylib), as tools/sweet-root-install.sh does.
#
# Start with the phone in recovery (fastboot boot recovery/recovery.img).
# Leftovers of earlier runs in research/ are deleted first. Then:
#   1. the phone's iOS root (first 16 GiB of userdata) is copied to
#      research/apollo-root-base.img (~20 minutes)
#   2. ... and copied again to research/apollo-root-new.img
#   3. tools/sweet-root-install.sh puts every PROGRAM into that copy
#      (/usr/local/bin) with a launchd job LABEL that runs it at boot (its
#      output reaches the console log that tools/sweet-log-pull.sh reads with
#      boot-arg sweetnull=...,NAME), and sweet-userland/lib/* into /usr/local/lib
#   4. research/apollo-root-new.simg collects only the changed blocks
#   5. it ASKS, then reboots the phone to fastboot and flashes those blocks to
#      userdata. Answer anything but "yes" and nothing is written. After the
#      flash the copy is what the phone has: it becomes
#      research/ios-root/ios16-root.img (what build-ios-root.sh --reuse starts
#      from), and the first copy is deleted.
# Two progress bars: the whole job and the current step. The PC is kept from
# sleeping while it runs (a suspend cuts the USB copy from the phone).
# Needs: adb, fastboot, python3, sudo, fsck.hfsplus (hfsprogs), the hfsplus
# kernel module, and about 33 GB free under research/.
set -euo pipefail

if [ $(($# % 2)) -ne 0 ] || [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
	sed -n '2,28p' "$0"
	exit 1
fi
# Run again under systemd-inhibit: no suspend, idle sleep or lid-close sleep until the end.
if [ -z "${SWEET_NO_SLEEP:-}" ] && command -v systemd-inhibit >/dev/null &&
    systemd-inhibit --what=sleep:idle:handle-lid-switch --mode=block true 2>/dev/null; then
	export SWEET_NO_SLEEP=1
	exec systemd-inhibit --what=sleep:idle:handle-lid-switch --mode=block \
		--who=sweet-root-add --why="copying the phone's iOS root" "$0" "$@"
fi
[ -n "${SWEET_NO_SLEEP:-}" ] || printf 'note: could not stop the PC from sleeping; keep it awake until this ends\n'
here=$(cd "$(dirname "$0")/.." && pwd)
base=$here/research/apollo-root-base.img
new=$here/research/apollo-root-new.img
simg=$here/research/apollo-root-new.simg
progress=$here/research/.sweet-root-progress
fscklog=$here/research/apollo-root-new.fsck.log
mnt=/mnt/iosroot
size_mib=16384
size=$((size_mib * 1048576))

# --- progress bars: the whole job (steps weighted by how long they take) and the current step
weights=(0 55 15 5 25)          # % of the whole for steps 1..4 (copy from the phone, copy, edit, compare)
bar() {                         # bar PART TOTAL WIDTH
	local part=$1 total=$2 width=$3 fill pct
	((total > 0)) || total=1
	((part > total)) && part=$total
	fill=$((part * width / total))
	pct=$((part * 100 / total))
	printf '[%s%s] %3d%%' "$(printf '%*s' "$fill" '' | tr ' ' '#')" "$(printf '%*s' $((width - fill)) '' | tr ' ' '.')" "$pct"
}
show() {                        # show STEP PART TOTAL TEXT
	local step=$1 part=$2 total=$3 text=$4 before=0 i whole
	for ((i = 1; i < step; i++)); do before=$((before + weights[i])); done
	((total > 0)) || total=1
	((part > total)) && part=$total
	whole=$((before * 100 + weights[step] * 100 * part / total))
	printf '\r\033[K whole %s   step %d/4 %s %s' "$(bar "$whole" 10000 20)" "$step" "$(bar "$part" "$total" 20)" "$text"
}
follow_size() {                 # follow_size PID FILE STEP TEXT: until PID ends, FILE's size against $size
	local now
	while kill -0 "$1" 2>/dev/null; do
		now=$(stat -c %s "$2" 2>/dev/null || echo 0)
		show "$3" "$((now / 1048576))" "$size_mib" "$4 $((now / 1048576))/$size_mib MiB"
		sleep 2
	done
	wait "$1"
}
say() { printf '\n\n== %s\n' "$*"; }
die() { printf '\n\nSTOPPED: %s\n' "$*" >&2; exit 1; }

# --- checks
for ((i = 1; i <= $#; i += 2)); do
	[ -f "${!i}" ] || die "no program at ${!i}"
done
for tool in adb fastboot python3 sudo fsck.hfsplus; do
	command -v "$tool" >/dev/null || die "$tool is not installed"
done
adb get-state 2>/dev/null | grep -q recovery || die "the phone is not in recovery: fastboot boot recovery/recovery.img, wait for it, run again"

# --- leftovers of earlier tries
mkdir -p "$here/research"
if mountpoint -q "$mnt" 2>/dev/null; then
	sudo umount "$mnt" || die "$mnt is still mounted from an earlier try and does not unmount"
fi
for old in "$base.part" "$base" "$new" "$simg" "$progress" "$fscklog"; do
	if [ -e "$old" ]; then
		printf 'deleting %s from an earlier try\n' "${old#"$here"/}"
		rm -f "$old"
	fi
done
free_kb=$(df -Pk "$here/research" | awk 'NR == 2 { print $4 }')
[ "$free_kb" -gt $((33 * 1024 * 1024)) ] || die "need about 33 GB free under research/ (have $((free_kb / 1024 / 1024)) GB)"
# sudo's password now, kept valid until the end (the copies take longer than sudo remembers it)
sudo -v
( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 60; done ) &
keepalive=$!
cleanup() {
	kill "$keepalive" 2>/dev/null || true
	if mountpoint -q "$mnt" 2>/dev/null; then sudo umount "$mnt" || true; fi
}
trap cleanup EXIT

# --- 1. the phone's root
say "1/4 copying the phone's iOS root to ${base#"$here"/}"
adb exec-out "dd if=/dev/block/sda34 bs=1048576 count=$size_mib 2>/dev/null" > "$base.part" &
follow_size $! "$base.part" 1 "from the phone" || die "adb stopped copying: run again"
[ "$(stat -c %s "$base.part")" -eq "$size" ] || die "the copy is short ($(stat -c %s "$base.part") bytes): run again"
mv "$base.part" "$base"
show 1 1 1 "copied"

# --- 2. the copy to edit
say "2/4 making the copy to edit, ${new#"$here"/}"
cp "$base" "$new" &
follow_size $! "$new" 2 "copying" || die "the copy failed"
show 2 1 1 "copied"

# --- 3. the edit
say "3/4 adding the programs and libraries (tools/sweet-root-install.sh)"
show 3 0 5 "checking the filesystem (fsck)"
sudo fsck.hfsplus -fy "$new" >"$fscklog" 2>&1 || true     # never cleanly unmounted on the phone: repairs are expected
show 3 1 5 "mounting"
sudo mkdir -p "$mnt"
sudo mount -t hfsplus -o loop,force "$new" "$mnt"
[ -f "$mnt/System/Library/xpc/launchd.plist" ] || die "this does not look like the iOS root (no launchd.plist)"
show 3 2 5 "installing"
printf '\n'
sudo "$here/tools/sweet-root-install.sh" "$mnt" "$@"
show 3 4 5 "unmounting"
sync
sudo umount "$mnt"
show 3 5 5 "done"

# --- 4. the changed blocks
say "4/4 collecting the changed blocks into ${simg#"$here"/}"
python3 "$here/tools/sparsediff.py" "$base" "$new" "$simg" --progress "$progress" >"$progress.out" &
diffpid=$!
while kill -0 "$diffpid" 2>/dev/null; do
	read -r compared total 2>/dev/null <"$progress" || { compared=0; total=$size; }
	show 4 "$((compared / 1048576))" "$((total / 1048576))" "comparing $((compared / 1048576))/$((total / 1048576)) MiB"
	sleep 2
done
wait "$diffpid" || die "comparing the images failed"
show 4 1 1 "compared"
printf '\n%s\n' "$(cat "$progress.out")"
rm -f "$progress" "$progress.out"

# --- 5. the flash
say "ready to write the changed blocks to the phone's userdata (the iOS root)"
printf 'Type yes to reboot the phone to fastboot and flash them: '
read -r answer
[ "$answer" = yes ] || die "nothing was written to the phone. To flash later: adb reboot bootloader; fastboot flash userdata $simg"
adb reboot bootloader
printf 'waiting for fastboot...\n'
until fastboot devices | grep -q fastboot; do sleep 2; done
fastboot flash userdata "$simg"

# the copy is now what the phone has: keep it as the root image build-ios-root.sh --reuse starts from
mkdir -p "$here/research/ios-root"
mv -f "$new" "$here/research/ios-root/ios16-root.img"
rm -f "$base" "$simg"
say "done: the programs are on the phone and run at every boot"
printf 'research/ios-root/ios16-root.img is now a copy of the phone'"'"'s root.\n'
printf 'Next: boot the kernel as usual; the programs'"'"' output is in the log (tools/sweet-log-pull.sh).\n'
