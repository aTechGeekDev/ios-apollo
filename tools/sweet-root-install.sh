#!/usr/bin/env bash
# Put our programs and libraries into a mounted iOS root (run by build-ios-root.sh and
# sweet-root-add.sh, as root).
#
#   sudo tools/sweet-root-install.sh MOUNTED_ROOT [PROGRAM LABEL]...
#
# Every PROGRAM goes to /usr/local/bin with a launchd job LABEL that runs it once at boot
# (tools/add-launchd-job.py; its output reaches the console log with its name in boot-arg
# sweetnull). With no PROGRAM given, the test programs of the sweet-userland artifact that are
# there: sweet-gpu-test (com.sweet.gputest), sweet-gl-test (com.sweet.gltest). Every file in
# sweet-userland/lib/ (libOSMesa.8.dylib) goes to /usr/local/lib, which is where the programs
# look for it.
#
# The libraries we change often (PUSHED below) go in padded with zeros to 64 MiB, and where their
# blocks lie on the volume is written to research/ios-root/push/NAME.extents (tools/sweet-extents.py):
# tools/sweet-push.sh then writes a new build of one straight over those blocks from recovery, with
# no new root image and no flash of it. 64 MiB is above the sizes at which HFS+ moves a file (its
# on-the-fly defragmentation, its hot-file clustering), so the blocks stay where they were put; the
# padding after the end of a Mach-O is never read (as ios-sailfish does with its GL library).
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
mnt=${1:?usage: sweet-root-install.sh MOUNTED_ROOT [PROGRAM LABEL]...}
shift
plist=$mnt/System/Library/xpc/launchd.plist
[ -f "$plist" ] || { echo "sweet-root-install.sh: $mnt is not an iOS root (no launchd.plist)" >&2; exit 1; }
if [ $# -eq 0 ]; then
	for known in sweet-gpu-test:com.sweet.gputest sweet-gl-test:com.sweet.gltest; do
		if [ -f "$here/sweet-userland/${known%%:*}" ]; then
			set -- "$@" "$here/sweet-userland/${known%%:*}" "${known#*:}"
		fi
	done
fi
[ $(($# % 2)) -eq 0 ] || { echo "sweet-root-install.sh: PROGRAM without LABEL" >&2; exit 1; }

PUSHED="libsweet-gl.dylib libsweet-ca.dylib libOSMesa.8.dylib"
PAD=$((64 * 1048576))
mkdir -p "$mnt/usr/local/bin" "$mnt/usr/local/lib"
work=$(mktemp)
padded=$(mktemp)
trap 'rm -f "$work" "$padded"' EXIT
if [ -d "$here/sweet-userland/lib" ]; then
	for lib in "$here"/sweet-userland/lib/*; do
		[ -f "$lib" ] || continue
		name=${lib##*/} size=$(stat -c %s "$lib")
		case " $PUSHED " in
		*" $name "*)
			[ "$size" -le "$PAD" ] || { echo "sweet-root-install.sh: $name is over 64 MiB" >&2; exit 1; }
			# written whole (zeros included) so that every block is allocated, then where it lies
			cat "$lib" > "$padded"
			head -c $((PAD - size)) /dev/zero >> "$padded"
			rm -f "$mnt/usr/local/lib/$name"
			install -m 0755 "$padded" "$mnt/usr/local/lib/$name"
			mkdir -p "$here/research/ios-root/push"
			python3 "$here/tools/sweet-extents.py" "$mnt/usr/local/lib/$name" "$here/research/ios-root/push/$name.extents"
			sha256sum < "$padded" | cut -d' ' -f1 > "$here/research/ios-root/push/$name.onphone"
			chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$here/research/ios-root/push"   # sweet-push.sh runs as the user
			printf 'added /usr/local/lib/%s (%s bytes, padded to 64 MiB: tools/sweet-push.sh can replace it)\n' "$name" "$size"
			;;
		*)
			install -m 0755 "$lib" "$mnt/usr/local/lib/$name"
			printf 'added /usr/local/lib/%s (%s bytes)\n' "$name" "$size"
			;;
		esac
	done
fi
while [ $# -gt 0 ]; do
	prog=$1 label=$2 name=${1##*/}
	shift 2
	[ -f "$prog" ] || { echo "sweet-root-install.sh: no program at $prog" >&2; exit 1; }
	install -m 0755 "$prog" "$mnt/usr/local/bin/$name"
	python3 "$here/tools/add-launchd-job.py" "$plist" "$work" "$label" "/usr/local/bin/$name" >/dev/null
	cp "$work" "$plist"             # cp onto the existing file: its owner and mode stay
	printf 'added /usr/local/bin/%s, run at boot by launchd job %s\n' "$name" "$label"
done
