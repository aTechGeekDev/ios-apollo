#!/bin/bash
# Build Mesa for the phone: libOSMesa.8.dylib, OpenGL ES 2/3 (and desktop GL) in one library,
# drawing on the Adreno 650 through the kernel's SweetGPU service (freedreno), or in software
# (softpipe) when there is no GPU or OSMESA_SOFTWARE=1. On macOS with Xcode (the userland
# workflow runs it on macos-14):
#
#   userland/mesa/build.sh OUT
#
# OUT/lib/libOSMesa.8.dylib     install name /usr/local/lib/libOSMesa.8.dylib, ad hoc signed
#                               (programs declare what they use of it: userland/gl-test)
# MESA_WORK/meta/gl.xml, exported-gl.txt
#                               the Khronos registry Mesa has and the gl* functions the library
#                               exports: for userland/ca-bridge/mkeagl.py (not for the phone)
#
# Mesa itself is not in the repository: the pinned release is fetched and checked, then
# patches/*.patch go on top and sweet-drm/ (a stand-in for libdrm that talks to SweetGPU) is put
# in as src/sweet-drm. The patches and the build options follow HackiOS's tools/mk-mesa.sh
# (OOSEX GANG, MIT); see each patch's header.
# Needs: Xcode (iPhoneOS SDK), python3, bison >= 2.7 (Homebrew's), flex; meson, ninja, mako,
# pyyaml and packaging are installed into a private python environment.
set -euo pipefail

VERSION=25.0.7
SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
here=$(cd "$(dirname "$0")" && pwd)
out=$(mkdir -p "${1:?usage: build.sh OUT}" && cd "$1" && pwd)
work=${MESA_WORK:-$PWD/mesa-work}
mkdir -p "$work"
cd "$work"

[ -f mesa-$VERSION.tar.xz ] || curl -sSL --fail -o mesa-$VERSION.tar.xz https://archive.mesa3d.org/mesa-$VERSION.tar.xz
echo "$SHA256  mesa-$VERSION.tar.xz" | shasum -a 256 -c --quiet
rm -rf mesa-$VERSION build
tar xJf mesa-$VERSION.tar.xz
for p in "$here"/patches/*.patch; do
	echo "patch: ${p##*/}"
	patch -s --no-backup-if-mismatch -d mesa-$VERSION -p1 < "$p"
done
cp -R "$here/sweet-drm" mesa-$VERSION/src/sweet-drm

if [ ! -x venv/bin/python3 ]; then
	python3 -m venv venv
	venv/bin/pip -q install meson ninja mako pyyaml packaging
fi
export PATH=$work/venv/bin:$PATH
if command -v brew >/dev/null && [ -d "$(brew --prefix bison 2>/dev/null)/bin" ]; then
	export PATH=$(brew --prefix bison)/bin:$PATH       # macOS's own bison is 2.3
fi
bison --version | head -1

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
CXX=$(xcrun --sdk iphoneos -f clang++)
cat > cross.ini <<INI
[binaries]
c = ['$CC', '-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK']
cpp = ['$CXX', '-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK']
objc = ['$CC', '-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK']
ar = '$(xcrun -f ar)'
strip = '$(xcrun -f strip)'
pkg-config = 'false'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
INI

meson setup build mesa-$VERSION --cross-file cross.ini --wrap-mode=nofallback \
	--prefix=/usr/local --libdir=lib --buildtype=release -Db_ndebug=true \
	-Dplatforms= -Dgallium-drivers=softpipe,freedreno -Dfreedreno-kmds=msm -Dvulkan-drivers= \
	-Dglx=disabled -Degl=disabled -Dgbm=disabled -Dosmesa=true -Dllvm=disabled -Dshared-glapi=enabled \
	-Dgles1=disabled -Dgles2=enabled -Dopengl=true -Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled \
	-Dshader-cache=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dglvnd=disabled -Dvideo-codecs= \
	-Dtools= -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dgallium-xa=disabled -Dlmsensors=disabled \
	-Dbuild-tests=false
ninja -C build src/gallium/targets/osmesa/libOSMesa.8.dylib

mkdir -p "$out/lib"
lib=$out/lib/libOSMesa.8.dylib
xcrun strip -x -o "$lib" build/src/gallium/targets/osmesa/libOSMesa.8.dylib
xcrun install_name_tool -id /usr/local/lib/libOSMesa.8.dylib "$lib"
codesign -s - -f "$lib"
mkdir -p "$work/meta"
cp mesa-$VERSION/src/mapi/glapi/registry/gl.xml "$work/meta/gl.xml"
nm -gU "$lib" | awk '$3 ~ /^_gl/ { print substr($3, 2) }' > "$work/meta/exported-gl.txt"
echo "build.sh: Mesa $VERSION: $lib, $(stat -f %z "$lib") bytes, $(nm -gU "$lib" | grep -c ' _gl') gl* functions," \
	"SweetGPU named $(strings "$lib" | grep -c '^SweetGPU$') time(s)"
