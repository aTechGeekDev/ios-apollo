# project-BadApple

**Apple's iOS 16 running natively on the Xiaomi Mi 10T 5G / Mi 10T Pro 5G** (`apollo`, Snapdragon 865).

Apple's open-source XNU kernel (xnu-8796), patched for this phone, boots the **unmodified iOS 16.7.16 (20H392) system of the iPhone X**: launchd, the system daemons, the window server, SpringBoard and the stock apps. No emulator, and no Android underneath.

> [!WARNING]
> This is an experiment, not a daily-use phone OS. Most of Apple's security model is switched off, and installing the iOS root **erases Android's `userdata` partition**.

---

## Contents

1. [Progress](#progress)
2. [Being worked on now](#being-worked-on-now)
3. [How it boots](#how-it-boots)
4. [Getting started](#getting-started)
5. [Boot options](#boot-options)
6. [Firmware](#firmware)
7. [Repository layout](#repository-layout)
8. [Credits and license](#credits-and-license)

---

## Progress

**Overall: `██████░░░░` 65%** (updated 2026-10-30)

The percentages are rough estimates of how much of each part works on the phone today.

| Area | Progress | Status | Details |
| --- | --- | --- | --- |
| Boot to the iOS home screen | `██████████` 100% | ✅ Works | Stock bootloader → `fastboot boot` shim → XNU → iOS root in `userdata` → lock screen, home screen, Control Center, Settings, app switcher, home gesture, wallpapers, widgets |
| Touch | `█████████░` 95% | ✅ Works | Novatek NT36675 over SPI; its firmware is loaded at every boot |
| Buttons | `██████████` 100% | ✅ Works | Power, volume up, volume down |
| Wi-Fi | `█████████░` 95% | ✅ Works | QCA6390 with Linux's ath11k built into the kernel: scan, WPA2, saved networks, signal bars, on/off switch, internet in apps and Safari |
| Bluetooth | `█████████░` 90% | ✅ Works | QCA6390 over UART at 921600 baud: on/off, scan, pairing (kept across reboots), music to headphones (A2DP), HFP and AVRCP |
| Speakers | `████████░░` 85% | ✅ Works | Audio DSP + two CS35L41 amplifiers (drivers from hakios-apollo); an occasional crackle remains |
| Vibration | `███████░░░` 75% | ✅ Works | AW8697 motor: taps and ringtone patterns; duty-cycle limits protect the motor |
| GPU drawing | `███████░░░` 75% | ✅ Works | Adreno 650 runs Mesa (OpenGL ES 3.2, freedreno); iOS's CoreAnimation draws the whole UI on it through a bridge, blur and materials included |
| CPU | `████████░░` 85% | ✅ Works | All 8 cores (or a chosen set with `cpumask`); clocks follow the load with a 75 °C limit on the big cores (xnu 0153, boot 86) |
| Smoothness (goal: 60 fps) | `██████░░░░` 65% | 🚧 In progress | 19–54 fps measured (boot 86); the copy to the panel takes ~4 ms on its own thread; backboardd's GL work and a busy CPU are the main costs |
| Screen fit | `████████░░` 80% | 🧪 Testing | Full-panel mode: iOS draws 375×834 points, scaled by 0.96 onto the whole panel (boot 86); smoother, blended scaling for text and corners (xnu 0155) built, not yet booted |
| Backlight / brightness | `█████████░` 95% | ✅ Works | Brightness slider and Control Center drive the backlight (boot 86); smooth fade on lock/unlock |
| Heat / power use | `████░░░░░░` 40% | 🚧 In progress | Boot 86: cores stay 40–70% busy even with the screen off, so they never cool down; xnu 0155 adds a per-thread CPU report to find the cause and stops touch polling while dark |
| Microphone | `███░░░░░░░` 30% | ⏸️ Parked | The WCD938x codec comes up and iOS opens it, but the recording is silent |
| Battery / charging status | `░░░░░░░░░░` 0% | ❌ Not started |  |
| Sleep / standby | `░░░░░░░░░░` 0% | ❌ Not started | The panel goes dark when locked, but the phone never suspends |
| USB, cameras, cellular, sensors, GPS, fingerprint | `░░░░░░░░░░` 0% | ❌ Not started |  |

Status key: ✅ works on the phone · 🧪 built, waiting for a test boot · 🚧 in progress · ⏸️ parked · ❌ not started.

The detailed engineering log, with every boot's results, is [`NOTES.md`](NOTES.md).

---

## Being worked on now

| Patch | What it does | State |
| --- | --- | --- |
| **0156** | No tearing: frames are drawn off-screen and the display controller flips to them between refreshes (three buffers) | Built, not booted |
| **0155** | A per-thread CPU report every 10 s (`SWEET TOP`) to find what keeps the cores busy; blended screen scaling; touch polled slowly while the screen is off | Booted (boot 87): tearing and slow; its log is needed |
| Next | Fix whatever `SWEET TOP` shows burning idle CPU; let the GPU do the screen scaling (no CPU copy: cooler and faster); GPU clock scaling; the microphone | Planned |

---

## How it boots

```
Xiaomi bootloader (unlocked)
  └─ fastboot boot shim-boot.img        temporary: nothing is flashed to boot
     └─ shim                            loads XNU, an Apple Device Tree and boot options
        └─ XNU kernel + drivers         UFS storage, display, touch, GPU, Wi-Fi, Bluetooth, audio …
           └─ iOS root (HFS+)           in the userdata partition
              └─ launchd → daemons → backboardd + SpringBoard → apps
```

- **Nothing permanent is flashed** except the iOS root in `userdata`. Every boot is a temporary `fastboot boot`; rebooting without it starts Android's boot chain as usual.
- **There is no serial port.** The kernel keeps a 4 MiB log at the end of `userdata`, read back from recovery with `tools/sweet-log-pull.sh`.
- **The first boot of a new root** runs iOS's data migration once (an hour or more). Later boots take about a minute.

---

## Getting started

### What you need

| | |
| --- | --- |
| Phone | Mi 10T / 10T Pro (`apollo`) with an **unlocked bootloader** |
| Computer | Linux with `adb`, `fastboot`, `python3`, `aarch64-linux-gnu-gcc`, `mkbootimg`, and the GitHub CLI (`gh`) |
| GitHub | The kernel and the iOS programs build on GitHub Actions' macOS runners |
| Recovery | A recovery image with `adb` (OrangeFox works) at `recovery/recovery.img`, booted temporarily |

> [!CAUTION]
> Everything on `userdata` (Android's apps and files) is lost. Bootloaders, recovery, modem and `persist` are never touched.

### Step 1: back up the phone

From the temporary recovery, pull at least `persist`, `modemst1`, `modemst2`, `fsg`, `fsc`, `boot`, `dtbo` and `vbmeta`, and keep them out of git. Then extract the stock device tree for the shim:

```sh
python3 tools/unpack_bootv2.py backup/boot.img dtb/boot_unpacked
```

### Step 2: build the kernel and the iOS programs

```sh
python3 tools/validate-repo.py               # checks the patch series in seconds
gh workflow run xnu.yml                      # the kernel
gh workflow run userland.yml                 # Mesa, the CoreAnimation bridge, GPU tests
gh workflow run audio.yml                    # the audio plug-in
gh workflow run bt.yml                       # the Bluetooth library
gh run list -w xnu.yml                       # find the run ID, then:
gh run watch RUN_ID --exit-status
gh run download RUN_ID -n xnu-kernel -D xnu/out
gh run download USERLAND_RUN_ID -n sweet-userland -D sweet-userland
gh run download BT_RUN_ID -n sweet-bt -D sweet-bt
```

### Step 3: build and install the iOS root

`tools/build-ios-root.sh` downloads the iPhone X IPSW's disk images, builds the root, adds the programs and, after asking, writes it to `userdata`. Details are in [`userland/README.md`](userland/README.md).

### Step 4: get the firmware

The firmware comes from Xiaomi and Qualcomm and is never stored in git. See [Firmware](#firmware) for each file and the tool that fetches it.

### Step 5: build the boot image and boot

```sh
python3 tools/mkadt.py shim/out/apollo.adt --highmem \
    --touch-fw research/apollo-fw/novatek_nt36675_j3s_fw01.bin \
    --gmu-fw research/apollo-gpu/a650_gmu.bin --sqe-fw research/apollo-gpu/a650_sqe.fw \
    --zap-mdt research/apollo-gpu/a650_zap.mdt --zap-seg research/apollo-gpu/a650_zap.b02 \
    --wifi-fw research/apollo-wifi --bt-fw research/apollo-bt \
    --file /usr/local/lib/libsweet-gl.dylib=sweet-userland/lib/libsweet-gl.dylib \
    --file /usr/local/lib/libsweet-bt.dylib=sweet-bt/lib/libsweet-bt.dylib \
    --files-from tools/root-files/files.txt --files-from tools/root-files/bt-on.txt
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/apollo.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpumask=0xf1 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=60 sweetgpu=22 sweetgpukeep=1 sweetgpulevel=6 sweetwifi=12 apollo_audio=5 apollo_sound_gain=0 apollo_sound_below=80 apollo_mic=4 apollo_haptic=5 sweetbt=6 sweetinject=/usr/local/lib/libsweet-ca.dylib:backboardd;/usr/local/lib/libsweet-bt.dylib:bluetoothd,BlueTool sweetnull=backboardd,SpringBoard,bluetoothd,BlueTool,mediaserverd'
shim/build.sh ../shim/out/payload.bin        # → shim/out/shim-boot.img
fastboot boot shim/out/shim-boot.img
```

This is the full-featured setup: GPU-drawn UI at 60 Hz, Wi-Fi, Bluetooth, sound, vibration. For a minimal first boot, drop everything after `sweetfb_noconsole=1` and use `cpus=1` instead of `cpumask=0xf1`.

> [!NOTE]
> Sound, the audio plug-in and some firmware go onto the root with one-boot file lists (`--files-from …`). See [Firmware](#firmware) and `tools/root-files/`.

### Step 6: read the kernel log

```sh
fastboot boot recovery/recovery.img && adb wait-for-recovery
tools/sweet-log-pull.sh logs/boot.txt
adb reboot bootloader
```

`tools/sweet-crash.py` turns crash reports in the log into function names.

---

## Boot options

Boot options (boot-args) go in `--cmdline`. The most useful ones are below. Each driver's source in `xnu/patches/` documents the rest.

### Core

| Option | Effect |
| --- | --- |
| `cpus=N` | Start N cores (`cpus=1` is the safe fallback) |
| `cpumask=M` | Start the cores in mask M instead (bit n = core n: 0–3 small, 4–6 big, 7 prime). `0xf1` = core 0 + the four big cores. Not together with `cpus=` |
| `ufslogsecs=1` | Write the log to storage every second (for hangs) |
| `sweetnull=A,B,…` | Copy what these programs print into the kernel log |
| `sweettouch=0`, `sweetkeys=0` | Turn off touch or the buttons |

### Display and backlight

| Option | Effect |
| --- | --- |
| `sweetfb_hz=N` | Screen refreshes a second (default 10; use 60) |
| `sweetfb_noconsole=1` | Don't draw kernel text over the UI |
| `sweetfb_fit=0` | Crop the iPhone X picture instead of scaling it to fit |
| `sweetfb_height=2502` | Full-panel mode (0152): build the device tree with `mkadt.py --display-height 2502` and add `--files-from tools/root-files/mgcache-reset.txt` on the first boot |
| `sweetfb_native=1` | iOS draws at 1080×2400 1:1 (360×800 points; iOS shows a red status bar). Needs `mkadt.py --native-display` |
| `sweetfb_stats=N` | Every N s, a `SWEET FB` line with frames a second and copy time (default 10) |
| `sweetflip=0` | Copy each frame into the shown buffer instead of page flipping (0156; tears) |
| `sweetfb_smooth=0` | Nearest-pixel scaling instead of the blended (bilinear) default (0155): less CPU, rougher text |
| `apollo_backlight=P` | Backlight: `0` leave it alone, `1`–`100` set a level, absent = keep the bootloader's level |
| `apollo_backlight_fade_ms=N` | Lock/unlock fade length (default 300) |
| `sweetbacklight=0` | Don't offer the backlight to iOS (the brightness slider does nothing) |

### CPU, memory and heat

| Option | Effect |
| --- | --- |
| `sweetcpugov=0` | Pin every core at top speed (the old way) instead of following the load |
| `sweetcpufreq=N` | Cap the CPU clock at N MHz |
| `sweetthermal=T` | Slow the big cores while the hottest core is over T °C (default 75; 0 = no limit) |
| `sweetcpustats=N` | Every N s, a `SWEET CPUFREQ` line: clocks, load, temperatures (default 10) |
| `sweettop=0` | No `SWEET TOP` line (the 8 threads that used the most CPU, with the stats line; 0155) |
| `sweetddr=N` | Memory bus: `0` leave it alone, `1` follow the load (default), `2` always at top |
| `sweetddrlow=V` | The memory bus's idle level (default `0x800`); raise it if the screen flickers when idle |

### GPU

| Option | Effect |
| --- | --- |
| `sweetgpu=22 sweetgpukeep=1` | Bring the GPU up and keep it on for iOS |
| `sweetgpulevel=N` | GPU speed: `1` = 305 MHz (default) … `6` = 587 MHz (best frame rate) |
| `sweetinject=/usr/local/lib/libsweet-ca.dylib:backboardd` | Load the CoreAnimation bridge so iOS draws on the GPU |
| `sweetgl=0` | Keep iOS's software renderer |

### Wi-Fi and Bluetooth

| Option | Effect |
| --- | --- |
| `sweetwifi=12` | Wi-Fi for iOS (1–11 are bring-up test steps) |
| `sweetwifimac=aa:bb:cc:dd:ee:ff` | Fixed Wi-Fi address (default: random each boot) |
| `sweetbt=6` | Bluetooth for iOS (1–5 are test steps); needs the `bt-on.txt` list and the `libsweet-bt` injection |

### Sound, vibration and microphone

| Option | Effect |
| --- | --- |
| `apollo_audio=5` | Speakers for iOS (1–4 are test steps); needs the audio plug-in on the root once (`--files-from tools/root-files/audio-on.txt`) |
| `apollo_sound_below=N` | Volume ceiling below Android's level, in eighths of a dB (default 160 = 20 dB) |
| `apollo_sound_gain=N` | Pre-gain of the limiter, in eighths of a dB (default 96; `0` avoids crackle) |
| `apollo_haptic=5` | Vibration motor for iOS (1–4 are test steps) |
| `apollo_haptic_max_ms=N` | Longest single vibration (default 2000) |
| `apollo_mic=4` | Microphone for iOS (1–3 are test steps); `apollo_mic_path=0` uses the plain path without Xiaomi's tuning |

---

## Firmware

None of these files are in git. Each tool runs with the phone in the temporary recovery.

| Part | Files | How to get them | Goes to |
| --- | --- | --- | --- |
| Touch | `novatek_nt36675_j3s_fw01.bin` | Xiaomi's kernel source: `curl` the `.ihex` from `MiCode/Xiaomi_Kernel_OpenSource` (branch `apollo-q-oss`, `firmware/`), then `objcopy -I ihex -O binary` | `research/apollo-fw/` |
| GPU | `a650_gmu.bin`, `a650_sqe.fw`, `a650_zap.*` | `tools/pull-gpu-fw.sh` | `research/apollo-gpu/` |
| Wi-Fi | `amss20.bin`, `m3.bin`, `regdb.bin`, `bd_j3sgl.elf` | `tools/pull-wifi-fw.sh` | `research/apollo-wifi/` |
| Bluetooth | `htbtfw20.tlv`, `htnv20.bin` | `tools/pull-bt-fw.sh` | `research/apollo-bt/` |
| Audio DSP | `adsp.mdt`, `adsp.b00` … | `tools/pull-audio-fw.sh` (writes a one-boot file list) | onto the root |
| Vibration and microphone tuning | `aw8697_haptic.bin`, the ACDB-derived `mic_*.bin` | `tools/pull-mic-haptic-fw.sh` (writes a one-boot file list) | onto the root |

---

## Repository layout

| Path | What's inside |
| --- | --- |
| `xnu/patches/` | The kernel: patches 0001–0156 on Apple's xnu-8796, applied in order by CI |
| `shim/` | The boot shim, packed as an Android boot image |
| `wifi/` | The Linux compatibility layer the Wi-Fi driver (ath11k) is built on |
| `userland/` | Programs for the phone: Mesa, the CoreAnimation bridge, the audio plug-in, the Bluetooth library, GPU tests ([details](userland/README.md)) |
| `tools/` | Device tree builder, boot packer, iOS root builder, firmware pullers, log and crash tools |
| `tools/root-files/` | One-boot file lists that add, move or remove files on the iOS root |
| `.github/workflows/` | CI: the kernel, the iOS programs, and an analysis job for iOS's system libraries (nothing from Apple is stored) |
| `NOTES.md` | The engineering log: every boot's result, current state, next steps |

`sweet` / `SWEET` is the kernel's internal machine name; you'll see it in file, tool and option names.

Kept out of git: partition backups, device dumps, firmware, Apple's files, serial numbers and logs.

---

## Credits and license

Built on:
- **Apple's open-source releases:** xnu, IOHIDFamily, libpthread, hfs.
- **[hakios-apollo](https://github.com/enesuzun2002/hakios-apollo):** the Mi 10T's sound, microphone, vibration and backlight drivers, and the audio plug-in.
- **[HackiOS](https://github.com/oosexgang/hackios-xnu-kernel):** the Mesa and CoreAnimation approach and the Wi-Fi layer.
  - Its [Xiaomi Mi 10 port](https://github.com/JopangJovan/hackios-xnu-kernel-umi): the QCA6390 bring-up.
- **ios-spes and ios-sailfish:** the brightness service design.
- **Build and analysis tools:** [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build), [ipsw](https://github.com/blacktop/ipsw).
- **Graphics:** [Mesa](https://mesa3d.org).
- **Other code:** [BearSSL](https://bearssl.org); Linux's ath11k driver and FreeBSD's LinuxKPI (fetched at build time, not kept here).
- **Phone software:** Xiaomi's published kernel source; [OrangeFox Recovery](https://orangefox.download).

iOS itself belongs to Apple and is not distributed here.

MIT License, see [`LICENSE`](LICENSE).
