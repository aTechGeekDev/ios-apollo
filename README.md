# ios-apollo

**Porting ios-sweet (Apple's iOS 16 on a Snapdragon Android phone) to the Xiaomi Mi 10T 5G / Mi 10T Pro 5G (`apollo`, Qualcomm SM8250 / Snapdragon 865).**

This repository is a fork of **ios-sweet**. ios-sweet builds Apple's open-source XNU kernel (xnu-8796, the iOS 16 generation) for the Redmi Note 10 Pro (`sweet`, SM7150), then runs the **unmodified iOS 16.7.16 (20H392) userland of the iPhone X** on it: launchd, the system daemons, backboardd, SpringBoard and the stock apps. On `sweet` it reaches the iOS home screen with touch, buttons, all eight cores and USB networking.

This fork moves that work to `apollo`. As of **2026-10-24** the Mi 10T boots XNU on six cores and reaches **iOS Setup**, and **touch, power, volume-up and volume-down all work**. The kernel loads the touch chip's firmware over SPI at every boot. The section [apollo port status](#apollo-port-status) has the details.

> Experimental bring-up, not a usable phone OS. Apple's security model is mostly switched off, and installing the iOS root **erases Android's `userdata` partition**.

## apollo port status

| Area | State on apollo |
| --- | --- |
| Boot | Stock bootloader → `fastboot boot` shim → XNU → iOS 16.7 userland from `userdata` → **Setup (Siri page) on screen**. Kernel log readable from recovery |
| Boot shim | GIC, PSCI, IMEM restart reason and timer PPIs retargeted to SM8250 (virtual timer INTID 27, physical timer INTID 30, restart reason at `0x146bf65c`) |
| Device tree (ADT) | `tools/mkadt.py`: 1080×2400 framebuffer at `0x9c000000` (35 MiB splash region), virtual timer INTID 27, 4 GiB from `0x1_00000000`, root compatible gains `xiaomi,apollo` / `qcom,sm8250` (`xiaomi,sweet` stays: `SweetPlatformExpert` matches it). `--touch-fw` embeds the touch firmware |
| CPU | **All eight cores** with `cpus=8` (four A55, three A77, one A77 prime). `sweet_cpufreq.c` (0098) raises each cluster to its top EPSS level at boot: silver 1804 MHz, gold 2419 MHz, prime 2841 MHz (was 1516 / 710 MHz). No thermal management yet; `sweetcpufreq=N` caps at N MHz |
| Buttons | **Working** (0082, 0084): power and volume-down on the PON block, volume-up on PM8150 GPIO6 (PPID `0x0c5`), probed automatically; `sweetvolup=0xPPID` overrides |
| Touch | **Working** (0082–0094, first touch 2026-10-24). Novatek NT36675 on QUP0 SE4 SPI (`spi@990000`), reset GPIO 38, IRQ GPIO 39 (rising edge). The driver finds the pins (south TLMM tile), votes the SE4 clocks in GCC (DFS level 0 = 19.2 MHz), muxes GPIO 8–11 to `qup4`, sets up SPI at 4.8 MHz, reads the chip ID (`0e 00 00 72 66 03`), downloads the firmware with hardware CRC (reset state `0xa0`) and polls the event buffer at `0x22D00`. The chip has no flash: its firmware (`novatek_nt36675_j3s_fw01.bin`, built into Xiaomi's kernel and published in their kernel source; not in git) goes into the ADT with `mkadt.py --touch-fw` |
| Display | Kernel text and the iOS GUI on the bootloader framebuffer. A bottom band of the Setup page is drawn red (unexplained) |
| Not ported yet | Display power (0079), USB device mode / Ethernet (0072–0077), battery, the `/memory` size check |

The next steps and the full engineering history are in [`NOTES.md`](NOTES.md).

## Roadmap

**Overall: 10 of 15 milestones done**

```
[█████████████░░░░░░░]  67 %
```

**Touch: 8 of 8 steps done**

```
[████████████████████]  100 %
```

**GPU: 6 of 9 steps done** (power and clocks, GMU firmware, GMU messages and 3D core power, microcode and commands, out of secure mode, first GPU-drawn frame; next: kernel GPU service, Mesa freedreno, CoreAnimation bridge)

```
[█████████████░░░░░░░]  67 %
```

| # | Milestone | State |
| --- | --- | --- |
| 1 | Shim boots on apollo (`fastboot boot`, SM8250 GIC/timers/PSCI) | ✅ Done |
| 2 | XNU kernel boots on SM8250 | ✅ Done |
| 3 | iOS root on UFS `userdata` mounts, launchd and daemons run | ✅ Done |
| 4 | iOS GUI on screen (Setup) | ✅ Done |
| 5 | Six cores (`cpus=6`) | ✅ Done |
| 6 | Buttons: power, volume-up, volume-down | ✅ Done |
| 7 | Touch: GPIO pins, SE4 clocks, SPI pin mux, SPI engine, chip ID | ✅ Done |
| 8 | Touch: firmware download into the NT36675 (0093) | ✅ Done (2026-10-24) |
| 9 | Touch: finger reports reach iOS; Setup, home screen and gestures usable | ✅ Done (2026-10-24) |
| 10 | CPU speed: clock up via the EPSS tables, then all eight cores (`cpus=8`, A55 + A77) | ✅ Done (2026-10-24): 8 cores, silver 1804 / gold 2419 / prime 2841 MHz |
| 11 | Display: fix the red band on the Setup page; display off/on with the power button (0079 for SM8250) | ⏳ Planned |
| 12 | USB device mode, USB Ethernet and the live kernel log (0072–0077 retargeted to SM8250) | ⏳ Planned |
| 13 | Battery and charging readout | ⏳ Planned |
| 14 | Wi-Fi, Bluetooth, audio, cameras, sensors, cellular | 🔭 Long term |
| 15 | GPU acceleration (Adreno 650), following [HackiOS](https://github.com/oosexgang/hackios-xnu-kernel)'s Adreno 642L work: (1) probe, (2) GMU, (3) 3D core and zap shader, (4) Mesa freedreno + CoreAnimation bridge | 🔄 Phase 2 done (2026-10-24): **the GMU's firmware runs** (`a650_gmu.bin` through our SMMU context, `fw_init_result 0x100`) and its HFI queues are up. Phase 3 (2026-10-24, boot 17): **the GMU powers the 3D core**, which answers its first register reads; then everything is handed back cleanly. Boot 20 (0104, `sweetgpu=19`): **the 3D core takes commands**: SQE microcode running, command processor started, `CP_ME_INIT` read and executed with no faults. Boot 24 (0105–0109, `sweetgpu=20`): **the 3D core is out of secure mode** — TrustZone authenticates the signed zap shader (`a650_zap.mdt`/`.b02` via `mkadt.py --zap-mdt --zap-seg`, PAS image 13) into `pil_gpu_mem 0x8681a000`, and `CP_SET_SECURE_MODE 0` goes through the ring with no faults. (Boot 21 hung on a blind `PAS_SHUTDOWN`-of-nothing; the SCM calls were reworked into a staged, verified `sweetgpuzap` ladder — `0` off, `1` atomic queries, `2` += signature, `3` += the full load, now the default — and that call was removed.) Boot 26 (0110–0111, `sweetgpu=22`): **the GPU draws**: the core writes our memory on command, and its 2D engine fills a 1080×2400 frame (orange, white, blue) that is checked and shown on the panel. Phase 4 in test (0112, `sweetgpu=22 sweetgpukeep=1`): the GPU kept on as the `SweetGPU` IOKit service with the msm DRM interface Mesa's freedreno speaks. Then: Mesa freedreno, the CoreAnimation bridge |

The touch steps are pins, clocks, pin mux, SPI, chip ID, firmware download, finger reports and iOS gestures, all done. Milestones 14 and 15 were never done on sweet either: they need drivers for hardware Apple's userland knows nothing about, so treat them as research, not scheduled work.

## What ios-sweet achieved on `sweet` (the baseline)

| Area | State on sweet (as of 2026-10-18) |
| --- | --- |
| Boot | Stock Xiaomi bootloader → `fastboot boot` of our shim → XNU. Nothing is flashed to the boot partitions |
| CPU | All 8 cores (six Cortex-A55 + two Cortex-A76) via PSCI, 16K pages, GICv3 interrupts, timers |
| Memory | About 3.95 GiB of the upper DDR bank |
| Storage | Own UFS host driver; the iOS root is a journaled HFS+ volume in `userdata`, read/write |
| iOS userland | Real iPhone X 16.7.16 root filesystem and shared cache; launchd and the system daemons run |
| Display | Kernel IOSurface + IOMobileFramebuffer (`AppleCLCD`); CoreAnimation renders in software; frames copied to the bootloader framebuffer; presented as an iPhone X panel (1125×2436); display off/on with the power button |
| GUI | backboardd, SpringBoard, lock screen, home screen, Control Center, notification center, Settings, app switcher, home gesture |
| Input | Goodix GT9896 touch over GENI I²C; power and volume keys over SPMI; all delivered as HID events |
| USB | DWC3 device mode, CDC-ECM Ethernet (`ue0`, 192.168.7.2), live kernel log streamed over UDP |
| Identity / activation | iPhone X (`iPhone10,3` / `D22AP`); mobileactivationd's native "Hactivation" path, no Apple servers |

Not working on sweet either: Wi-Fi, Bluetooth, cellular, audio, camera, sensors, GPS, SEP / Face ID and the GPU. Rendering is done on the CPU at about 20–30 fps, the first boot takes about 4 minutes, and iOS does not use the USB link for internet yet. Code signing (AMFI), the sandbox and data protection are permissive or stubbed.

## How it boots

```
ABL (stock Xiaomi bootloader, unlocked)
  -> fastboot boot shim-boot.img              (temporary; nothing is flashed to boot)
     -> shim: own MMU setup, reads the live FDT, loads the payload from the ramdisk
        -> XNU Mach-O + generated Apple Device Tree (ADT) + boot-args
           -> XNU -> UFS driver -> HFS+ root in the userdata partition
              -> dyld + shared cache -> launchd -> daemons -> backboardd + SpringBoard
```

There is no usable serial port. The kernel draws its console into the framebuffer that ABL leaves at `0x9c000000` and keeps a persistent 4 MiB log ring in the last 1025 blocks of `userdata`. `tools/sweet-log-pull.sh` reads that ring from recovery. Once USB comes up (`sweetusb=2`), `tools/sweet-usbnet.sh` streams the log live instead.

## Build and boot

You need an **unlocked** device, a Linux PC and a GitHub account (the kernel builds on GitHub's macOS runners). **Everything on `userdata` is lost.** Bootloaders, recovery, modem and persist are never touched.

### 0. Back up the phone

Boot a recovery with adb root temporarily and pull at least `persist`, `modemst1`, `modemst2`, `fsg`, `fsc`, `boot`, `dtbo` and `vbmeta`. They hold per-device calibration data and serial numbers, so keep them out of git (`backup/`, `dtb/` and `recovery/` are already in `.gitignore`). The shim needs the stock DTB:

```sh
python3 tools/unpack_bootv2.py backup/boot.img dtb/boot_unpacked   # -> dtb/boot_unpacked/dtb
```

### 1. Validate, then build the kernel

```sh
python3 tools/validate-repo.py        # seconds; CI runs it before the macOS build
gh workflow run xnu.yml -R YOU/ios-apollo
gh run download RUN_ID -R YOU/ios-apollo -n xnu-kernel -D xnu/out
```

The workflow fetches xnu-8796 via [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build), applies `xnu/patches/` in order and stages the pinned open-source libpthread, HFS and BearSSL sources. `validate-repo.py` checks patch numbering, that every hunk matches its `@@` header, and that every file the series creates (`bsd/dev/sweet_*.c`, …) still applies through every later patch. A hand-edited or stale patch fails there in under a second. `tools/xnu-cc.py` replays single-file compiles from a previous CI log.

### 2. Build the iOS root image

From the iPhone X (iPhone10,3) iOS 16.7.16 (20H392) IPSW, on Linux with `apfs-fuse`, `hfsprogs` and sudo:

```sh
tools/mkiosroot.sh OS.dmg SystemOS.dmg AppOS.dmg ios16-root.img 16G
sudo fsck.hfsplus -fy ios16-root.img
sudo mount -t hfsplus -o loop,force ios16-root.img /mnt/iosroot
sudo python3 tools/sweet-root-tweaks.py /mnt/iosroot
sudo umount /mnt/iosroot
img2simg ios16-root.img ios16-root.simg
```

`sweet-root-tweaks.py` applies the bring-up changes: Setup skip, seeded activation state, no baseband daemon, no app watchdogs, and others. Its header explains each one. The ADT builder copies `/product` from the real iPhone X device tree (MobileGestalt needs it):

```sh
python3 tools/remotezip.py IPSW_URL DeviceTree.d22ap.im4p research/ipsw-x/dt
ipsw img4 im4p extract research/ipsw-x/dt/Firmware/all_flash/DeviceTree.d22ap.im4p -o research/ipsw-x/d22ap.adt
```

### 3. Build the boot image

Needs `aarch64-linux-gnu-gcc` and `mkbootimg`.

```sh
python3 tools/mkadt.py shim/out/apollo.adt --highmem --touch-fw research/apollo-fw/novatek_nt36675_j3s_fw01.bin
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/apollo.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1'
shim/build.sh ../shim/out/payload.bin      # -> shim/out/shim-boot.img
```

The touch firmware is compiled into Xiaomi's stock kernel, so it is on no partition. Xiaomi publishes it in their kernel source (`firmware/` of MiCode/Xiaomi_Kernel_OpenSource, branch `apollo-q-oss`). Download and convert it (not in git; `research/` is in `.gitignore`):

```sh
mkdir -p research/apollo-fw && cd research/apollo-fw
curl -LO https://raw.githubusercontent.com/MiCode/Xiaomi_Kernel_OpenSource/apollo-q-oss/firmware/novatek_nt36675_j3s_fw01.bin.ihex
objcopy -I ihex -O binary novatek_nt36675_j3s_fw01.bin.ihex novatek_nt36675_j3s_fw01.bin
sha256sum novatek_nt36675_j3s_fw01.bin   # 429137d357f25c62be6652c179041fe2f1a815e4890bbd531eb1506110bbe628
cd ../..
```

Without `--touch-fw`, the kernel boots normally and touch stops before the firmware download. `tools/nvt-fw-find.py` can also pull the firmware out of a stock kernel `Image`.

| Boot-arg | Effect |
| --- | --- |
| `rd=ufsroot0 ufsrw=1 rootrw=1` | Root on the `userdata` partition, writable |
| `cpus=N` | Number of cores to start; `cpus=1` is the safe fallback |
| `launchd_unsecure_cache=1` | launchd accepts its job cache without AMFI |
| `wdt=-1 wdt_test=no_user_checkin` | No hardware watchdog |
| `sweetfb_noconsole=1`, `sweetfb_hz=30` | Stop drawing kernel text over the GUI; panel copy rate |
| `sweettouch=0`, `sweetkeys=0` | Disable the touch or button driver |
| `sweettouchstage=1..4` | Touch bring-up depth: 1 reads the pins, 2 reads the SPI engine, 3 pulses reset, 4 sets up clocks, pins and SPI, reads the chip ID, loads the firmware and polls for reports (default 4) |
| `sweettouchdelay=S`, `sweettouch_debug=1` | Touch start delay in seconds (default 20); log every raw report |
| `sweettouchfw=0`, `sweettouchmux=0` | Skip the firmware download or the SPI pin mux |
| `sweettouchse=`, `sweettouchrst=`, `sweettouchirq=`, `sweettouchtlmm=`, `sweettouchdiv=`, `sweettouchbuf=` | Override the SPI engine address, reset/IRQ GPIOs, TLMM tile, SPI clock divider (default 4 = 4.8 MHz) and event buffer address |
| `sweetcpufreq=N` | CPU clock: 0 leaves the firmware's speed, 1 (default) the highest non-boost level per cluster, N > 1 the highest level at or below N MHz |
| `sweetgpu=1..22`, `sweetgpuzap=0..3`, `sweetgpulevel=N`, `sweetgpukeep=1` | Adreno 650 bring-up (off by default): 1 reads the GPU clocks in GCC, 2 switches the GPU config-bus clock on if needed, 3 reads the GPU clock controller, 4 powers the CX half on, 5 starts the GMU clocks (200 MHz), 6 reads the GMU, 7 reads its RPMh channel, 8–9 read the GPU's SMMU, 10 tests the GMU's memory, 11 maps memory for the GMU through the SMMU, 12 loads `a650_gmu.bin`, 13 starts the GMU, 14 starts its HFI queues, 15 reads RPMh's command database (rail levels), 16 sends the GMU its speed and bus tables and starts it, 17 asks for a GPU speed (`sweetgpulevel` 1 = 305 MHz … 6 = 587 MHz, default 1) and for the 3D core's power, then reads the core, 18 maps the core's ring and microcode, 19 starts its command processor and sends `CP_ME_INIT`, 20 leaves secure mode via the zap shader (11+ need `mkadt.py --gmu-fw`, 18+ also `--sqe-fw`, 20 also `--zap-mdt --zap-seg`). Step 20's TrustZone calls are staged by `sweetgpuzap` (a blind one hung apollo, boot 21): `0` no SCM call, `1` only the atomic no-memory queries, `2` += the zap signature, `3` (default since 0109) += the load and `CP_SET_SECURE_MODE`. 21 has the core write a word into our memory, 22 has its 2D engine fill a frame, checked and copied to the panel. Everything is given back and CX collapsed again afterwards, unless `sweetgpukeep=1`: then, once step 21 (or 22) has passed, the GPU stays on, a self-test submission runs through the kept path, and the `SweetGPU` service offers the GPU to programs (Linux's msm DRM interface, as HackiOS's RedwoodGPU). Runs `sweetgpudelay` seconds (default 15) after the drivers start |
| `ufslogsecs=N` | Persistent-log flush interval in seconds (use 1 when chasing hangs) |
| `sweetvolup=0xPPID` | PMIC GPIO peripheral for volume-up (SID << 8 \| peripheral) |
| `sweetusb=2` | USB device mode, CDC-ECM Ethernet and the live log |

### 4. Flash the root and boot

```sh
fastboot -S 512M flash userdata ios16-root.simg   # ~7 minutes; do not unplug
fastboot boot shim/out/shim-boot.img
```

On sweet, Xiaomi's fastboot often hangs after a large flash. Re-enter fastboot with Power + Volume down. The first boot sits on the Apple logo for 4–5 minutes.

### 5. Read the kernel log

```sh
fastboot boot recovery/recovery.img        # temporary recovery with adb
tools/sweet-log-pull.sh logs/boot.txt      # 4 MiB console ring from the end of userdata
adb reboot bootloader
```

The driver lines start with `SWEET ...`, and crash reports start with `CRASH name ...`. `tools/sweet-crash.py` symbolicates the crash reports against the shared cache. `tools/qemu-sweet.py` boots the same kernel on QEMU `virt` for kernel-only changes; see [`docs/QEMU_TESTING.md`](docs/QEMU_TESTING.md).

## Repository layout

| Path | What |
| --- | --- |
| `shim/` | Bare-metal boot shim (C + asm) packed as an Android boot.img v2 |
| `xnu/patches/` | The XNU patch series (0001–0112, applied in order by CI) plus staging scripts for libpthread, HFS and BearSSL |
| `.github/workflows/xnu.yml` | `validate` (Ubuntu, seconds), then the kernel `build` (macOS) |
| `tools/validate-repo.py` | Patch-series and script checks (numbering, hunk headers, replay of series-created files) |
| `tools/mkadt.py` | Apple Device Tree from the board's MMIO layout and the iPhone X identity |
| `tools/mkpayload.py` | Packs kernel + ADT + boot-args into the shim payload |
| `tools/mkiosroot.sh`, `sweet-root-tweaks.py` | HFS+ iOS root from the IPSW images, and the bring-up changes to it |
| `tools/sweet-log-pull.sh`, `sweet-log.py`, `sweet-usbnet.sh` | Persistent log from recovery; live log over USB Ethernet |
| `tools/sweet-crash.py` | Symbolicate console crash reports |
| `tools/xnu-cc.py` | Local single-file compile check from a CI log |
| `tools/qemu-sweet.py` | QEMU test boots with framebuffer text decoding |
| `tools/lpextract.py` | Extract one partition (e.g. `vendor`) from a raw Android `super` image |
| `tools/gmu-fw-info.py` | List the blocks of an Adreno GMU firmware file |
| `tools/nvt-fw-find.py` | Find and extract NT36xxx touch firmware built into a kernel `Image` |
| `tools/adt.py`, `remotezip.py`, `unpack_bootv2.py`, `sparsediff.py`, `check-exports.py` | Helpers |
| `site/` | The project website |
| `NOTES.md` | Engineering log: every boot, crash and decision, hardware facts, the active handoff |

Not in git: partition backups, live device trees, recovery images, Apple firmware and root images, CI build trees and pulled logs. They contain device serials and calibration data, or Apple's copyrighted files.

## Kernel patches

| # | What |
| --- | --- |
| 0001–0009 | Toolchain compatibility, SWEET machine config, non-PAC arm64, stubs for Apple-internal pieces |
| 0010–0018 | Early framebuffer console, physmap fix, PRNG without corecrypto, device-tree platform expert, timer PPI, boot CPU driver |
| 0019–0020 | Apple open-source libpthread kernel provider; BearSSL AES |
| 0021–0027 | RAM-disk root, mockfs, SHA-256, minimal AMFI, Apple open-source HFS+, MD5 |
| 0028–0034 | UFS host driver and root device, read/write root, DMA above 4 GiB |
| 0035–0045 | Entitlements, bindfs, AppleKeyStore stub, IOWatchdog, console crash reports |
| 0046 | IOSurface (IOCoreSurfaceRoot) and IOMobileFramebuffer (AppleCLCD) services |
| 0047–0055 | Diagnostics: persistent log, /dev/null tee, IOKit trace, heap strings and user stack sampler on crash; permissive Sandbox policy; HFS rename-swap; AppleKeyStore selectors |
| 0056–0057 | Throttled panel copy; no external identity resolver |
| 0058 | HID event services (Apple IOHIDFamily-1915.140.3 user client and event queue) |
| 0059 | iPhone X identity (`hw.product` / `hw.target` from the device tree) |
| 0060 | sweet power/volume keys over SPMI; touch over GENI I²C |
| 0061 | Present the display as 1125×2436 |
| 0062–0063 | RPMh touch rail; battery power source; GENI FIFO packing and the Goodix GT9896 protocol |
| 0064 | Grant PRIV_WORK_INTERVAL (UIKit's CoreAnimation work interval) |
| 0065 | SMP: secondary cores via PSCI CPU_ON |
| 0066–0069 | Fault-region crash info; console mute; IOSurface lookup fix; batched persistent-log flushes |
| 0070–0071 | `pid_hibernate` syscall (leaving apps); edge-swipe flags on touches (home gesture) |
| 0072–0077 | USB: DWC3 probe, ep0, VBUS override, CDC-ECM Ethernet `ue0`, RX into cluster mbufs, live log over UDP |
| 0078–0081 | All eight cores; display power off/on; network route/address trace; Ethernet link state |
| **0082** | **apollo:** Novatek NT36675 SPI touch driver (first version); volume-up PPID fallback and `sweetvolup=` |
| **0083–0087** | **apollo:** touch bring-up in logged stages (`sweettouchstage`); volume-up probe (finds PM8150 GPIO6); TLMM tile search; SPI engine firmware/clock logging; selectable SE |
| **0088–0089** | **apollo:** touch driver from the live device tree and Xiaomi's source: SE4 `0x990000`, GPIO 38/39, NT36xxx SPI framing, chip-ID read, event buffer `0x22D00` |
| **0090–0092** | **apollo:** SE4 clock votes in GCC (hardware-gated branches accepted); SPI pin mux GPIO 8–11 → `qup4` |
| **0093** | **apollo:** NT36675 firmware host download with hardware CRC (firmware from the ADT) |
| **0094** | **apollo:** touch on by default (stage 4, 20 s delay); no polling without running firmware |
| **0095** | **apollo:** CPU clock through the SM8250 OSM frequency tables (`sweet_cpufreq.c`) |
| **0096** | **apollo:** Adreno 650 phase 1, staged read-only probe of the GPU clocks and power (`sweet_gpu.c`, `sweetgpu=N`) |
| **0097** | **apollo:** Adreno 650 steps 4–6: CX power on, GMU clocks, first GMU register reads (GPU block alive); raw frequency-table dump |
| **0098** | **apollo:** CPU clock with the EPSS layout apollo actually has; GPU steps 7–10 (RSCC, SMMU, GMU memory) |
| **0099** | **apollo:** GPU register access as single `ldr`/`str` (the hypervisor emulates the SMMU); probe on its own thread after `sweetgpudelay` s |
| **0100** | **apollo:** GMU boot, steps 11–14: SMMU page tables and context, `a650_gmu.bin` load, RSCC/PDC, GMU start, HFI queues |
| **0101** | **apollo:** GPU steps 15–17: cmd-db rail levels, HFI speed and bus tables, "start", GPU speed vote, 3D core power (OOB), clean give-back (slumber, RPMh sleep) |
| **0102** | **apollo:** GPU steps 18–19: core SMMU context (streams 0/1), `a650_sqe.fw` (`mkadt.py --sqe-fw`), Linux a650 register setup, command processor start, `CP_ME_INIT`; cmd-db bus addresses |
| **0103** | **apollo:** accept apollo's `a650_sqe.fw` (version 0x093, below Linux's 0x095 minimum; the vendor kernel runs it) with a warning |
| **0104** | **apollo:** the 3D core's SMMU stream entry written as the device tree declares it (stream 0, mask 0x401) |
| **0105–0109** | **apollo:** GPU step 20 (the user's): the signed zap shader authenticated by TrustZone (`mkadt.py --zap-mdt --zap-seg`, staged by `sweetgpuzap`), then `CP_SET_SECURE_MODE 0`: the 3D core out of secure mode |
| **0110** | **apollo:** GPU steps 21–22: `CP_MEM_WRITE` into our page; a 1080×2400 frame filled by the 2D engine in three bands, checked, copied to the panel |
| **0111** | **apollo:** step 22 maps the 10 MB panel framebuffer from the kernel's data range (`ml_io_map_unmappable`) instead of the 8 MiB I/O map pool, and releases it |
| **0112** | **apollo:** the GPU kept on (`sweetgpukeep=1`): address allocator, mapping, ring submission with fences, a self-test; the `SweetGPU` IOKit service and user client (msm DRM ABI of HackiOS's RedwoodGPU) |

## Key hardware facts

| | sweet (SM7150) | apollo (SM8250) |
| --- | --- | --- |
| GIC | GICv3, `0x17a00000` / `0x17a60000` | same addresses |
| Virtual timer | INTID 19 (PPI 3) | INTID 27 (PPI 11) |
| Framebuffer | `0x9c000000`, 1080×2400 | `0x9c000000`, 1080×2400, 35 MiB splash region |
| Touch | Goodix GT9896, I²C `0x5d`, QUP SE7 `0xa84000` | Novatek NT36675 (flashless), SPI on QUP0 SE4 `0x990000` (pins GPIO 8–11, `qup4`), reset GPIO 38 / IRQ GPIO 39 in the south TLMM tile `0x0f500000` |
| Touch clocks | Left on by ABL | Off under `fastboot boot`: GCC `0x100000`, vote `0x52008` bits 6–9 and 14, SE4 RCG `0x174d0` (DFS) |
| Volume-up | PM6150L GPIO2 (PPID `0x4c1`) | PM8150 GPIO6 (PPID `0x0c5`) |
| CPUs | 6×A55 + 2×A76 | 4×A55 + 4×A77 |

Both: PSCI through `smc`, 19.2 MHz timer, no pointer authentication, UFS host at `0x1d84000`. Details in [`NOTES.md`](NOTES.md).

## Credits

Built on [ios-sweet](https://github.com/dipa-studio/ios-sweet) and Apple's open-source releases (xnu, IOHIDFamily, libpthread, hfs), [BearSSL](https://bearssl.org), [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build), [ipsw](https://github.com/blacktop/ipsw), Qualcomm/Xiaomi's published Linux kernel sources for the hardware details, and [OrangeFox Recovery](https://orangefox.download). iOS itself is Apple's and is not distributed here. Licensed under the MIT License (see `LICENSE`).
