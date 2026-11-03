/*
 * HotMetal2.bundle: the Metal driver for the Adreno 640 on metal2vulkan + Turnip (boot-arg hotmtl=2 / sweetmtl=2:
 * SweetAccelerator names this bundle and class HotMTL2Device). Metal.framework loads it in every process that asks
 * for a device; -initWithAcceleratorPort: hands back the frontend's device (NativeBridgeMetalFrontend.mm, UniXNU's,
 * over the bridge in bridge/, which drives Turnip, the libvulkan_freedreno.dylib inside this bundle, through the
 * kernel's v2 user client). Which processes get one: backboardd always, others when /var/local/mtl2-clients lists
 * them ("*" = all, "-NAME" excludes NAME); the rest get none, so their frameworks take their CPU paths.
 * Log: /dev/console and /var/local/mtl2.log (when it exists, mode 666), lines "MTL2[pid name]: ...".
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <string.h>
#include "NativeBridgeMetalFrontend.h"
#include "bridge/NativeMetalObjects.h"

extern "C" void sm2_logs(const char *s);
static void sm2_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#include "HotPrimeShaders.h"

extern "C" void sm2_logs(const char *s)
{
	char buf[700];
	int n = snprintf(buf, sizeof(buf), "MTL2[%d %s]: %s\n", getpid(), getprogname(), s);
	if (n > (int)sizeof(buf) - 1)
		n = (int)sizeof(buf) - 1;
	static int console = -2, file = -2;
	if (console == -2) {
		const char *want_console = getenv("HOT_MTL2_CONSOLE");
		if (!want_console)
			want_console = getenv("SWEET_MTL2_CONSOLE");
		console = (want_console && !strcmp(want_console, "1")) ? open("/dev/console", O_WRONLY | O_NOCTTY) : -1;
	}
	if (file == -2)
		file = open("/var/local/mtl2.log", O_WRONLY | O_APPEND);
	if (console >= 0)
		write(console, buf, (size_t)n);
	if (file >= 0)
		write(file, buf, (size_t)n);
}

static void sm2_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void sm2_log(const char *fmt, ...)
{
	char buf[600];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	sm2_logs(buf);
}

/*
 * The A640 does not snoop the CPU caches: libSystem's sys_dcache_flush (a no-op where the GPU is coherent) must
 * really clean and invalidate here. User space may (SCTLR_EL1.UCI). This definition wins at link time, for the
 * bridge and the frontend alike (IOSurface imports).
 */
extern "C" void sys_dcache_flush(void *start, size_t len)
{
	uintptr_t a = (uintptr_t)start & ~(uintptr_t)63, end = (uintptr_t)start + len;
	for (; a < end; a += 64)
		__asm__ volatile("dc civac, %0" :: "r"(a) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}

/* Metal validation failures abort by default; frameworks with Apple-GPU-only kernels (MPS) report one on any other device. */
__attribute__((constructor)) static void sm2_error_mode(void)
{
	void (*set)(unsigned, unsigned) = (void (*)(unsigned, unsigned))dlsym(RTLD_DEFAULT, "MTLFailureTypeSetErrorModeType");
	for (unsigned t = 0; set && t < 5; t++)
		set(t, 5);	/* 5 = NSLog */
}

/* Selectors the frontend lacks, each logged once (the frontend then raises the usual unrecognised-selector exception) */
static void missing(const char *cls, const char *sel)
{
	static NSMutableSet *seen;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		seen = [NSMutableSet new];
	});
	NSString *k = [NSString stringWithFormat:@"%s %s", cls, sel];
	@synchronized(seen) {
		if ([seen containsObject:k])
			return;
		[seen addObject:k];
	}
	sm2_log("MISSING %s -%s", cls, sel);
}

@interface NBDeviceMethods : NSObject
@end

/*
 * QuartzCore asks for its precompiled pipeline archive (Apple GPU code): none, it builds its pipelines itself.
 * CoreImage / IconServices on iOS 26 also probe stitched & dynamic libraries; refuse cleanly with NSError before
 * _MTLDevice's base implementation schedules MTLCompilerStitchingRequest onto a worker queue and sends private
 * _MTLFunction selectors (-[NBFunction libraryData]) that abort iconservicesagent.
 */
@interface NBDeviceMethods (HotMetal2)
@end
@implementation NBDeviceMethods (HotMetal2)
- (id)newPipelineLibraryWithFilePath:(NSString *)path error:(NSError **)error
{
	(void)path;
	if (error)
		*error = [NSError errorWithDomain:@"HotMetal2" code:1 userInfo:@{ NSLocalizedDescriptionKey : @"no pipeline libraries" }];
	return nil;
}
- (id)newLibraryWithStitchedDescriptor:(id)descriptor error:(NSError **)error
{
	(void)descriptor;
	if (error)
		*error = [NSError errorWithDomain:@"HotMetal2" code:2 userInfo:@{ NSLocalizedDescriptionKey : @"stitched libraries are not supported" }];
	return nil;
}
- (void)newLibraryWithStitchedDescriptor:(id)descriptor completionHandler:(void (^)(id, NSError *))completionHandler
{
	(void)descriptor;
	NSError *err = [NSError errorWithDomain:@"HotMetal2" code:2 userInfo:@{ NSLocalizedDescriptionKey : @"stitched libraries are not supported" }];
	if (completionHandler)
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ completionHandler(nil, err); });
}
- (id)newLibraryWithStitchedDescriptorSPI:(id)descriptor error:(NSError **)error
{
	return [self newLibraryWithStitchedDescriptor:descriptor error:error];
}
- (void)newLibraryWithStitchedDescriptorSPI:(id)descriptor completionHandler:(void (^)(id, NSError *))completionHandler
{
	[self newLibraryWithStitchedDescriptor:descriptor completionHandler:completionHandler];
}
- (id)newDynamicLibrary:(id)library error:(NSError **)error
{
	(void)library;
	if (error)
		*error = [NSError errorWithDomain:@"HotMetal2" code:3 userInfo:@{ NSLocalizedDescriptionKey : @"dynamic libraries are not supported" }];
	return nil;
}
- (id)newDynamicLibraryWithURL:(NSURL *)url error:(NSError **)error
{
	(void)url;
	if (error)
		*error = [NSError errorWithDomain:@"HotMetal2" code:3 userInfo:@{ NSLocalizedDescriptionKey : @"dynamic libraries are not supported" }];
	return nil;
}
@end

static bool listed(void)
{
	if (!strcmp(getprogname(), "backboardd"))
		return true;
	FILE *f = fopen("/var/local/mtl2-clients", "r");
	if (!f)
		return false;
	char text[2048] = { 0 };
	size_t n = fread(text, 1, sizeof(text) - 1, f);
	fclose(f);
	text[n] = 0;
	/* names, "*" = all, "-NAME" = never NAME (wins over "*") */
	char *save = NULL;
	bool yes = false;
	for (char *name = strtok_r(text, " ,\t\r\n", &save); name; name = strtok_r(NULL, " ,\t\r\n", &save)) {
		if (name[0] == '-' && !strcmp(name + 1, getprogname()))
			return false;
		if (!strcmp(name, "*") || !strcmp(name, getprogname()))
			yes = true;
	}
	return yes;
}

@interface _MTLDevice : NSObject
@end

@interface HotMTL2Device : _MTLDevice
- (id)initWithAcceleratorPort:(mach_port_t)port;
@end

@implementation HotMTL2Device
- (id)initWithAcceleratorPort:(mach_port_t)port
{
	/* this object is dropped for the frontend's device: initialised, so its -[_MTLDevice dealloc] has queues to release */
	if (!(self = [super init]))
		return nil;
	static id device;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		if (!listed()) {
			sm2_log("not listed (/var/local/mtl2-clients): no Metal device");
			return;
		}
		NSString *bundle = [[NSBundle bundleForClass:[HotMTL2Device class]] bundlePath];
		NSString *turnip = [bundle stringByAppendingPathComponent:@"libvulkan_freedreno.dylib"];
		char cache[256];
		mkdir("/var/local/m2v-cache", 0777);
		chmod("/var/local/m2v-cache", 0777);
		snprintf(cache, sizeof(cache), "/var/local/m2v-cache/%s", getprogname());
		mkdir(cache, 0777);
		if (access(cache, W_OK) != 0) {
			/* a sandboxed process: its own caches directory */
			char dir[256];
			if (confstr(_CS_DARWIN_USER_CACHE_DIR, dir, sizeof(dir) - 8)) {
				snprintf(cache, sizeof(cache), "%sm2v", dir);
				mkdir(cache, 0700);
			}
		}
		/* plain rows everywhere: no Apple framebuffer compression, no 10-bit deep framebuffer */
		setenv("CA_DISABLE_FRAMEBUFFER_COMPRESSION", "1", 1);
		CFPreferencesSetAppValue(CFSTR("CAEnableFramebufferCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		CFPreferencesSetAppValue(CFSTR("CAEnableIOSurfaceCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		CFPreferencesSetAppValue(CFSTR("CAEnableDeepFramebuffer"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		/* debugging: KEY=VALUE lines of /var/local/mtl2-env into this process's environment */
		if (FILE *ef = fopen("/var/local/mtl2-env", "r")) {
			char line[256];
			while (fgets(line, sizeof(line), ef)) {
				line[strcspn(line, "\r\n")] = 0;
				char *eq = strchr(line, '=');
				if (line[0] != '#' && eq) {
					*eq = 0;
					setenv(line, eq + 1, 1);
					sm2_log("env %s=%s", line, eq + 1);
				}
			}
			fclose(ef);
		}
		/* opt-in via HOT_MTL2_LOG_PIPELINES=1: the runtime's VkPipeline makings count into the telemetry (V row) */
		{
			const char *lp = getenv("HOT_MTL2_LOG_PIPELINES");
			if (!lp)
				lp = getenv("SWEET_MTL2_LOG_PIPELINES");
			if (lp && !strcmp(lp, "1"))
				setenv("METAL2VULKAN_LOG_PIPELINES", "1", 0);
		}
		/* Default Adreno 640 GMEM tiling autotune with concurrent binning off (AdrenoMetal@461a8421); overridable via mtl2-env or mtl2-tu-debug */
		setenv("TU_DEBUG", "nocb", 0);
		/* debugging: Turnip options for this process from /var/local/mtl2-tu-debug (TU_DEBUG), its log to /var/local/turnip-<proc>.log */
		{
			char opts[128] = { 0 };
			FILE *f = fopen("/var/local/mtl2-tu-debug", "r");
			if (f) {
				if (fgets(opts, sizeof(opts), f))
					opts[strcspn(opts, "\r\n")] = 0;
				fclose(f);
			}
			if (opts[0]) {
				char path[128];
				snprintf(path, sizeof(path), "/var/local/turnip-%s.log", getprogname());
				setenv("TU_DEBUG", opts, 1);
				setenv("MESA_LOG_FILE", path, 1);
				sm2_log("TU_DEBUG=%s, log %s", opts, path);
			}
		}
		uint64_t registryID = 0;
		IORegistryEntryGetRegistryEntryID(port, &registryID);
		double t0 = CFAbsoluteTimeGetCurrent();
		@try {
			device = native_bridge_metal_open(turnip.UTF8String, cache, registryID, missing);
		} @catch (NSException *e) {
			sm2_log("device: exception %s", e.reason.UTF8String);
			device = nil;
		}
		sm2_log("device %s in %.0f ms (cache %s)%s%s", device ? [[device name] UTF8String] : "refused",
			(CFAbsoluteTimeGetCurrent() - t0) * 1000, cache, device ? "" : ": ", device ? "" : nmb_last_error());
		/*
		 * Extended-range (XR10) formats: the frontend withholds them so backboardd keeps an 8-bit framebuffer; other
		 * processes may render into them (AegirPoster's CAMetalLayer throws "unsupported extended range format" without).
		 */
		if (device && strcmp(getprogname(), "backboardd") != 0)
			class_replaceMethod(object_getClass(device), sel_registerName("supportsExtendedXR10Formats"),
					    imp_implementationWithBlock(^BOOL(id me) { (void)me; return YES; }), "B16@0:8");
		/* image bases, for symbolicating pstack samples (atos -o out/HotMetal2.dSYM -l BASE ADDR) */
		Dl_info self = { 0 }, tu = { 0 };
		dladdr((void *)sm2_logs, &self);
		void *th = dlopen(turnip.UTF8String, RTLD_NOW | RTLD_NOLOAD);
		void *vk = th ? dlsym(th, "vk_icdGetInstanceProcAddr") : NULL;
		if (vk)
			dladdr(vk, &tu);
		sm2_log("images: HotMetal2 %p, libvulkan_freedreno %p", self.dli_fbase, tu.dli_fbase);
		/* backboardd: idle background shader priming (+90 s, QOS_CLASS_BACKGROUND) + optional 10 s telemetry */
		if (device && !strcmp(getprogname(), "backboardd")) {
			hot_prime_shaders_start((id<MTLDevice>)device, "/var/local/mtl2-primelist", 90);
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
				for (;;) {
					sleep(10);
					if (access("/var/local/mtl2-telemetry", F_OK) != 0)
						continue;
					static char text[8192];
					native_bridge_metal_telemetry(text, sizeof(text));
					int fd = open("/var/local/mtl2.log", O_WRONLY | O_APPEND);
					if (fd >= 0) {
						dprintf(fd, "MTL2[%d %s]: telemetry\n%s", getpid(), getprogname(), text);
						close(fd);
					}
				}
			});
		}
	});
	return device;
}
@end

@interface SweetMTL2Device : HotMTL2Device
@end
@implementation SweetMTL2Device
@end
