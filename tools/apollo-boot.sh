#!/usr/bin/env bash
# Download a CI kernel, build the boot image around it and boot the phone with it.
#
#   tools/apollo-boot.sh [RUN_ID]
#
# RUN_ID: an xnu.yml run (default: the newest one). A run still building is
# waited for. Then:
#   1. its xnu-kernel artifact -> xnu/out-RUN_ID/
#   2. shim/out/apollo.adt with the touch firmware (research/apollo-fw/) and
#      the GPU firmware and zap shader (research/apollo-gpu/)
#   3. shim/out/payload.bin with the boot-args below, then shim/build.sh ->
#      shim/out/shim-boot.img
#   4. fastboot boot (the phone in fastboot, or in Android/recovery with adb:
#      it is sent to fastboot first). Nothing is flashed.
# EXTRA_ARGS="..." adds boot-args (e.g. EXTRA_ARGS=ufslogsecs=1).
# Needs: gh (logged in), python3, aarch64-linux-gnu-gcc, mkbootimg, fastboot.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
args='debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0'
args+=' unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1'
args+=' launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetgpu=22 sweetgpukeep=1'
args+=${EXTRA_ARGS:+ $EXTRA_ARGS}
touch_fw=research/apollo-fw/novatek_nt36675_j3s_fw01.bin
gpu=research/apollo-gpu

die() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
	sed -n '2,17p' "$0"
	exit 0
fi
for tool in gh python3 aarch64-linux-gnu-gcc mkbootimg fastboot; do
	command -v "$tool" >/dev/null || die "$tool is not installed"
done
for f in "$touch_fw" "$gpu/a650_gmu.bin" "$gpu/a650_sqe.fw" "$gpu/a650_zap.mdt" "$gpu/a650_zap.b02"; do
	[ -f "$f" ] || die "missing $f"
done

# --- 1. the kernel
run=${1:-$(gh run list --workflow xnu.yml --limit 1 --json databaseId -q '.[0].databaseId')}
[ -n "$run" ] || die "no xnu.yml run found"
say "1/4 kernel build $run"
printf 'waiting for it to finish (if it is still building, about 8 minutes)...\n'
gh run watch "$run" --exit-status --interval 30 >/dev/null || die "kernel build $run failed: gh run view $run --log-failed"
out=xnu/out-$run
rm -rf "$out"
gh run download "$run" -n xnu-kernel -D "$out" || die "downloading the kernel of run $run failed"
kernel=$out/kernel.development.sweet
[ -f "$kernel" ] || die "no $kernel in the artifact (it has: $(ls "$out"))"
ls -l "$kernel"

# --- 2. the device tree
say "2/4 shim/out/apollo.adt"
mkdir -p shim/out
python3 tools/mkadt.py shim/out/apollo.adt --highmem --touch-fw "$touch_fw" \
	--gmu-fw "$gpu/a650_gmu.bin" --sqe-fw "$gpu/a650_sqe.fw" \
	--zap-mdt "$gpu/a650_zap.mdt" --zap-seg "$gpu/a650_zap.b02"

# --- 3. the boot image
say "3/4 shim/out/shim-boot.img"
printf 'boot-args: %s\n' "$args"
python3 tools/mkpayload.py "$kernel" shim/out/apollo.adt shim/out/payload.bin --cmdline "$args"
shim/build.sh ../shim/out/payload.bin >/dev/null
ls -l shim/out/shim-boot.img

# --- 4. boot
say "4/4 booting the phone"
if ! fastboot devices | grep -q fastboot; then
	adb reboot bootloader 2>/dev/null || true
	printf 'waiting for the phone in fastboot mode (volume down + power)...\n'
	until fastboot devices | grep -q fastboot; do sleep 2; done
fi
fastboot boot shim/out/shim-boot.img
say "booted kernel run $run"
printf 'If fastboot hangs on "Sending": hold volume down + power, then run: fastboot boot shim/out/shim-boot.img\n'
printf 'Log afterwards: fastboot boot recovery/recovery.img; tools/sweet-log-pull.sh logs/apollo-bootN.txt\n'
