/*
 * SPDX-License-Identifier: MIT
 *
 * HotPrimeShaders.h — Idle background Metal shader cache primer for backboardd.
 * Runs strictly on QOS_CLASS_BACKGROUND (pinned to A55 E-cores under 0151 AMP Edge)
 * after boot settles (+90 s), yields 2 s whenever recent GPU commit rate > 8/250ms,
 * and can be disabled anytime by touching /var/local/no-prime.
 */
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "NativeBridgeMetalFrontend.h"

@interface NSObject (HotPrimeZeroConstants)
- (id<MTLFunction>)nb_newFunctionWithZeroConstants:(NSString *)name;
@end

static inline void hot_prime_yield_if_busy(void)
{
	while (native_bridge_metal_recent_commits(250000) > 8) {
		usleep(2000000);
	}
}

static inline void hot_prime_shaders_start(id<MTLDevice> device, const char *list_path, unsigned delay_sec)
{
	if (!device || !list_path)
		return;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
		sleep(delay_sec);
		if (access("/var/local/no-prime", F_OK) == 0 ||
		    access("/private/var/local/no-prime", F_OK) == 0) {
			sm2_log("hot-prime: disabled (/var/local/no-prime)");
			return;
		}
		FILE *f = fopen(list_path, "r");
		if (!f)
			return;
		NSMutableArray<NSString *> *paths = [NSMutableArray array];
		char line[512];
		while (fgets(line, sizeof(line), f)) {
			line[strcspn(line, "\r\n")] = 0;
			if (line[0] == 0 || line[0] == '#')
				continue;
			[paths addObject:[NSString stringWithUTF8String:line]];
		}
		fclose(f);
		if (paths.count == 0)
			return;

		double t0 = CFAbsoluteTimeGetCurrent();
		unsigned libs_ok = 0, comp_ok = 0, rend_ok = 0;
		for (NSString *path in paths) {
			if (access("/var/local/no-prime", F_OK) == 0 ||
			    access("/private/var/local/no-prime", F_OK) == 0)
				break;
			hot_prime_yield_if_busy();
			@autoreleasepool {
				NSError *err = nil;
				NSURL *url = [NSURL fileURLWithPath:path];
				id<MTLLibrary> lib = [device newLibraryWithURL:url error:&err];
				if (!lib)
					continue;
				libs_ok++;
				NSArray<NSString *> *names = [lib functionNames];
				NSMutableArray<id<MTLFunction>> *verts = [NSMutableArray array];
				NSMutableArray<id<MTLFunction>> *frags = [NSMutableArray array];
				unsigned lib_comp = 0;
				BOOL has_zero = [(id)lib respondsToSelector:@selector(nb_newFunctionWithZeroConstants:)];
				for (NSString *fnName in names) {
					hot_prime_yield_if_busy();
					@autoreleasepool {
						id<MTLFunction> fn = has_zero
						    ? [(id)lib nb_newFunctionWithZeroConstants:fnName]
						    : [lib newFunctionWithName:fnName];
						if (!fn)
							continue;
						MTLFunctionType ft = fn.functionType;
						if (ft == MTLFunctionTypeKernel) {
							if (lib_comp < 64) {
								NSError *ce = nil;
								id<MTLComputePipelineState> cps =
								    [device newComputePipelineStateWithFunction:fn error:&ce];
								if (cps) {
									comp_ok++;
									lib_comp++;
								}
							}
						} else if (ft == MTLFunctionTypeVertex) {
							if (verts.count < 48)
								[verts addObject:fn];
						} else if (ft == MTLFunctionTypeFragment) {
							if (frags.count < 48)
								[frags addObject:fn];
						}
					}
					if (verts.count >= 48 && frags.count >= 48 && lib_comp >= 64)
						break;
				}
				NSUInteger pairs = MIN(verts.count, frags.count);
				for (NSUInteger i = 0; i < pairs; i++) {
					hot_prime_yield_if_busy();
					@autoreleasepool {
						MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
						desc.vertexFunction = verts[i];
						desc.fragmentFunction = frags[i];
						desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
						NSError *re = nil;
						if ([device newRenderPipelineStateWithDescriptor:desc error:&re])
							rend_ok++;
						desc.colorAttachments[0].blendingEnabled = YES;
						desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
						desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
						desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
						desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
						if ([device newRenderPipelineStateWithDescriptor:desc error:&re])
							rend_ok++;
					}
				}
			}
		}
		sm2_log("hot-prime: warmed %u libs, %u compute, %u render pipelines in %.1f s",
		    libs_ok, comp_ok, rend_ok, CFAbsoluteTimeGetCurrent() - t0);
	});
}
