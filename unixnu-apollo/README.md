# UniXNU-apollo (project-BadApple)

The [UniXNU](https://unixnu.com/porting/) device repository for the Xiaomi Mi 10T 5G / Mi 10T Pro 5G
(`apollo`, Qualcomm SM8250), running the iOS 16.7.16 (20H392) userland of the iPhone X. Format 2
(board, DTS, OS profile, porting record), kept inside project-BadApple until it is split into its own
repository (`git subtree split --prefix=unixnu-apollo`).

**Status (2026-11-18): the configuration resolves and the payload, firmware and boot image build on a
Linux host; nothing has booted through UniXNU yet.** [porting.toml](porting.toml) is the authoritative
statement of what is measured, built and planned.

## What changes, what stays

| Layer | Before (project-BadApple) | With UniXNU (this directory) |
| --- | --- | --- |
| Boot image | `shim/` (our own loader) | BootShim + uefi-apollo firmware volume + payload ramdisk (`./unixnu bootimg`) |
| Loader | `shim/loader.c` | UniXNU.efi + DarwinBoot |
| Device tree | `tools/mkadt.py` | `dts/apollo.dts` + `os-profiles/` + `board.toml` [adt], through UniXNU's generator, plus `scripts/apollo-adt.py` for what the SWEET kernel still reads that the generator cannot write |
| Kernel | xnu-8796.141.3 + `xnu/patches` 0001-0186 (SWEET), `xnu.yml` | the same kernel, handed to `./unixnu payload --kernel` |
| Root | HFS+ image in userdata (`tools/build-ios-root.sh`) | unchanged |

The kernel and the root stay project-BadApple's, so everything that works today (touch, Metal on
Turnip, Wi-Fi, Bluetooth, audio) can keep working once DarwinBoot hands off. Moving the kernel itself
to `./unixnu kernel` (the patch series split into OS, SoC and device layers) is the next stage
(porting.toml, area `packaging`).

| Repository | Role | Pin |
| --- | --- | --- |
| [UniXNU](https://github.com/UniXNU/UniXNU) | Build tools, DarwinBoot, the ADT generator | checked at `563595ab` |
| [UniXNU-sm8250-common](https://github.com/Pistachio-Project/UniXNU-sm8250-common) | Shared SM8250 DTSI | `13f1d873` (feeds.toml) |
| [uefi-apollo](https://github.com/Pistachio-Project/uefi-apollo) | Mu-Silicium firmware for apollo (reaches the UniXNU menu on a Mi 10T) | `ab70992c` |
| this directory | Board DTS, iOS 16.7.16 profile, payload policy, ADT bridge, record | |

## Layout

| Path | Contents |
| --- | --- |
| `board.toml` | Board, SoC, OS profile, components, firmware, boot image, payload, board ADT values |
| `feeds.toml`, `unixnu.lock` | Pinned SoC source and xnu-8796.141.3 |
| `dts/apollo.dts` | DRAM, firmware carve-outs, panic log region, CPUs (SMP), UFS; the rest of the wiring as comments |
| `os-profiles/ios-16.7.16-20H392/` | The iOS 16.7.16 iPhone X profile, linked into UniXNU by `scripts/install-os-profile.sh` |
| `configs/`, `patches/xnu/series` | Placeholders in this stage (the kernel is built by `xnu.yml`) |
| `scripts/apollo-adt.py` | `gap`: what the SWEET kernel reads and the generator does not write; `payload`: puts mkadt.py's tree with DarwinBoot's handoff properties into the payload |
| `scripts/package.sh` | UniXNU's packaging script (unchanged copy) |
| `proprietary-files.txt` | The phone's firmware, where it comes from and who uses it |
| `evidence/host/` | Logs of the host checks the porting record cites |

## Build (host)

Checkouts side by side: `~/ios-apollo` (this repository), `~/UniXNU`, `~/uefi-apollo`.
Tools: `python3` (3.11+), `git`, `make`, `clang`/`lld`, `dtc`, `mtools`
([requirements](https://unixnu.com/guide/requirements)).

```sh
git clone https://github.com/UniXNU/UniXNU ~/UniXNU
git clone https://github.com/Pistachio-Project/uefi-apollo ~/uefi-apollo
git -C ~/uefi-apollo checkout ab70992cdf353d7531df77649740bcce405365f4
```

```sh
~/ios-apollo/unixnu-apollo/scripts/install-os-profile.sh
```

```sh
cd ~/UniXNU && D=~/ios-apollo/unixnu-apollo &&
./unixnu defconfig apollo_defconfig -D $D && ./unixnu fetch -D $D && ./unixnu status --json -D $D &&
python3 scripts/porting-record.py check --device $D
```

Image, with the SWEET kernel from `xnu.yml` and the usual `mkadt.py` arguments of the boot (firmware,
root files, options; `--highmem` as always):

```sh
cd ~/ios-apollo && python3 tools/mkadt.py shim/out/apollo.adt --highmem --display-height 2502 --artwork-subtype 2556 ... &&
cd ~/UniXNU && D=~/ios-apollo/unixnu-apollo &&
./unixnu firmware -D $D --uefi ~/uefi-apollo --target RELEASE &&
UNIXNU_UNIQUE_CHIP_ID=5357454554000001 ./unixnu payload -D $D --kernel ~/ios-apollo/xnu/out/kernel.development.sweet &&
python3 $D/scripts/apollo-adt.py payload out/apollo/ios-16.7.16-20H392/apollo/payload/payload.img ~/ios-apollo/shim/out/apollo.adt &&
./unixnu bootimg -D $D --uefi ~/uefi-apollo --target RELEASE --dtb ~/ios-apollo/dtb/boot_unpacked/dtb
```

The image is `out/apollo/ios-16.7.16-20H392/apollo/boot/boot.img` (`fastboot boot`, nothing flashed).
What to look for on the first boot is in porting.toml (areas `firmware` and `memory`): the UniXNU
menu, then DarwinBoot's large-type hand-off screen with the window address (`pa=`), which
`apollo-adt.py --window` must match.

## Read

[Port a device](https://unixnu.com/porting/), [migration](https://unixnu.com/porting/migration),
[device repository](https://unixnu.com/porting/device-repository),
[device tree](https://unixnu.com/porting/device-tree), [boot chain](https://unixnu.com/concepts/boot-chain),
[records](https://unixnu.com/porting/records), and project-BadApple's `NOTES.md`.

Licenses: see [NOTICE](NOTICE).
