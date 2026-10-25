#!/usr/bin/env bash
# Put a program on the phone's iOS root and run it once at every boot.
#
#   tools/sweet-root-add.sh PROGRAM LABEL
#   e.g. tools/sweet-root-add.sh sweet-userland/sweet-gpu-test com.sweet.gputest
#
# Start with the phone in recovery (fastboot boot recovery/recovery.img).
# The script:
#   1. copies the phone's iOS root (first 16 GiB of userdata) to
#      research/apollo-root-base.img (~12 minutes)
#   2. edits a copy, research/apollo-root-new.img: PROGRAM goes to
#      /usr/local/bin, a launchd job LABEL runs it at boot (output in the
#      console log that tools/sweet-log-pull.sh reads)
#   3. makes research/apollo-root-new.simg holding only the changed blocks
#   4. ASKS, then reboots the phone to fastboot and flashes those blocks to
#      userdata. Answer anything but "yes" and nothing is written.
# Needs: adb, fastboot, python3, sudo, fsck.hfsplus (hfsprogs), the hfsplus
# kernel module, and about 33 GB free under research/.
set -euo pipefail

if [ $# -ne 2 ]; then
	sed -n '2,18p' "$0"
	exit 1
fi
program=$1
label=$2
name=$(basename "$program")
here=$(cd "$(dirname "$0")/.." && pwd)
base=$here/research/apollo-root-base.img
new=$here/research/apollo-root-new.img
simg=$here/research/apollo-root-new.simg
mnt=/mnt/iosroot
size_mib=16384

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }

[ -f "$program" ] || die "no program at $program"
for tool in adb fastboot python3 sudo fsck.hfsplus; do
	command -v "$tool" >/dev/null || die "$tool is not installed"
done
mkdir -p "$here/research"
free_kb=$(df -Pk "$here/research" | awk 'NR == 2 { print $4 }')
[ "$free_kb" -gt $((33 * 1024 * 1024)) ] || die "need about 33 GB free under research/ (have $((free_kb / 1024 / 1024)) GB)"
adb get-state 2>/dev/null | grep -q recovery || die "the phone is not in recovery: fastboot boot recovery/recovery.img, wait for it, run again"

say "1/4 copying the phone's iOS root to $base (about 12 minutes)"
adb exec-out "dd if=/dev/block/sda34 bs=1048576 count=$size_mib 2>/dev/null" > "$base.part" &
pull=$!
while kill -0 "$pull" 2>/dev/null; do
	sleep 20
	printf '   %d of %d MiB\n' $(($(stat -c %s "$base.part") / 1048576)) "$size_mib"
done
wait "$pull" || die "adb stopped copying: run again"
[ "$(stat -c %s "$base.part")" -eq $((size_mib * 1048576)) ] || die "the copy is short ($(stat -c %s "$base.part") bytes): run again"
mv "$base.part" "$base"

say "2/4 adding $name and the launchd job $label to a copy"
cp "$base" "$new"
sudo fsck.hfsplus -fy "$new" || true          # the root is never cleanly unmounted; repairs are expected
sudo mkdir -p "$mnt"
sudo mount -t hfsplus -o loop,force "$new" "$mnt"
trap 'sudo umount "$mnt" 2>/dev/null || true' EXIT
[ -f "$mnt/System/Library/xpc/launchd.plist" ] || die "this does not look like the iOS root (no launchd.plist)"
sudo mkdir -p "$mnt/usr/local/bin"
sudo install -m 0755 "$program" "$mnt/usr/local/bin/$name"
python3 "$here/tools/add-launchd-job.py" "$mnt/System/Library/xpc/launchd.plist" /tmp/sweet-launchd.plist \
	"$label" "/usr/local/bin/$name"
sudo cp /tmp/sweet-launchd.plist "$mnt/System/Library/xpc/launchd.plist"
sync
sudo umount "$mnt"
trap - EXIT

say "3/4 collecting the changed blocks into $simg"
python3 "$here/tools/sparsediff.py" "$base" "$new" "$simg"

say "4/4 ready to write the changed blocks to the phone's userdata (the iOS root)"
printf 'Type yes to reboot the phone to fastboot and flash them: '
read -r answer
[ "$answer" = yes ] || die "nothing was written to the phone. To flash later: adb reboot bootloader; fastboot flash userdata $simg"
adb reboot bootloader
printf 'waiting for fastboot...\n'
until fastboot devices | grep -q fastboot; do sleep 2; done
fastboot flash userdata "$simg"

say "done: the phone runs /usr/local/bin/$name at every boot"
printf 'The phone now holds %s: keep it as the base for the next change.\n' "$new"
printf 'Next: boot the kernel as usual; the program'"'"'s output is in the log (tools/sweet-log-pull.sh).\n'
