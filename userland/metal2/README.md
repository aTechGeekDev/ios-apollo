# Metal through metal2vulkan + Turnip (SweetMetal2)

Metal for iOS 16.7 on the Mi 10T's Adreno 650 the way IOS-26-Hot runs it on the Adreno 640: Apple's Metal.framework
loads **SweetMetal2.bundle** (named by the kernel's `IOAcceleratorES` service, `SweetAccelerator`, with boot-arg
`sweetmtl=2`); the bundle's device (UniXNU's NativeBridgeMetalFrontend) records Metal's commands, metal2vulkan turns
them and Apple's AIR shaders into Vulkan, and **Turnip** (Mesa's Vulkan driver for Adreno) runs them on the GPU through
the kernel's NativeAdreno user client (`turnip/NativeAdrenoABI.h`).

## Where the parts come from

| Part | Source | Licence |
|---|---|---|
| `metal2/` (HotMetal2.mm, NativeBridgeMetalFrontend.mm, HotPrimeShaders.h, m2vtest.c, Info.plist) | [IOS-26-Hot](https://github.com/nithinyadavamaraboina-online/IOS-26-Hot) `phone/metal2` at d249939b (2026-11-01), unchanged | MIT (`LICENSE.IOS-26-Hot`) |
| `metal2/bridge/` (NativeMetalBridge.rs, NativeMetalObjects.rs/.h, patches/) | the same; the bridge is UniXNU's NativeMetal | MIT (`metal2/bridge/LICENSE`) |
| `turnip/` (NativeAdrenoABI.h, vktest.c, v2test.cpp, shaders/, patches/) | IOS-26-Hot `phone/turnip` at d249939b, unchanged | MIT |
| `build-turnip-ios.sh`, `build-m2v-bridge.sh`, `ios-cc`, `*/build.sh` | IOS-26-Hot's `tools/` and build scripts, paths changed for this repository | MIT |
| Mesa (Turnip) | gitlab.freedesktop.org/mesa/mesa 85fda3b3, fetched by `fetch-sources.sh` | MIT |
| UniXNU's Mesa patches (the darwin kernel backend `tu_knl_darwin.cc` and Turnip fixes) | github.com/UniXNU/UniXNU cd1b9757, `patches/mesa`, in `scripts/data/adreno-compiler-inputs.json` order | BSD-2-Clause-Patent |
| metal2vulkan | github.com/steelbrain/metal2vulkan 720ef1ce + `metal2/bridge/patches` | see the project |

IOS-26-Hot's kernel series for iOS 16 (`xnu/patches`, xnu-8796.141.3) shares this repository's 0001-0081 (the ios-sweet
baseline) and runs the same iPhone X 16.7.16 (20H392) root; its Metal kernel side (0096/0097/0115/0116 there) is
re-done here on this kernel's own GPU core (xnu 0170, `bsd/dev/sweet_gpu.c`).

## Build

`.github/workflows/metal2.yml` (macOS): `fetch-sources.sh`, `build-turnip-ios.sh ios`, `build-m2v-bridge.sh ios`
(Rust 1.98, `aarch64-apple-ios`), `metal2/build.sh`, `turnip/build.sh`. Artifact `sweet-metal2`.

## On the phone (in order)

1. `sweetmtl=1`: the kernel publishes the GPU for Vulkan only (no Metal plug-in named): `vktest` checks Turnip.
2. `m2vtest`: the bridge.
3. `sweetmtl=2` with SweetMetal2.bundle in /System/Library/Extensions: Metal clients (backboardd always; others listed
   in `/var/local/mtl2-clients`, `*` for all) get the device; CoreAnimation renders through Metal. Without the GL bridge
   (no libsweet-ca injection) in those boots.

Run-time switches the plug-in reads (files on the phone): `/var/local/mtl2.log` (its log, if the file exists),
`/var/local/mtl2-clients`, `/var/local/mtl2-env` (KEY=VALUE lines), `/var/local/mtl2-tu-debug` (TU_DEBUG),
`/var/local/mtl2-telemetry`.
