#!/bin/sh
# Pack apps for the phone (PC side): tools/app-pack.sh APP.ipa|APP.app [...]
# Each becomes research/apps/NAME.tar.gz (the .app at the top, owner root) and a line in research/apps/apps.txt for
# mkadt.py --files-from. On the phone userland/jb/sweet-jbpost.sh (tools/root-files/jb-post.txt) unpacks them into
# /Applications; one more boot with tools/root-files/ls-rebuild.txt makes LaunchServices register them.
# The boot image carries 48 MiB of files at most. App Store apps are encrypted (FairPlay) and will not start:
# use decrypted or self-built ones. Not in git: research/ is ignored.
set -eu
[ $# -ge 1 ] || { sed -n '2,7p' "$0"; exit 1; }
out=research/apps
mkdir -p "$out"
: > "$out/apps.txt.new"
[ -f "$out/apps.txt" ] && cat "$out/apps.txt" > "$out/apps.txt.new"
for src in "$@"; do
	work=$(mktemp -d)
	case "$src" in
	*.ipa)
		unzip -q "$src" 'Payload/*' -d "$work"
		app=$(find "$work/Payload" -maxdepth 1 -name '*.app' -type d | head -1)
		;;
	*.app|*.app/)
		cp -R "${src%/}" "$work/"
		app="$work/$(basename "${src%/}")"
		;;
	*)
		echo "$src: give an .ipa or an .app folder" >&2; rm -rf "$work"; exit 1
		;;
	esac
	[ -n "$app" ] && [ -f "$app/Info.plist" ] || { echo "$src: no .app with an Info.plist inside" >&2; rm -rf "$work"; exit 1; }
	name=$(basename "$app" .app)
	tar -czf "$out/$name.tar.gz" --owner=0 --group=0 -C "$(dirname "$app")" "$name.app"
	rm -rf "$work"
	line="/private/var/sweet-jb/apps/$name.tar.gz=$out/$name.tar.gz 0:0:0600"
	grep -qxF "$line" "$out/apps.txt.new" || echo "$line" >> "$out/apps.txt.new"
	echo "$name.app: $(du -h "$out/$name.tar.gz" | cut -f1) -> $out/$name.tar.gz"
done
mv "$out/apps.txt.new" "$out/apps.txt"
total=$(sed 's/=\([^ ]*\) .*/ \1/' "$out/apps.txt" | while read -r _ f; do [ -f "$f" ] && stat -c %s "$f"; done | awk '{s+=$1} END {print s+0}')
echo "research/apps/apps.txt: $(wc -l < "$out/apps.txt") app(s), $((total / 1048576)) MiB (48 MiB a boot at most)"
