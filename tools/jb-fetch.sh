#!/bin/sh
# tools/jb-fetch.sh: the files of the in-place jailbreak (userland/jb/sweet_jbinstall.c), into research/jb/
# (kept out of git). Procursus' rootless bootstrap for iOS 16 (CoreFoundation 1900, iphoneos-arm64 = /var/jb),
# recompressed from zstd to xz because iOS's libcompression reads xz but not zstd; and Sileo's rootless .deb.
# Needs curl, zstd and xz. Then boot once with --files-from tools/root-files/jb-install.txt (and the userland
# artifact that has bin/sweet-jbinstall); the phone installs on its own and logs "sweet-jb:" lines.
set -eu
cd "$(dirname "$0")/.."
OUT=research/jb
BOOTSTRAP=https://apt.procurs.us/bootstraps/1900/bootstrap-iphoneos-arm64.tar.zst
SILEO=https://github.com/Sileo/Sileo/releases/download/2.5.1/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb
mkdir -p "$OUT"
for t in curl zstd xz; do command -v "$t" >/dev/null || { echo "jb-fetch: $t is needed (sudo apt install $t)"; exit 1; }; done
[ -s "$OUT/bootstrap.tar.zst" ] || curl -fL -o "$OUT/bootstrap.tar.zst" "$BOOTSTRAP"
[ -s "$OUT/sileo.deb" ] || curl -fL -o "$OUT/sileo.deb" "$SILEO"
if [ ! -s "$OUT/bootstrap.tar.xz" ]; then
	zstd -dc "$OUT/bootstrap.tar.zst" | xz -6 -T0 -c > "$OUT/bootstrap.tar.xz.part"
	mv "$OUT/bootstrap.tar.xz.part" "$OUT/bootstrap.tar.xz"
fi
ls -la "$OUT"
echo "jb-fetch: ready; boot with --files-from tools/root-files/jb-install.txt"
