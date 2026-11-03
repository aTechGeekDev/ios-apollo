# hakios-metal on the Mi 10T (ios-apollo port)

This directory is [hakios-metal](https://github.com/oosexgang/hakios-metal) (MIT, `LICENSE`, `NOTICE`) imported at
upstream commit `9d52b5142542a253b7263a0d7889ad278e5c7693` (2026-11-01), then ported. The import is its own commit
(`userland/metal: import hakios-metal 9d52b51 unchanged`), so `git diff <that commit> -- userland/metal` is the
whole port. Every changed place carries a `sweet` comment.

Upstream is the Metal driver of hakios: Metal's command model (queues, command buffers, blits, compute, render
passes in sysmem and GMEM, textures, samplers, blending, depth) written straight as Adreno A6xx PM4 packets and
submitted through the kernel's msm-DRM-style GPU driver, without Mesa at run time. It was measured on an Adreno 7c+
Gen 3 (A635, Mesa's a6xx gen4). The Mi 10T has an Adreno 650 (SM8250, chip id 0x06050002, Mesa's a6xx gen3).

## What the port changes

| Where | Upstream (A635, HakiosGPU) | Here (A650, SweetGPU) |
|---|---|---|
| `src/iokit_transport.cpp` | `HakiosGPU`, `<IOKit/IOKitLib.h>` | `SweetGPU` first, `HakiosGPU` after; the IOKitLib calls declared in the file (Xcode's iPhoneOS SDK has no IOKit headers); `kIOReturnNotReady` -> `EAGAIN` |
| `a6xx.hpp`, chip facts | gen4: num_ccu 2, LPAC, no early preamble, 512 KiB GMEM, tiles 32 wide | gen3: num_ccu 3 (3 SP cores), no LPAC, early preamble, 1152 KiB GMEM, tiles 96 wide; `kGpuId` 650 for Mesa's `GPUId(650)` row |
| `a6xx.hpp`, magic registers | `__info14` | `GPUId(650)`'s `magic_regs`: PC_POWER_CNTL 2, TPL1_DBG_ECO_CNTL 0x01008000, UCHE_CLIENT_PF 4, SP_DBG_ECO_CNTL 0x01000000 (the rest equal) |
| `a6xx.hpp`, CCU | RB_CCU_CNTL sysmem 0x10000000, GMEM 0x3c400000 | 0x18000000 and 0x8a400000 (colour cache at 0x114000 in GMEM), as turnip's `tu_device.cc` computes them |
| batch start (`render.cpp`) | - | `SP_FS_CTRL_REG0 = 0` last, as `fd6_emit_static_regs` does on early-preamble chips |
| compute (`compute.hpp`) | HLSQ_CS_CTRL_REG1 and SP_CS_CNTL_0/1 copies | not written (`hlsqCopies = kHasLpac`), as Gallium and computerator do without LPAC; the fake GPU checks the copies only with LPAC |
| GMEM tiles (`render.cpp` gmemTiles) | power-of-two masks | `%` for the 96-pixel alignment, doubled until a bin row is a multiple of 64 bytes (turnip `tu_pass.cc`) |
| private memory (`command.cpp`) | 2 SP cores | `a6xx::kNumSpCores` |
| fake GPU | A635 parameters | SweetGPU's: GPU_ID 650, CHIP_ID 0x06050002, GMEM 0x120000, HIGHEST_BANK_BIT 16 |
| probe | exits when there is no GPU | waits up to `SWEET_METAL_WAIT` (180) s for SweetGPU; stdout line-buffered (the kernel copies it to its log with `sweetnull`) |
| tests | A635 literals | `CHIP(a635, a650)` (`tests/test.hpp`); both builds pass |

`-DHAKIOS_METAL_A635` builds upstream's chip again (CI runs the tests both ways). Every A650 value is from Mesa 25.0's
`src/freedreno/common/freedreno_devices.py` (the `GPUId(650)` entry, `a6xx_gen3`, `a6xx_base`) and
`src/freedreno/vulkan/tu_device.cc`, read 2026-11-03 from the 25.0 branch (github.com/mirror/mesa: archive.mesa3d.org
and gitlab.freedesktop.org were not reachable from the agent's container).

Kernel side: SweetGPU already answers every request the driver makes (it is the same RedwoodGPU ABI: msm GET_PARAM,
GEM_NEW/INFO/CPU_PREP/CPU_FINI/SUBMIT, WAIT_FENCE, SUBMITQUEUE_NEW/CLOSE, GEM_CLOSE, and 0x7e for an IOSurface's
memory with the same 40-byte structure). xnu 0169 makes its FAULTS parameter count `sweet_gpu_recover()`'s resets
(0163), which `command.cpp` reads to tell a submission a reset gave up from one that ran.

## Not done yet (in order)

1. **Run the probe on the phone**: artifact `sweet-metal`, `bin/sweet-metal` (upstream's `hakios-metal-probe`,
   renamed short for the boot line), put on the root with a launchd job
   (`tools/sweet-root-add.sh sweet-metal/bin/sweet-metal com.sweet.metal`, phone in recovery), booted with the GPU kept
   on (`sweetgpu=22 sweetgpukeep=1`) and `sweet-metal` in `sweetnull`. Its lines `probe: ok ...` / `probe: FAIL ...`
   say what the A650 does with each stream; the last line is the count, and the exit status the number of failures.
   It shares the GPU with backboardd's GL bridge (one SMMU context for every client): a probe hang can take the UI
   with it until 0163's recovery resets the core.
2. **The precompiled kernels are ir3 code compiled for the A635** (`tests/fixtures/*.hpp`, made by
   `tools/ir3-kernel` / `tools/mesa/ir3-dump.patch` against chip 0x06030500). The ISA is the same family, but gen4
   lets ir3 use instructions gen3 lacks (dp4acc, getfiberid, isam.v, SSBO immediate offsets, sad). Simple kernels are
   expected to run; a probe FAIL or hang in a stage is first to be checked against this. Regenerating the fixtures for
   the A650 needs a host Mesa build (`tools/compiler.mk`, MESA=1).
3. **The compiler in the driver** (`MESA=1`: AIR -> NIR by hakios's front end, NIR -> ir3 by Mesa): needs hakios's
   Mesa tree with the AIR front end (github.com/oosexgang/hakios, `tools/mesa`), built for the host and for iOS. Without
   it Apple's `.metallib` shaders refuse by name.
4. **The Metal plug-in** (`plugin/HakiosMetal.m`): what `MTLCreateSystemDefaultDevice()` returns. Metal finds it
   through the GPU service's registry properties (hakios: boot-arg `metal=1` and two properties on HakiosGPU); SweetGPU
   publishes neither yet (a kernel patch), and the plug-in bundle needs building and installing on the root.
