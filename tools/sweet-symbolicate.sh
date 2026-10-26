#!/usr/bin/env bash
# Name the addresses in a pulled kernel log's crash reports and process samples, on the PC.
#
#   tools/sweet-symbolicate.sh LOG [OUT]          (OUT default: LOG with -sym.txt)
#
# The shared cache is only in the iOS root image, so: mounts research/ios-root/ios16-root.img
# read-only at /mnt/iosroot (unless something is mounted there), copies the cache files into
# research/dsc/ once (a few GB: ipsw keeps its symbol index next to the cache, so the folder must
# be writable, and it follows symbolic links to absolute paths wrongly) and runs
# tools/sweet-crash.py --last (the last sample only) on LOG.
# Needs ipsw (github.com/blacktop/ipsw): see the message below if it is missing.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
log=${1:?usage: sweet-symbolicate.sh LOG [OUT]}
out=${2:-${log%.txt}-sym.txt}
die() { echo "sweet-symbolicate.sh: $*" >&2; exit 1; }
if ! command -v ipsw >/dev/null; then
	die "no ipsw. Install it once:
  url=\$(curl -s https://api.github.com/repos/blacktop/ipsw/releases/latest | grep -o 'https://[^\"]*linux_x86_64.tar.gz' | head -1)
  curl -L \"\$url\" | tar -xz -C /tmp ipsw && sudo install /tmp/ipsw /usr/local/bin/ipsw"
fi
mnt=/mnt/iosroot
if ! mountpoint -q "$mnt"; then
	sudo mkdir -p "$mnt"
	sudo mount -t hfsplus -o loop,ro "$here/research/ios-root/ios16-root.img" "$mnt"
fi
dsc=$here/research/dsc
mkdir -p "$dsc"
copied=0
for f in "$mnt"/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64*; do
	to=$dsc/$(basename "$f")
	[ -L "$to" ] && rm -f "$to"             # links from the first version of this script
	if [ ! -f "$to" ] || [ "$(stat -c %s "$to")" != "$(stat -c %s "$f")" ]; then
		[ $copied = 1 ] || echo "copying the shared cache into $dsc (once)..."
		copied=1
		cp "$f" "$to.part" && mv "$to.part" "$to"
	fi
done
[ -e "$dsc/dyld_shared_cache_arm64" ] || die "no shared cache under $mnt/System/Library/Caches/com.apple.dyld"
# the programs' own binaries are root's only (0700 folders on the image): readable copies for the disassembly
bins=$dsc/root
for rel in usr/libexec/backboardd System/Library/CoreServices/SpringBoard.app/SpringBoard; do
	mkdir -p "$bins/$(dirname "$rel")"
	[ -s "$bins/$rel" ] || { sudo cat "$mnt/$rel" > "$bins/$rel"; }
done
echo "naming the addresses (the first run builds ipsw's symbol index: a few minutes)..."
python3 "$here/tools/sweet-crash.py" --last "$dsc/dyld_shared_cache_arm64" "$bins" "$log" > "$out"
echo "written: $out"
