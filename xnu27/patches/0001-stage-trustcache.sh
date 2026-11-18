#!/bin/bash
# Reuse the headers shipped with the pinned darwin-xnu-build dependency.
# Run from dxb/xnu, before SWEET patches and before exporting kernel headers.
set -euo pipefail

if [[ -n "${MACHINE_CONFIG:-}" && "${MACHINE_CONFIG}" != SWEET ]]; then
    exit 0
fi

patch=../patches/TrustCache.patch
if [[ ! -f "$patch" ]]; then
    echo "Missing pinned darwin-xnu-build TrustCache headers: $patch" >&2
    exit 1
fi

if git apply --check "$patch" 2>/dev/null; then
    git apply "$patch"
elif git apply --reverse --check "$patch" 2>/dev/null; then
    echo "Pinned TrustCache headers already staged"
else
    echo "TrustCache headers differ from the pinned dependency; refusing to overwrite" >&2
    exit 1
fi
