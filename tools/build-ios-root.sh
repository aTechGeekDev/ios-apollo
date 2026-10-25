#!/usr/bin/env bash
# Build a fresh iOS root for the phone from Apple's IPSW and flash it to userdata.
#
#   tools/build-ios-root.sh [--reuse] [--oslog] [PROGRAM LABEL]...
#   e.g. tools/build-ios-root.sh sweet-userland/sweet-gpu-test com.sweet.gputest
#
# --reuse: skip steps 1-2 and start from the research/ios-root/ios16-root.img
# an earlier run left (never booted: the phone has its own copy), to bring a
# changed sweet-root-tweaks.py or new programs to the phone without a rebuild.
# --oslog: backboardd, SpringBoard and datamigrator also write their os_log to
# the console log (sweet-root-tweaks.py --oslog; boot with
# sweetnull=backboardd,SpringBoard,com.apple.datamigrator,...). A run without it
# takes that out again.
# With no arguments, sweet-userland/sweet-gpu-test is added if it is there.
#   1. the three disk images of the iPhone X (iPhone10,3) iOS 16.7.16 (20H392)
#      IPSW (OS, SystemOS and AppOS, ~7.5 GB), found through its
#      BuildManifest.plist, into research/ipsw/ (kept: the next run reuses them)
#   2. tools/mkiosroot.sh: research/ios-root/ios16-root.img, 16 GiB HFS+
#   3. tools/sweet-root-tweaks.py (Setup skipped, activation, no baseband
#      daemon, ...) and every PROGRAM into /usr/local/bin, each with a launchd
#      job LABEL that runs it at boot (its output reaches the console log
#      with boot-arg sweetnull=backboardd,SpringBoard,NAME)
#   4. research/ios-root/ios16-root.simg (img2simg)
#   5. it ASKS, then flashes that to userdata (phone in fastboot, ~7 minutes).
#      Anything but "yes" writes nothing to the phone.
# Leftovers of earlier runs (images, a stale mount) are removed first, and the
# PC is kept from sleeping. IPSW_URL=... overrides the download link (default:
# asked of api.ipsw.me).
# Needs: curl, python3, sudo, apfs-fuse, hfsprogs (mkfs/fsck.hfsplus), rsync,
# img2simg (android-sdk-libsparse-utils), fastboot, adb, about 40 GB free.
set -euo pipefail

device=iPhone10,3
build=20H392
here=$(cd "$(dirname "$0")/.." && pwd)
ipswdir=$here/research/ipsw/${device/,/_}-$build
out=$here/research/ios-root
img=$out/ios16-root.img
simg=$out/ios16-root.simg
mnt=/mnt/iosroot
reuse=${SWEET_REUSE:-}
oslog=${SWEET_OSLOG:-}

while [ "${1:-}" = --reuse ] || [ "${1:-}" = --oslog ]; do
	# exported: kept across the systemd-inhibit re-run below
	if [ "$1" = --reuse ]; then reuse=1; export SWEET_REUSE=1; else oslog=--oslog; export SWEET_OSLOG=--oslog; fi
	shift
done
if [ $# -eq 0 ] && [ -f "$here/sweet-userland/sweet-gpu-test" ]; then
	set -- "$here/sweet-userland/sweet-gpu-test" com.sweet.gputest
fi
if [ $(($# % 2)) -ne 0 ] || [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
	sed -n '2,31p' "$0"
	exit 1
fi
# Run again under systemd-inhibit: no suspend, idle sleep or lid-close sleep until the end.
if [ -z "${SWEET_NO_SLEEP:-}" ] && command -v systemd-inhibit >/dev/null &&
    systemd-inhibit --what=sleep:idle:handle-lid-switch --mode=block true 2>/dev/null; then
	export SWEET_NO_SLEEP=1
	exec systemd-inhibit --what=sleep:idle:handle-lid-switch --mode=block \
		--who=build-ios-root --why="building and flashing the iOS root" "$BASH" "$0" "$@"
fi
[ -n "${SWEET_NO_SLEEP:-}" ] || printf 'note: could not stop the PC from sleeping; keep it awake until this ends\n'

weights=(0 40 35 5 10 10)       # % of the whole for steps 1..5
bar() {                         # bar PART TOTAL WIDTH
	local part=$1 total=$2 width=$3 fill
	((total > 0)) || total=1
	((part > total)) && part=$total
	fill=$((part * width / total))
	printf '[%s%s] %3d%%' "$(printf '%*s' "$fill" '' | tr ' ' '#')" "$(printf '%*s' $((width - fill)) '' | tr ' ' '.')" \
		$((part * 100 / total))
}
step() {                        # step N TEXT: the whole job's bar as step N begins
	local before=0 i
	for ((i = 1; i < $1; i++)); do before=$((before + weights[i])); done
	printf '\n== whole %s   step %d/5: %s\n' "$(bar "$before" 100 30)" "$1" "$2"
}
die() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }

# --- checks
programs=()
while [ $# -gt 0 ]; do
	[ -f "$1" ] || die "no program at $1"
	programs+=("$1" "$2")
	shift 2
done
for tool in curl python3 sudo apfs-fuse mkfs.hfsplus fsck.hfsplus rsync img2simg fastboot adb; do
	command -v "$tool" >/dev/null || die "$tool is not installed (Kali: sudo apt install curl apfs-fuse hfsprogs rsync android-sdk-libsparse-utils fastboot adb)"
done
mkdir -p "$ipswdir" "$out"
sudo -v
( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 60; done ) &
keepalive=$!
cleanup() {
	kill "$keepalive" 2>/dev/null || true
	if mountpoint -q "$mnt" 2>/dev/null; then sudo umount "$mnt" || true; fi
}
trap cleanup EXIT

# --- leftovers of earlier tries (the downloaded disk images are kept)
if mountpoint -q "$mnt" 2>/dev/null; then
	sudo umount "$mnt" || die "$mnt is still mounted from an earlier try and does not unmount"
fi
if [ -n "$reuse" ]; then
	[ -f "$img" ] || die "--reuse: no ${img#"$here"/} from an earlier run; run without --reuse"
	olds=("$simg")
else
	olds=("$img" "$simg")
fi
for old in "${olds[@]}"; do
	if [ -e "$old" ]; then
		printf 'deleting %s from an earlier try\n' "${old#"$here"/}"
		rm -f "$old"
	fi
done
free_kb=$(df -Pk "$out" | awk 'NR == 2 { print $4 }')
have_kb=$(du -sk "$ipswdir" | awk '{ print $1 }')
need_kb=$(((40 * 1024 * 1024) - have_kb))
[ -z "$reuse" ] || need_kb=$((14 * 1024 * 1024))         # the sparse image only
[ "$free_kb" -gt "$need_kb" ] || die "need about $((need_kb / 1024 / 1024)) GB free under research/ (have $((free_kb / 1024 / 1024)) GB)"

# --- 1. the IPSW's disk images
if [ -n "$reuse" ]; then
	step 1 "skipped (--reuse)"
	step 2 "skipped (--reuse): ${img#"$here"/} from an earlier run"
else
step 1 "downloading the IPSW's disk images ($device $build) into ${ipswdir#"$here"/}"
url=${IPSW_URL:-}
if [ -z "$url" ]; then
	url=$(curl -sfL "https://api.ipsw.me/v4/ipsw/$device/$build" | python3 -c 'import json, sys; print(json.load(sys.stdin)["url"])') ||
		die "could not ask api.ipsw.me for the IPSW link; set IPSW_URL=... and run again"
fi
printf 'IPSW: %s\n' "$url"
python3 "$here/tools/remotezip.py" "$url" BuildManifest.plist "$ipswdir" >/dev/null ||
	die "could not read the IPSW at $url (no network, or a wrong IPSW_URL)"
read -r os_dmg sysos_dmg appos_dmg < <(python3 - "$ipswdir/BuildManifest.plist" <<'EOF'
import plistlib, sys
manifest = plistlib.load(open(sys.argv[1], 'rb'))
ident = next(i for i in manifest['BuildIdentities'] if i['Info'].get('RestoreBehavior') == 'Erase')['Manifest']
print(ident['OS']['Info']['Path'], ident['Cryptex1,SystemOS']['Info']['Path'], ident['Cryptex1,AppOS']['Info']['Path'])
EOF
)
[ -n "${appos_dmg:-}" ] || die "no OS/SystemOS/AppOS disk images in research/${ipswdir#"$here"/research/}/BuildManifest.plist"
printf 'disk images: OS %s, SystemOS %s, AppOS %s\n' "$os_dmg" "$sysos_dmg" "$appos_dmg"
for dmg in "$os_dmg" "$sysos_dmg" "$appos_dmg"; do
	python3 "$here/tools/remotezip.py" "$url" "$dmg" "$ipswdir" || die "downloading $dmg failed; run again to resume"
done

# --- 2. the root
step 2 "building ${img#"$here"/} from them (tools/mkiosroot.sh)"
"$here/tools/mkiosroot.sh" "$ipswdir/$os_dmg" "$ipswdir/$sysos_dmg" "$ipswdir/$appos_dmg" "$img" 16G ||
	die "building the root failed (its output is above)"
fi

# --- 3. the changes
step 3 "the repo's changes (tools/sweet-root-tweaks.py) and the programs"
sudo fsck.hfsplus -fy "$img" >/dev/null 2>&1 || true
sudo mkdir -p "$mnt"
sudo mount -t hfsplus -o loop,force "$img" "$mnt" || die "could not mount $img (is the hfsplus kernel module there? sudo modprobe hfsplus)"
[ -f "$mnt/System/Library/xpc/launchd.plist" ] || die "$img does not look like an iOS root (no launchd.plist)"
sudo python3 "$here/tools/sweet-root-tweaks.py" $oslog "$mnt"
for ((i = 0; i < ${#programs[@]}; i += 2)); do
	prog=${programs[i]}
	label=${programs[i + 1]}
	name=$(basename "$prog")
	sudo mkdir -p "$mnt/usr/local/bin"
	sudo install -m 0755 "$prog" "$mnt/usr/local/bin/$name"
	python3 "$here/tools/add-launchd-job.py" "$mnt/System/Library/xpc/launchd.plist" /tmp/sweet-launchd.plist \
		"$label" "/usr/local/bin/$name" >/dev/null
	sudo cp /tmp/sweet-launchd.plist "$mnt/System/Library/xpc/launchd.plist"
	printf 'added /usr/local/bin/%s, run at boot by launchd job %s\n' "$name" "$label"
done
sync
sudo umount "$mnt"
# A fresh journaled volume always reads "needs minor repair" to Linux fsck -n: shown, not fatal.
sudo fsck.hfsplus -fn "$img" 2>&1 | tail -2 || true

# --- 4. the sparse image
step 4 "making ${simg#"$here"/} (img2simg)"
img2simg "$img" "$simg"
ls -l "$simg"

# --- 5. the flash
step 5 "ready to flash it to the phone's userdata (the iOS root; ~7 minutes)"
printf 'Put the phone in fastboot mode (volume down + power), then type yes to flash: '
read -r answer
[ "$answer" = yes ] || die "nothing was written to the phone. To flash later: fastboot flash -S 512M userdata $simg"
if ! fastboot devices | grep -q fastboot; then
	adb reboot bootloader 2>/dev/null || true
	printf 'waiting for the phone in fastboot mode...\n'
	until fastboot devices | grep -q fastboot; do sleep 2; done
fi
fastboot flash -S 512M userdata "$simg"

printf '\n== whole %s   done: a fresh iOS root is on the phone\n' "$(bar 100 100 30)"
printf 'After a big flash the phone'"'"'s fastboot often hangs on the next "fastboot boot" ("Sending"):\n'
printf 'then hold volume down + power to re-enter fastboot and boot again.\n'
