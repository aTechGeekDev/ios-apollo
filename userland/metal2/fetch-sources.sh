#!/bin/sh
# Fetch and patch the two large inputs of the Metal-on-Vulkan stack, at pinned commits (IOS-26-Hot's userland.yml steps):
#   $WORK/turnip/mesa      Mesa 85fda3b3 + UniXNU's Mesa patches (their adreno-compiler-inputs.json order, UniXNU at
#                          UNIXNU_COMMIT; BSD-2-Clause-Patent) + turnip/patches/*.patch; adds the darwin kernel backend
#                          (src/freedreno/vulkan/tu_knl_darwin.cc) that speaks turnip/NativeAdrenoABI.h
#   $WORK/metal2vulkan     github.com/steelbrain/metal2vulkan 720ef1ce + metal2/bridge/patches/*.patch
# WORK defaults to <repo>/work/metal2. Nothing is fetched twice: an existing tree is left as it is.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${METAL2_WORK:-$ROOT/work/metal2}
MESA_COMMIT=85fda3b36405bcaea8bffc64aa4f2651dc90770d
UNIXNU_COMMIT=cd1b9757fd5d730bf85aabb37a4bce729ede9e58   # 2026-10-26: the NativeAdreno ABI v1 that IOS-26-Hot's turnip/NativeAdrenoABI.h is (UniXNU changed it on 10-28: SetPriority, Note, OwnedCoherent)
M2V_COMMIT=720ef1ce9ae2a2068999a8675717418b9416283e
mkdir -p "$WORK"

if [ ! -f "$WORK/turnip/mesa/src/freedreno/vulkan/tu_knl_darwin.cc" ]; then
	rm -rf "$WORK/turnip/mesa" "$WORK/UniXNU"
	git init -q "$WORK/UniXNU"
	git -C "$WORK/UniXNU" fetch -q --depth 1 https://github.com/UniXNU/UniXNU.git "$UNIXNU_COMMIT"
	git -C "$WORK/UniXNU" checkout -q FETCH_HEAD
	git init -q "$WORK/turnip/mesa"
	git -C "$WORK/turnip/mesa" fetch -q --depth 1 https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_COMMIT" ||
		git -C "$WORK/turnip/mesa" fetch -q --depth 1 https://chromium.googlesource.com/external/gitlab.freedesktop.org/mesa/mesa "$MESA_COMMIT"
	git -C "$WORK/turnip/mesa" checkout -q FETCH_HEAD
	python3 - "$WORK" <<'PY'
import json, os, subprocess, sys
work = sys.argv[1]
cfg = json.load(open(os.path.join(work, "UniXNU/scripts/data/adreno-compiler-inputs.json")))
assert cfg["mesa"]["commit"] == "85fda3b36405bcaea8bffc64aa4f2651dc90770d", cfg["mesa"]["commit"]
for rel in cfg["patches"]:
    p = os.path.join(work, "UniXNU", rel)
    r = subprocess.run(["git", "-C", os.path.join(work, "turnip/mesa"), "apply", "--check", p], capture_output=True, text=True)
    if r.returncode == 0:
        subprocess.run(["git", "-C", os.path.join(work, "turnip/mesa"), "apply", p], check=True)
        print("applied", rel)
    else:
        print("SKIPPED (does not apply)", rel, r.stderr.strip()[:200])
PY
	test -f "$WORK/turnip/mesa/src/freedreno/vulkan/tu_knl_darwin.cc" || { echo "tu_knl_darwin.cc missing: turnip-darwin-kmd.patch did not apply" >&2; exit 1; }
	for p in "$HERE"/turnip/patches/*.patch; do
		git -C "$WORK/turnip/mesa" apply "$p"
		echo "applied $(basename "$p")"
	done
fi

if [ ! -d "$WORK/metal2vulkan/crates" ]; then
	rm -rf "$WORK/metal2vulkan"
	git init -q "$WORK/metal2vulkan"
	git -C "$WORK/metal2vulkan" fetch -q --depth 1 https://github.com/steelbrain/metal2vulkan.git "$M2V_COMMIT"
	git -C "$WORK/metal2vulkan" checkout -q FETCH_HEAD
	for p in "$HERE"/metal2/bridge/patches/*.patch; do
		git -C "$WORK/metal2vulkan" apply "$p"
		echo "applied $(basename "$p")"
	done
fi
