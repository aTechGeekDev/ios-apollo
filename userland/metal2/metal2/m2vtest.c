/*
 * m2vtest: the metal2vulkan runtime on Turnip on the A640 (phone/metal2/bridge self-test): a compute kernel, a render
 * pass, a render into imported host pages, then every QuartzCore kernel and vertex/fragment pair translated and
 * built into pipelines on the phone.
 *   m2vtest [TURNIP] [CACHE_DIR] [METALLIB]
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "bridge/NativeMetalBridge.h"

/*
 * libSystem's sys_dcache_flush assumes a coherent GPU (Apple's): here it must really clean and invalidate,
 * from user space (SCTLR_EL1.UCI is set). This definition wins over libSystem's at link time.
 */
void sys_dcache_flush(void *start, size_t len)
{
	uintptr_t a = (uintptr_t)start & ~(uintptr_t)63, end = (uintptr_t)start + len;
	for (; a < end; a += 64)
		__asm__ volatile("dc civac, %0" :: "r"(a) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}

static double t0;
static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static void mark(uint32_t m)
{
	static const char *const names[] = { "", "device", "fixture library", "compute", "render", "import", "QuartzCore" };
	unsigned i = m & 0xff;
	printf("[%7.2f s] step %x %s\n", now() - t0, m, i < 7 ? names[i] : (i == 0xf ? "done" : "?"));
	fflush(stdout);
}

int main(int argc, char **argv)
{
	const char *lib = argc > 1 ? argv[1] : "/var/local/lib/libvulkan_freedreno.dylib";
	const char *cache = argc > 2 ? argv[2] : "/var/local/m2v-cache";
	const char *qc = argc > 3 ? argv[3] : "/System/Library/Frameworks/QuartzCore.framework/default.metallib";
	mkdir(cache, 0777);
	int fd = open(qc, O_RDONLY);
	struct stat st;
	uint8_t *bytes = NULL;
	size_t n = 0;
	if (fd >= 0 && fstat(fd, &st) == 0) {
		n = (size_t)st.st_size;
		bytes = malloc(n);
		if (read(fd, bytes, n) != (ssize_t)n)
			n = 0;
		close(fd);
	}
	printf("QuartzCore metallib: %zu bytes\n", n);
	struct NmbSelftest out = { 0 };
	t0 = now();
	uint32_t r = nmb_selftest(lib, cache, bytes, n, mark, &out);
	printf("result %x stage %x: compute bad %u/1000, render bad %u/64, import bad %u/4096\n", r, out.stage, out.compute_bad,
	       out.render_bad, out.import_bad);
	printf("QuartzCore: %u functions, kernels %u ok %u failed, vertex/fragment pairs %u ok %u failed (%.1f s)\n",
	       out.qc_functions, out.qc_kernels_ok, out.qc_kernels_failed, out.qc_pairs_ok, out.qc_pairs_failed, now() - t0);
	printf("message: %.96s\n", out.message);
	return out.stage != 0;
}
