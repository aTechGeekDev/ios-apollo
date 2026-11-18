# xnu27: the iOS 26/27-generation kernel for apollo

Apple's open-source **xnu-12377.121.6** (macOS 26.5's xnu; Apple has not published the iOS 27 kernel, and UniXNU and
Scion run iOS 27 on this one with Darwin 27's system calls added), built as the SWEET machine configuration in plain
arm64: the Snapdragon 865 has no pointer authentication, so iOS 27's arm64e user space is rewritten to arm64 ("PAC
translation", as Scion does) and the kernel emulates what is left. Built by `.github/workflows/xnu27.yml`, artifact
`xnu27-kernel`. The iOS 16 kernel (`xnu/`, `xnu.yml`) is separate and unchanged.

## The series (`patches/`, applied in name order after the staging scripts)

| Range | What | Source |
| --- | --- | --- |
| `0000`, `0001`, `0019`, `0020`, `0026`, `0058` `.sh` | Staging: CoreEntitlements v2 headers (stand-in KDK), TrustCache headers, libpthread-539.100.4, BearSSL, hfs-715.120.4, IOHIDFamily-2238.120.5; each fetched at a pinned commit and checked | IOS-26-Hot `xnu/patches-26` at d249939b |
| `0003`-`0081` | The SWEET baseline on xnu-12377 (the same patches as our `xnu/patches` 0001-0081 on xnu-8796, rebased) | IOS-26-Hot d249939b |
| `0129`, `0130`, `0133`, `0135`, `0140`, `0141` | Generic iOS 26 changes: arm64e Mach-O exec and the shared region, the ARMv8.3/8.4 PAC instruction emulator in `sleh.c`, the production fuse query, the kmem RNG board guard, IPC service ports, the IOMobileFramebuffer swap layout | IOS-26-Hot d249939b |
| `0900` | iOS 27 (Darwin 26) system calls in slots xnu-12377 leaves `nosys`: `pipe2`, `dup3`, `fchflagsat`, `getumask`, `aio_readv`/`aio_writev` (ENOTSUP), `fsctlat`, `guarded_ftruncate_np` | UniXNU `patches/xnu-12377/darwin26-syscalls.patch` at be2cb0c7 (BSD-2-Clause-Patent) |
| `0901` | Shared-region slide capped so iOS 27's larger shared cache still maps | UniXNU `patches/xnu-12377/darwin26-shared-region.patch` at be2cb0c7 |

Not taken from IOS-26-Hot: its Pixel 4 (`flame`) and Realme X2 Pro (`rmx1931`) drivers (0083-0128 and later
`flame-*`), whose file names collide with ours (`sweet_gpu.c`, `SweetAccelerator.cpp`, ...). Its other generic
iOS 26 patches (0131 build fixes, 0132, 0134 firehose, 0136, 0137, 0138 PAC fast path, 0142 IOSurface ABI, 0148)
also edit those phones' code; they are being split (NOTES.md, "iOS 27 TRACK") and join as their generic parts are
resolved.

To come: project-BadApple's apollo drivers
(`xnu/patches` 0082-0186) ported to xnu-12377.

## Licenses

The patches modify Apple's XNU (APSL 2.0). IOS-26-Hot's files are MIT, "Copyright (c) 2026 dipa-studio"
(github.com/nithinyadavamaraboina-online/IOS-26-Hot/blob/d249939b9c36380afaee1a76cf167aeee8347475/LICENSE).
The staging scripts fetch Apple's open-source releases and BearSSL (MIT) at build time; none of their sources is kept here.
