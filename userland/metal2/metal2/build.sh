#!/bin/sh
# Build SweetMetal2.bundle (metal2vulkan + Turnip; the executable keeps IOS-26-Hot's name, HotMetal2) for iOS arm64
# into metal2/out, signed ad hoc. The kernel (SweetAccelerator, sweetmtl=2) names this bundle SweetMetal2 and its class
# SweetMTL2Device (HotMetal2.mm defines it as HotMTL2Device's alias).
#   userland/metal2/metal2/build.sh        (first: ../build-turnip-ios.sh, ../build-m2v-bridge.sh)
# Also m2vtest (the bridge's self-test).
set -e
cd "$(dirname "$0")"
ROOT=$(cd ../../.. && pwd)
WORK=${METAL2_WORK:-$ROOT/work/metal2}
CC="$ROOT/userland/metal2/ios-cc"
BRIDGE=$WORK/m2v-bridge/ios/libnative_metal_bridge.a
TURNIP=$WORK/turnip/build-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib
B=out/SweetMetal2.bundle
rm -rf "$B" && mkdir -p "$B"
"$CC" -x objective-c++ -std=c++17 -fobjc-arc -O2 -g -Wall -Wno-deprecated-declarations -Wno-unused-function -bundle \
	-o "$B/HotMetal2" HotMetal2.mm NativeBridgeMetalFrontend.mm -x none "$BRIDGE" -Wl,-dead_strip -lc++ \
	-framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation 2>&1 |
	grep -v "was built for newer 'iOS' version" || true
[ -f "$B/HotMetal2" ] || exit 1
rm -rf out/HotMetal2.dSYM; mv "$B/HotMetal2.dSYM" out/ 2>/dev/null || dsymutil "$B/HotMetal2" -o out/HotMetal2.dSYM 2>/dev/null || true
strip -x "$B/HotMetal2"
cp Info.plist "$B/Info.plist"
cp "$TURNIP" "$B/libvulkan_freedreno.dylib"
strip -x "$B/libvulkan_freedreno.dylib"
codesign -f -s - "$B/libvulkan_freedreno.dylib" 2>/dev/null
codesign -f -s - "$B" 2>/dev/null
"$CC" -O2 -Wall -o out/m2vtest m2vtest.c "$BRIDGE" -Wl,-dead_strip 2>&1 | grep -v "was built for newer" || true
strip -x out/m2vtest && codesign -f -s - out/m2vtest 2>/dev/null
nm -m "$B/HotMetal2" | grep "weak external" | grep -v "dynamically looked up" || true
ls -la "$B"
