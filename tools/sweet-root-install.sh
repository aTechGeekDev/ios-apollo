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

mkdir -p "$mnt/usr/local/bin" "$mnt/usr/local/lib"
if [ -d "$here/sweet-userland/lib" ]; then
	for lib in "$here"/sweet-userland/lib/*; do
		[ -f "$lib" ] || continue
		install -m 0755 "$lib" "$mnt/usr/local/lib/${lib##*/}"
		printf 'added /usr/local/lib/%s (%s bytes)\n' "${lib##*/}" "$(stat -c %s "$lib")"
	done
fi
work=$(mktemp)
trap 'rm -f "$work"' EXIT
while [ $# -gt 0 ]; do
	prog=$1 label=$2 name=${1##*/}
	shift 2
	[ -f "$prog" ] || { echo "sweet-root-install.sh: no program at $prog" >&2; exit 1; }
	install -m 0755 "$prog" "$mnt/usr/local/bin/$name"
	python3 "$here/tools/add-launchd-job.py" "$plist" "$work" "$label" "/usr/local/bin/$name" >/dev/null
	cp "$work" "$plist"             # cp onto the existing file: its owner and mode stay
	printf 'added /usr/local/bin/%s, run at boot by launchd job %s\n' "$name" "$label"
done
