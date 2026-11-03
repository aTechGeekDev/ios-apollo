#!/bin/sh
# Build the native Metal bridge (phone/metal2/bridge/NativeMetalBridge.rs: UniXNU's bridge over the metal2vulkan
# runtime, MIT) as a static library for iOS 16 arm64.
#   userland/metal2/build-m2v-bridge.sh [host]
# (ios-apollo: IOS-26-Hot's tools/build-m2v-bridge.sh, MIT, with this repository's paths; sources from fetch-sources.sh)
# Source: work/metal2vulkan = github.com/steelbrain/metal2vulkan 720ef1ce (UniXNU's pin) + phone/metal2/bridge/patches.
# Output: work/m2v-bridge/<target>/libnative_metal_bridge.a
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SRC=${METAL2_WORK:-$ROOT/work/metal2}/metal2vulkan
OUT=${METAL2_WORK:-$ROOT/work/metal2}/m2v-bridge
target=${1:-ios}
mkdir -p "$OUT"
LLVM_AS=/opt/homebrew/opt/llvm/bin/llvm-as
"$LLVM_AS" -o "$OUT/runtime_examples.air" "$SRC/crates/metal2vulkan-validation/fixtures/public/examples/runtime_examples.ll"
"$LLVM_AS" -o "$OUT/function_constant.air" "$SRC/crates/metal2vulkan-validation/fixtures/public/kernel_function_constant_gate_fold.ll"
cat > "$OUT/Cargo.toml" <<EOF
[package]
name = "native-metal-bridge"
version = "0.1.0"
edition = "2024"
rust-version = "1.98"
[workspace]
[lib]
crate-type = ["staticlib"]
path = "$HERE/metal2/bridge/NativeMetalBridge.rs"
[dependencies]
metal2vulkan = { path = "$SRC/crates/metal2vulkan", features = ["ash"] }
metal2vulkan-runtime = { path = "$SRC/crates/metal2vulkan-runtime" }
libc = "0.2"
sha2 = { version = "0.10", features = ["asm"] }
[profile.release]
panic = "unwind"
debug = 1
EOF
if [ "$target" = ios ]; then triple=aarch64-apple-ios; else triple=aarch64-apple-darwin; fi
# CI touches work/metal2vulkan back to 2025-01-01 while restoring a newer work/m2v-bridge/target cache via restore-keys;
# invalidate cached metal2vulkan artifacts whenever the applied patch set changes while keeping 3rd-party crates cached.
PATCH_HASH=$(cat "$HERE"/metal2/bridge/patches/*.patch 2>/dev/null | shasum -a 256 | awk '{print $1}')
if [ -d "$OUT/target" ] && [ "$(cat "$OUT/target/.patches.sha256" 2>/dev/null || true)" != "$PATCH_HASH" ]; then
	cargo +1.98.0 clean --manifest-path "$OUT/Cargo.toml" --target-dir "$OUT/target" --target "$triple" --release \
		-p metal2vulkan -p metal2vulkan-runtime -p native-metal-bridge 2>/dev/null || true
	rm -rf "$OUT/target/$triple/release/deps/libmetal2vulkan"* \
		"$OUT/target/$triple/release/deps/metal2vulkan"* \
		"$OUT/target/$triple/release/.fingerprint/metal2vulkan"* \
		"$OUT/target/release/.fingerprint/metal2vulkan"* \
		"$OUT/target/$triple/release/deps/libnative_metal_bridge"* \
		"$OUT/target/$triple/release/.fingerprint/native-metal-bridge"*
fi
NMB_FIXTURE_AIR=$OUT/runtime_examples.air NMB_FC_AIR=$OUT/function_constant.air IPHONEOS_DEPLOYMENT_TARGET=16.0 \
	MACOSX_DEPLOYMENT_TARGET=14.0 cargo +1.98.0 build --release --manifest-path "$OUT/Cargo.toml" --target $triple \
	--target-dir "$OUT/target" > "$OUT/build-$target.log" 2>&1 || { grep -E "^(error|warning: unused)" -A6 "$OUT/build-$target.log" | head -60; exit 1; }
printf '%s\n' "$PATCH_HASH" > "$OUT/target/.patches.sha256"
mkdir -p "$OUT/$target"
cp "$OUT/target/$triple/release/libnative_metal_bridge.a" "$OUT/$target/"
ls -la "$OUT/$target/libnative_metal_bridge.a"
