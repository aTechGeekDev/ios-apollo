#!/bin/sh
# Build Turnip (Mesa's Vulkan driver for Adreno) for iOS 16 arm64 with the darwin kernel backend.
#   userland/metal2/build-turnip-ios.sh [host]     (host: a macOS build of the same source, for checks on the Mac)
# (ios-apollo: IOS-26-Hot's tools/build-turnip-ios.sh, MIT, with this repository's paths; sources from fetch-sources.sh)
# Source: work/turnip/mesa = Mesa 85fda3b3 + UniXNU's patches/mesa (in their order, see
# reference-repos/UniXNU/scripts/data/adreno-compiler-inputs.json). The backend (tu_knl_darwin.cc) talks to
# the kernel's SweetAccelerator v2 user client through phone/turnip/NativeAdrenoABI.h.
# Output: work/turnip/build-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
T=${METAL2_WORK:-$ROOT/work/metal2}/turnip
target=${1:-ios}
export PATH=$T/venv/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$PATH
opts="-Dgallium-drivers= -Dvulkan-drivers=freedreno -Dfreedreno-kmds=darwin -Dtu-darwin-abi-dir=$HERE/turnip
 -Dplatforms=macos -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled
 -Dllvm=disabled -Dshared-glapi=disabled -Dxmlconfig=disabled -Dshader-cache=disabled -Dtools= -Dbuild-tests=false
 -Dvideo-codecs= -Dvulkan-layers= -Dlibunwind=disabled -Dlmsensors=disabled -Dvalgrind=disabled -Dexpat=disabled
 -Dzstd=disabled -Dbuildtype=release -Db_ndebug=true"
if [ "$target" = ios ]; then
	out=$T/build-ios
	sdk=$(xcrun --sdk iphoneos --show-sdk-path)
	cross=$T/ios16.cross
	flags="'-target', 'arm64-apple-ios16.0', '-isysroot', '$sdk', '-fstack-protector-strong'"
	cat > "$cross" <<EOF
[binaries]
c = '$(xcrun --sdk iphoneos --find clang)'
cpp = '$(xcrun --sdk iphoneos --find clang++)'
objc = '$(xcrun --sdk iphoneos --find clang)'
ar = '$(xcrun --sdk iphoneos --find ar)'
strip = '$(xcrun --sdk iphoneos --find strip)'
pkg-config = '/usr/bin/false'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = [$flags]
cpp_args = [$flags]
objc_args = [$flags]
c_link_args = [$flags]
cpp_link_args = [$flags]
objc_link_args = [$flags]
EOF
	cross_arg="--cross-file $cross"
	export CC=$(xcrun --sdk iphoneos --find clang) CXX=$(xcrun --sdk iphoneos --find clang++)
else
	out=$T/build-host
	cross_arg=""
	export CC=/usr/bin/clang CXX=/usr/bin/clang++
fi
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
if [ -f "$out/build.ninja" ]; then
	meson configure "$out" $opts >/dev/null
else
	meson setup "$out" "$T/mesa" --wrap-mode=nodownload $cross_arg $opts > "$T/configure-$target.log" 2>&1 ||
		{ tail -30 "$T/configure-$target.log"; exit 1; }
fi
ninja -C "$out" src/freedreno/vulkan/libvulkan_freedreno.dylib > "$T/build-$target.log" 2>&1 ||
	{ grep -E "error:|FAILED" "$T/build-$target.log" | head -30; exit 1; }
lib=$out/src/freedreno/vulkan/libvulkan_freedreno.dylib
nm -gU "$lib" | grep -q " T _vkGetInstanceProcAddr" || { echo "no vkGetInstanceProcAddr export" >&2; exit 1; }
if [ "$target" = ios ]; then
	# iOS 16 lacks symbols newer SDKs declare: weak imports resolve to NULL there (the strchrnul lesson)
	nm -m "$lib" | grep "weak external" || true
fi
ls -la "$lib"
