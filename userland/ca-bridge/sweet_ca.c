/*
 * libsweet-ca.dylib: what the kernel puts into backboardd (boot-arg
 * sweetinject=/usr/local/lib/libsweet-ca.dylib:backboardd, xnu 0114) so that CoreAnimation draws
 * with the GPU: it loads /usr/local/lib/libsweet-gl.dylib (eagl.c), the OpenGL ES behind
 * EAGLContext, before the window server makes its first context.
 *
 * The kernel offers the GPU (the SweetGPU service) some seconds after the window server has
 * started (sweet_gpu.c runs boot-arg sweetgpudelay seconds after the drivers, 15 by default), so
 * this waits for it, up to a minute (boot-arg sweetgl_wait=SECONDS): the library would otherwise
 * find no GPU and draw in software. No GPU by then, or boot-arg sweetgl=0: CoreAnimation keeps its
 * own software renderer, as without this library.
 *
 * Boot-arg caenv=NAME=VALUE (as many as wanted) goes into the window server's environment first,
 * for CoreAnimation's own switches. The output goes to stderr, which is the console log with
 * backboardd in boot-arg sweetnull.
 *
 * After HackiOS's userland/src/inject.c (Copyright (c) 2026 OOSEX GANG, MIT License, see
 * LICENSE.HackiOS): its opengl_es() and caenv handling; nothing of its iOS 16.5 patches.
 */
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef struct __CFDictionary *CFMutableDictionaryRef;
typedef const struct __CFDictionary *CFDictionaryRef;
extern CFMutableDictionaryRef IOServiceMatching(const char *name);
extern io_service_t IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching);
extern kern_return_t IOObjectRelease(io_object_t object);
extern const char *getprogname(void);

#define SWEET_GL        "/usr/local/lib/libsweet-gl.dylib"

static void
say(const char *format, ...)
{
	char line[512];
	va_list ap;
	int n;

	va_start(ap, format);
	n = vsnprintf(line, sizeof(line), format, ap);
	va_end(ap);
	if (n > (int)sizeof(line) - 1) {
		n = sizeof(line) - 1;
	}
	if (n > 0) {
		write(2, line, (size_t)n);
	}
}

/* the value of boot-arg NAME= in ARGUMENTS (the text after "NAME="), or NULL */
static const char *
boot_arg(const char *arguments, const char *name)
{
	size_t length = strlen(name);

	for (const char *at = arguments; (at = strstr(at, name)) != NULL; at += length) {
		if ((at == arguments || at[-1] == ' ') && at[length] == '=') {
			return at + length + 1;
		}
	}
	return NULL;
}

static int
gpu_there(void)
{
	io_service_t gpu = IOServiceGetMatchingService(0, IOServiceMatching("SweetGPU"));

	if (gpu == 0) {
		return 0;
	}
	IOObjectRelease(gpu);
	return 1;
}

__attribute__((constructor))
static void
sweet_ca_init(void)
{
	char arguments[1024] = "";
	size_t size = sizeof(arguments) - 1;
	const char *name = getprogname(), *value;
	unsigned wait = 60, waited = 0;

	if (name == NULL || strcmp(name, "backboardd") != 0) {
		return;
	}
	(void)sysctlbyname("kern.bootargs", arguments, &size, NULL, 0);
	for (const char *argument = arguments; (argument = strstr(argument, "caenv=")) != NULL; argument += 6) {
		char setting[128];
		size_t length = strcspn(argument + 6, " ");
		char *equals;

		if ((argument != arguments && argument[-1] != ' ') || length == 0 || length >= sizeof(setting)) {
			continue;
		}
		memcpy(setting, argument + 6, length);
		setting[length] = 0;
		if ((equals = strchr(setting, '=')) != NULL) {
			*equals = 0;
			setenv(setting, equals + 1, 1);
			say("sweet-ca: caenv: %s=%s for the window server\n", setting, equals + 1);
		}
	}
	if ((value = boot_arg(arguments, "sweetgl")) != NULL && value[0] == '0') {
		say("sweet-ca: sweetgl=0: CoreAnimation keeps its software renderer\n");
		return;
	}
	if ((value = boot_arg(arguments, "sweetgl_wait")) != NULL) {
		wait = (unsigned)strtoul(value, NULL, 10);
	}
	if (access(SWEET_GL, R_OK) != 0) {
		say("sweet-ca: no %s: CoreAnimation keeps its software renderer\n", SWEET_GL);
		return;
	}
	while (!gpu_there()) {
		if (waited >= wait * 10) {
			say("sweet-ca: no SweetGPU after %u s (boot-args sweetgpu=22 sweetgpukeep=1): CoreAnimation keeps its "
			    "software renderer\n", wait);
			return;
		}
		usleep(100000);
		waited++;
	}
	say("sweet-ca: SweetGPU is there (waited %u.%u s): loading %s\n", waited / 10, waited % 10, SWEET_GL);
	if (dlopen(SWEET_GL, RTLD_NOW) == NULL) {
		say("sweet-ca: %s: %s\n", SWEET_GL, dlerror());
	}
}
