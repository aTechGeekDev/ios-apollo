# project-BadApple

**Apple's iOS 16 on the Xiaomi Mi 10T 5G / Mi 10T Pro 5G (`apollo`, Snapdragon 865).**

Apple's open-source XNU kernel (xnu-8796), patched for the phone, boots the **unmodified iOS 16.7.16 (20H392) userland of the iPhone X**: launchd, the system daemons, backboardd, SpringBoard and the stock apps. No emulator, no Android underneath.

> Experimental, not a daily-use OS. Apple's security model is mostly switched off, and installing the iOS root **erases Android's `userdata` partition**.

## Status (2026-10-28)

| | |
| --- | --- |
| Boot | Stock bootloader → `fastboot boot` shim → XNU → iOS from `userdata` → **lock screen**, home screen, Control Center, Settings, app switcher, home gesture; **wallpapers and widgets** (app extensions registered, 2026-10-26) |
| CPU | All 8 cores, clocked up (1804 / 2419 / 2841 MHz) |
| Touch | Working (Novatek NT36675 over SPI, firmware loaded at every boot) |
| Buttons | Power, volume up, volume down |
| Display | iOS drawn by the GPU and copied to the panel (up to 60 frames a second with `sweetfb_hz=60`) |
| GPU | Adreno 650 up. **Mesa draws with it** (OpenGL ES 3.2, freedreno), and iOS's own renderer (CoreAnimation in backboardd) draws **the whole GUI** on it through the bridge: lock screen, home screen, keyboard, and the blur of Control Center, Spotlight and the App Library (2026-10-26). A backboardd crash on some image uploads has a fix built, not yet tested |
| Wi-Fi | **Working** (QCA6390, Linux's ath11k built into the kernel, `sweetwifi=12`): iOS's Wi-Fi settings list the networks around; WPA2 networks join from Settings or Control Center; passwords are kept and saved networks join by themselves after a reboot; the signal-strength icon is right; the Wi-Fi switch turns the radio off and on; the internet works in apps and Safari (2026-10-28) |
| Bluetooth | **The radio works in the kernel** (QCA6390 over the UART of serial engine 6, the phone's own firmware, `sweetbt=5`: it hears the LE devices around, 2026-10-28). iOS's Bluetooth (bluetoothd, Settings) is the next step |
| Audio | **iOS's sound plays through both speakers** (2026-10-28): the audio DSP started from the phone's own firmware, the tertiary TDM interface and the two CS35L41 amplifiers (kernel drivers of [hakios-apollo](https://github.com/enesuzun2002/hakios-apollo)), and its audio-server plug-in (`userland/audio/`), `apollo_audio=5`; 20 dB under Android's level by default (`apollo_sound_below=`). No microphones or vibration yet |
| Not yet | Display power, USB networking, battery, Bluetooth in iOS, microphones, vibration, cameras, cellular |

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
gh run watch KERNEL_RUN_ID --exit-status     # wait for it (gh run list -w xnu.yml shows the ID)
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

GPU, Wi-Fi and Bluetooth firmware, from the phone (in recovery): `tools/pull-gpu-fw.sh`, `tools/pull-wifi-fw.sh` and `tools/pull-bt-fw.sh` (into `research/apollo-gpu/`, `research/apollo-wifi/` and `research/apollo-bt/`; `mkadt.py --bt-fw research/apollo-bt`). The audio DSP's comes out of the Wi-Fi pull's modem copy: `tools/pull-audio-fw.sh`.

**4. Build the boot image** (needs `aarch64-linux-gnu-gcc` and `mkbootimg`):

```sh
python3 tools/mkadt.py shim/out/apollo.adt --highmem \
    --touch-fw research/apollo-fw/novatek_nt36675_j3s_fw01.bin \
    --gmu-fw research/apollo-gpu/a650_gmu.bin --sqe-fw research/apollo-gpu/a650_sqe.fw \
    --zap-mdt research/apollo-gpu/a650_zap.mdt --zap-seg research/apollo-gpu/a650_zap.b02 \
    --wifi-fw research/apollo-wifi
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/apollo.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1'
shim/build.sh ../shim/out/payload.bin          # -> shim/out/shim-boot.img
```

For the GPU-drawn GUI add `sweetfb_hz=60 sweetgpu=22 sweetgpukeep=1 sweetinject=/usr/local/lib/libsweet-ca.dylib:backboardd` to `--cmdline` (the bridge library must be on the root), and for the Wi-Fi test `sweetwifi=11`.

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
| `sweetfb_hz=N` | How often the screen is updated (default 10; 60 for smooth animation) |
| `ufslogsecs=1` | Flush the log every second (for hangs) |
| `sweettouch=0`, `sweetkeys=0` | Turn off touch or buttons |
| `sweetcpufreq=N` | Cap the CPU clock at N MHz (0 = leave as the bootloader set it) |
| `sweetgpu=22 sweetgpukeep=1` | Bring up the GPU and keep it on for programs |
| `sweetnull=A,B,...` | Copy what these programs print into the kernel log |
| `sweetinject=/usr/local/lib/libsweet-ca.dylib:backboardd` | Load the CoreAnimation bridge (GPU drawing) into the window server |
| `sweetgl=0` | Keep CoreAnimation's software renderer |
| `sweetwifi=N` | Wi-Fi bring-up steps 1..12 (QCA6390: power, PCIe link, SMMU, firmware boot, QRTR, firmware handshake, board data + M3, calibration; 11 = Linux's ath11k driver brings the radio up, scans, and goes down again; 12 = the driver stays up as `en0` for iOS's Wi-Fi); needs `mkadt.py --wifi-fw research/apollo-wifi` from step 4 |
| `sweetwifimac=aa:bb:cc:dd:ee:ff` | the radio's MAC address for `sweetwifi=11/12` (without it, a random locally administered one per boot) |
| `sweetbt=N` | Bluetooth bring-up steps 1..6 (QCA6390 over the UART of serial engine 6: 1-3 clocks, pins, UART loopback; 4 the chip's ROM answers; 5 firmware, then an LE scan and a classic inquiry in the kernel; 6 the radio stays up for iOS's bluetoothd); needs `mkadt.py --bt-fw research/apollo-bt` from step 5 |
| `apollo_audio=N` / `apollo_adsp_step=N` | the sound (xnu 0139: the drivers of the Mi 10T port [hakios-apollo](https://github.com/enesuzun2002/hakios-apollo)): 1 the audio DSP up; 2 the tertiary TDM port; 3 a test tone into a stream, amplifiers off; 4 the tone through the CS35L41 amplifiers, 20 dB under Android's level (`apollo_sound_below=` eighths of a dB, `apollo_sound_secs=`); 5 what iOS plays, through `/dev/apollo-audio`: needs the audio server's plug-in on the root once (`mkadt.py --files-from tools/root-files/audio-on.txt` with the `sweet-audio` artifact of `.github/workflows/audio.yml`; xnu 0140 moves iOS's VirtualAudio.plugin back for it; undo: `audio-off.txt`) and `mediaserverd` in `sweetnull` for the plug-in's own lines. `apollo_adsp_step=N`: the DSP's steps 1..N with a log of each. Needs the DSP's firmware on the root once: `tools/pull-audio-fw.sh` and `mkadt.py --files-from research/apollo-audio/files-adsp.txt` for one boot |

The other boot-args are described in their drivers' sources in `xnu/patches/` and in `NOTES.md`.

## Repository

| Path | What |
| --- | --- |
| `shim/` | Boot shim, packed as an Android boot image |
| `xnu/patches/` | The kernel patches (0001–0140), applied in order by CI |
| `wifi/` | HackiOS's Linux layer for the Wi-Fi driver; CI builds Linux's ath11k on it and links it into the kernel |
| `userland/` | Programs and libraries for the phone: GPU tests, Mesa, the CoreAnimation bridge |
| `tools/` | Device tree builder, payload packer, iOS root builder, log and crash tools |
| `NOTES.md` | Engineering log and current handoff |

`sweet` / `SWEET` is the kernel's internal machine-config name; it shows up in file, tool and boot-arg names.

Not in git: partition backups, device trees, recovery images, firmware, Apple's files and logs (device serials, calibration data, copyrighted files).

## Credits

Apple's open-source releases (xnu, IOHIDFamily, libpthread, hfs), [BearSSL](https://bearssl.org), [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build), [ipsw](https://github.com/blacktop/ipsw), [Mesa](https://mesa3d.org), [hakios-apollo](https://github.com/enesuzun2002/hakios-apollo) (the Mi 10T's sound), [HackiOS](https://github.com/oosexgang/hackios-xnu-kernel) (the Mesa and CoreAnimation approach, the Wi-Fi layer) and its [Xiaomi Mi 10 port](https://github.com/JopangJovan/hackios-xnu-kernel-umi) (the QCA6390 bring-up), Linux's ath11k driver and FreeBSD's LinuxKPI (fetched when CI builds the kernel, not kept here), Xiaomi's published kernel source and [OrangeFox Recovery](https://orangefox.download). iOS itself is Apple's and is not distributed here.

MIT License, see [`LICENSE`](LICENSE).
