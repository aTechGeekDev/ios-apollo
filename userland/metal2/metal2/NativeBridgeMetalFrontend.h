// SPDX-License-Identifier: MIT
// Entry points of the native Metal frontend over the bridge (NativeBridgeMetalFrontend.mm).
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
extern "C" {
// Opens the process's one device: loader exports vkGetInstanceProcAddr (Turnip), cache is a writable shader-cache directory, registryID is the
// accelerator service's registry entry. missing (may be null) is told the class and selector of every unimplemented call.
id native_bridge_metal_open(const char *loader, const char *cache, uint64_t registryID, void (*missing)(const char *, const char *));
// Bare AIR bitcode as a library (the bridge's fixtures; Metal itself accepts only metallibs).
id native_bridge_metal_library_with_air(const void *bytes, size_t length);
// One line for the plugin's status report: command buffers committed/failed locally, pipelines made, refusals, the last refusal's text.
size_t native_bridge_metal_status(char *out, size_t size);
// The pixel formats of the textures asked for (first eight distinct) and how many texture requests the runtime refused.
size_t native_bridge_metal_formats(char *out, size_t size);
size_t native_bridge_metal_telemetry(char *out, size_t size);
// Structured cumulative artifact/driver-cache counters for offline qualification.
struct NmbShaderCacheStats;
bool native_bridge_metal_shader_cache_stats(struct NmbShaderCacheStats *out);
bool native_bridge_metal_work_stats(uint64_t out[10]);
uint64_t native_bridge_metal_recent_commits(uint64_t windowUs);
// The same fixed CPU, memory and pipeline workload on the tablet and the host, so their times compare directly (int-145): compute, first-touch
// page faults, memset bandwidth, CommonCrypto SHA-256, then the first `pairs` vertex/fragment pairs of the given QuartzCore metallib made into
// BGRA8 render states and drawn once each (pipeline_timing_host's draw=1 order). The results become the telemetry's Y rows; also returned.
size_t native_bridge_metal_benchmark(id device, const char *metallib, unsigned pairs, char *out, size_t size);
}
#endif
