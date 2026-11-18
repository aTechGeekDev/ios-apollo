#!/usr/bin/env bash
# Link this board's OS profiles (os-profiles/*) into a UniXNU checkout's profiles/os/, the only place
# UniXNU reads them from. Harmless to run again; never replaces a profile that is not our link.
# usage: scripts/install-os-profile.sh [UNIXNU_CHECKOUT]   (default: board.toml [package] unixnu)
set -euo pipefail
DEVICE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UNIXNU=${1:-$(python3 -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb"))["package"]["unixnu"])' "$DEVICE/board.toml")}
case "$UNIXNU" in /*) ;; *) UNIXNU=$(cd "$DEVICE/$UNIXNU" && pwd) ;; esac
[ -d "$UNIXNU/profiles/os" ] || { echo "install-os-profile.sh: $UNIXNU is not a UniXNU checkout" >&2; exit 1; }
for profile in "$DEVICE"/os-profiles/*/; do
	name=$(basename "$profile")
	target="$UNIXNU/profiles/os/$name"
	if [ -e "$target" ] && [ ! -L "$target" ]; then
		echo "install-os-profile.sh: $target exists and is not a link; left as it is" >&2
		continue
	fi
	ln -sfn "${profile%/}" "$target"
	echo "install-os-profile.sh: $name -> $target"
done
