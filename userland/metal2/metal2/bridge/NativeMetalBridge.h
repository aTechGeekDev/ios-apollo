/* SPDX-License-Identifier: MIT */
/* C ABI of the native Metal bridge (NativeMetalBridge.rs): the metal2vulkan runtime over Turnip. */
#ifndef NATIVE_METAL_BRIDGE_H
#define NATIVE_METAL_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct NmbSelftest {
    uint32_t stage;              /* 0 when every step ran, else the failing step's marker (0x6501..0x6506) */
    uint32_t compute_bad;        /* wrong outputs of 1000 */
    uint32_t render_bad;         /* wrong texels of 64 (8x8) */
    uint32_t import_bad;         /* wrong texels of 4096 (64x64 over imported host pages) */
    uint32_t qc_functions;
    uint32_t qc_kernels_ok, qc_kernels_failed;
    uint32_t qc_pairs_ok, qc_pairs_failed;
    uint32_t reserved;
    char message[96];
};
/* Markers: 0x6501 device, 0x6502 fixture library, 0x6503 compute, 0x6504 render, 0x6505 import, 0x6506 QuartzCore, 0x650f done. */
uint32_t nmb_selftest(const char *loader, const char *cache_dir, const uint8_t *quartzcore, size_t quartzcore_bytes,
                      void (*mark)(uint32_t), struct NmbSelftest *out);
#ifdef __cplusplus
}
#endif
#endif
