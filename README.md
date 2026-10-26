# project-BadApple

**Apple's iOS 16 on the Xiaomi Mi 10T 5G / Mi 10T Pro 5G (`apollo`, Snapdragon 865).**

Apple's open-source XNU kernel (xnu-8796), patched for the phone, boots the **unmodified iOS 16.7.16 (20H392) userland of the iPhone X**: launchd, the system daemons, backboardd, SpringBoard and the stock apps. No emulator, no Android underneath.

> Experimental, not a daily-use OS. Apple's security model is mostly switched off, and installing the iOS root **erases Android's `userdata` partition**.

## Status (2026-10-25)

| | |
| --- | --- |
| Boot | Stock bootloader → `fastboot boot` shim → XNU → iOS from `userdata` → **lock screen**, home screen, Control Center, Settings, app switcher, home gesture; **wallpapers and widgets** (app extensions registered, 2026-10-26) |
| CPU | All 8 cores, clocked up (1804 / 2419 / 2841 MHz) |
| Touch | Working (Novatek NT36675 over SPI, firmware loaded at every boot) |
| Buttons | Power, volume up, volume down |
| Display | iOS drawn in software and copied to the panel |
| GPU | Adreno 650 up. **Mesa draws with it** (OpenGL ES 3.2, freedreno), and iOS's own renderer (CoreAnimation in backboardd) now draws on it through the bridge: the boot Apple logo appears with it (2026-10-26). Lock screen and home screen on the GPU: next |
| Not yet | Display power, USB networking, battery, Wi-Fi, Bluetooth, audio, cameras, cellular |

The first boot of a fresh root runs iOS data migration once (an hour or more); later boots are quick. Day-to-day progress and the next steps are in [`NOTES.md`](NOTES.md).

## How it boots

```
Xiaomi bootloader (unlocked)
  -> fastboot boot shim-boot.img     (temporary; nothing is flashed to boot)
     -> shim: loads XNU + Apple Device Tree + boot-args
        -> XNU -> UFS driver -> iOS root (HFS+) in userdata
           -> launchd -> daemons -> backboardd + SpringBoard
```

There is no serial port. The kernel draws its console on the bootloader's framebuffer and keeps a 4 MiB log at the end of `userdata`, readable from recovery.

## Build and boot

You need an **unlocked** phone, a Linux PC and a GitHub account (the kernel builds on GitHub's macOS runners). **Everything on `userdata` is lost.** Bootloaders, recovery, modem and persist are never touched.

**0. Back up the phone.** From a temporary recovery with adb, pull at least `persist`, `modemst1`, `modemst2`, `fsg`, `fsc`, `boot`, `dtbo` and `vbmeta`, and keep them out of git. Then extract the stock DTB for the shim:

```sh
python3 tools/unpack_bootv2.py backup/boot.img dtb/boot_unpacked
```

**1. Build the kernel and the phone programs** (on GitHub Actions):

```sh
python3 tools/validate-repo.py                 # patch-series check, seconds
gh workflow run xnu.yml                        # the kernel
gh workflow run userland.yml                   # GPU tests, Mesa, CoreAnimation bridge
gh run download KERNEL_RUN_ID -n xnu-kernel -D xnu/out
gh run download USERLAND_RUN_ID -n sweet-userland -D sweet-userland
```

**2. Build and flash the iOS root.** `tools/build-ios-root.sh` downloads the iPhone X IPSW's disk images, builds the root, adds the programs and (after asking) flashes it. Details: [`userland/README.md`](userland/README.md).

**3. Get the firmware** (not in git). Touch firmware, from Xiaomi's kernel source:

```sh
mkdir -p research/apollo-fw && cd research/apollo-fw
curl -LO https://raw.githubusercontent.com/MiCode/Xiaomi_Kernel_OpenSource/apollo-q-oss/firmware/novatek_nt36675_j3s_fw01.bin.ihex
objcopy -I ihex -O binary novatek_nt36675_j3s_fw01.bin.ihex novatek_nt36675_j3s_fw01.bin
cd ../..
```

GPU firmware, from the phone (in recovery): `tools/pull-gpu-fw.sh`.

**4. Build the boot image** (needs `aarch64-linux-gnu-gcc` and `mkbootimg`):

```sh
python3 tools/mkadt.py shim/out/apollo.adt --highmem \
    --touch-fw research/apollo-fw/novatek_nt36675_j3s_fw01.bin \
    --gmu-fw research/apollo-gpu/a650_gmu.bin --sqe-fw research/apollo-gpu/a650_sqe.fw \
    --zap-mdt research/apollo-gpu/a650_zap.mdt --zap-seg research/apollo-gpu/a650_zap.b02
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/apollo.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1'
shim/build.sh ../shim/out/payload.bin          # -> shim/out/shim-boot.img
```

**5. Boot:**

```sh
fastboot boot shim/out/shim-boot.img
```

**6. Read the kernel log:**

```sh
fastboot boot recovery/recovery.img            # temporary recovery with adb
tools/sweet-log-pull.sh logs/boot.txt
adb reboot bootloader
```

`tools/sweet-crash.py` turns crash reports in the log into function names.

## Useful boot-args

| Boot-arg | Effect |
| --- | --- |
| `cpus=N` | Cores to start (`cpus=1` is the safe fallback) |
| `sweetfb_noconsole=1` | Don't draw kernel text over the GUI |
| `ufslogsecs=1` | Flush the log every second (for hangs) |
| `sweettouch=0`, `sweetkeys=0` | Turn off touch or buttons |
| `sweetcpufreq=N` | Cap the CPU clock at N MHz (0 = leave as the bootloader set it) |
| `sweetgpu=22 sweetgpukeep=1` | Bring up the GPU and keep it on for programs |
| `sweetnull=A,B,...` | Copy what these programs print into the kernel log |
| `sweetinject=/usr/local/lib/libsweet-ca.dylib:backboardd` | Load the CoreAnimation bridge (GPU drawing) into the window server |
| `sweetgl=0` | Keep CoreAnimation's software renderer |
| `sweetwifi=N` | Wi-Fi bring-up steps 1..7 (QCA6390: power, PCIe link, SMMU, firmware boot, QRTR); needs `mkadt.py --wifi-fw` from step 4 |

The other boot-args are described in their drivers' sources in `xnu/patches/` and in `NOTES.md`.

## Repository

| Path | What |
| --- | --- |
| `shim/` | Boot shim, packed as an Android boot image |
| `xnu/patches/` | The kernel patches (0001–0126), applied in order by CI |
| `userland/` | Programs and libraries for the phone: GPU tests, Mesa, the CoreAnimation bridge |
| `tools/` | Device tree builder, payload packer, iOS root builder, log and crash tools |
| `NOTES.md` | Engineering log and current handoff |

`sweet` / `SWEET` is the kernel's internal machine-config name; it shows up in file, tool and boot-arg names.

Not in git: partition backups, device trees, recovery images, firmware, Apple's files and logs (device serials, calibration data, copyrighted files).

## Credits

Apple's open-source releases (xnu, IOHIDFamily, libpthread, hfs), [BearSSL](https://bearssl.org), [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build), [ipsw](https://github.com/blacktop/ipsw), [Mesa](https://mesa3d.org), [HackiOS](https://github.com/oosexgang/hackios-xnu-kernel) (the Mesa and CoreAnimation approach), Xiaomi's published kernel source and [OrangeFox Recovery](https://orangefox.download). iOS itself is Apple's and is not distributed here.

MIT License, see [`LICENSE`](LICENSE).
