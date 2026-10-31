/*
 * libsweet-fix.dylib: small run-time fixes for iOS 16 programs on apollo, inserted by the
 * kernel (xnu 0162: sweet_exec_inject's built-in group, boot-arg sweetfix=0 turns it off).
 *
 * There is no Metal device here (the GPU is driven through Mesa/OpenGL ES, not Apple's AGX
 * driver), so MTLCreateSystemDefaultDevice() is nil, and so is every library, function and
 * pipeline made from it. Most code copes; PencilKit (the markup in the screenshot preview,
 * ScreenshotServicesService) builds an MTLComputePipelineDescriptor and gives it the nil
 * function, and Metal's own check of that argument (MTLReportFailure -> __assert_rtn) aborts
 * the process (boot 93: sig 6, -[PKMetalResourceHandler newPaintShaderKernelPipelineState]
 * <- -[MTLComputePipelineDescriptorInternal setComputeFunction:]); no screenshot is saved.
 * Here the descriptor setters that take a function ignore nil (which is what they hold
 * already): the pipeline is then asked of the nil device, which answers nil, as for every
 * other Metal object here.
 *
 * (xnu 0164) An os_log mirror for the Files app, fileproviderd and LocalStorageFileProvider (the
 * "On My iPhone" provider), which never started in any boot without saying why: they log only
 * through os_log, which the kernel log never sees. _os_log_impl and its error/fault siblings jump to
 * our mirror (see hook_jump); errors, faults and default-level lines are copied, info/debug lines
 * when they name providers, domains, extensions or failures; at most MIRROR_MAX lines a process,
 * consecutive repeats dropped.
 * They go to stderr (/dev/null for these programs), which the kernel copies into its log for the
 * names 0164 adds to sweetnull: "|fileproviderd| fixlog: E ...".
 */
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>

typedef void (*setter_fn)(id, SEL, id);

#define FIXES 4
static const struct {
	const char *cls, *sel;
} fix_list[FIXES] = {
	{ "MTLComputePipelineDescriptorInternal", "setComputeFunction:" },
	{ "MTLRenderPipelineDescriptorInternal", "setVertexFunction:" },
	{ "MTLRenderPipelineDescriptorInternal", "setFragmentFunction:" },
	{ "MTLTileRenderPipelineDescriptorInternal", "setTileFunction:" },
};
static setter_fn fix_orig[FIXES];
static unsigned fix_skipped;

static void
fix_note(unsigned i)
{
	if (fix_skipped++ < 4) {
		fprintf(stderr, "sweet-fix: [%s %s] nil (no Metal device): skipped\n", fix_list[i].cls, fix_list[i].sel);
	}
}

#define FIX_SETTER(n) \
	static void fix_setter_##n(id self, SEL sel, id fn) \
	{ \
		if (fn == nil) { \
			fix_note(n); \
			return; \
		} \
		fix_orig[n](self, sel, fn); \
	}
FIX_SETTER(0)
FIX_SETTER(1)
FIX_SETTER(2)
FIX_SETTER(3)
static const IMP fix_new[FIXES] = { (IMP)fix_setter_0, (IMP)fix_setter_1, (IMP)fix_setter_2, (IMP)fix_setter_3 };

/* ---- the os_log mirror ---- */
#define MIRROR_MAX 800u
static int mirror_on;
static unsigned mirror_lines;

/* the format with os_log's encoded arguments after it (scalars as |N, C strings as |text) */
static void
mirror_decode(char *out, size_t outsz, const char *fmt, const uint8_t *buf, uint32_t size)
{
	int n = snprintf(out, outsz, "%s", fmt);
	size_t p = 2;

	if (buf == NULL || size < 2 || n < 0) {
		return;
	}
	for (uint8_t i = 0; i < buf[1] && p + 2 <= size && n < (int)outsz - 1; i++) {
		uint8_t desc = buf[p], sz = buf[p + 1];

		p += 2;
		if ((size_t)sz > size - p) {
			break;
		}
		if ((desc & 0xf0) == 0x20 && sz == 8) {         /* a C string */
			const char *str;

			memcpy(&str, buf + p, sizeof(str));
			if (str != NULL && (uintptr_t)str > 0x100000 && ((uintptr_t)str >> 47) == 0) {
				n += snprintf(out + n, outsz - (size_t)n, " |%.200s", str);
			}
		} else if ((desc & 0xf0) == 0x00 && sz >= 1 && sz <= 8) {       /* a scalar */
			unsigned long long v = 0;

			for (uint8_t b = 0; b < sz; b++) {
				v |= (unsigned long long)buf[p + b] << (8 * b);
			}
			n += snprintf(out + n, outsz - (size_t)n, " |%llu", v);
		} else {
			n += snprintf(out + n, outsz - (size_t)n, " |<%#x>", desc);   /* objects, private data */
		}
		p += sz;
	}
}

static int
mirror_wanted(uint8_t type, const char *line)
{
	static const char *const words[] = {
		"rovider", "omain", "LocalStorage", "xtension", "lugIn", "plugin", "ontainer", "group.",
		"ail", "rror", "enied", "nvalid", "not ", "nable", "can't", "cannot", "missing", "ejected", NULL
	};

	if (type == 0 || type >= 0x10) {        /* OS_LOG_TYPE_DEFAULT, _ERROR, _FAULT */
		return 1;
	}
	for (int i = 0; words[i] != NULL; i++) {
		if (strstr(line, words[i]) != NULL) {
			return 1;
		}
	}
	return 0;
}

static void
mirror(uint8_t type, const char *format, const uint8_t *buf, uint32_t size)
{
	static char last[600];
	char line[600];

	if (!mirror_on || format == NULL || mirror_lines >= MIRROR_MAX) {
		return;
	}
	mirror_decode(line, sizeof(line), format, buf, size);
	if (!mirror_wanted(type, line) || strcmp(line, last) == 0) {
		return;
	}
	strlcpy(last, line, sizeof(last));
	if (++mirror_lines == MIRROR_MAX) {
		fprintf(stderr, "fixlog: %u lines: the rest is not copied\n", MIRROR_MAX);
		return;
	}
	fprintf(stderr, "fixlog: %c %s\n", type == 0x11 ? 'F' : type == 0x10 ? 'E' : type == 2 ? 'D' : 'I', line);
}

/*
 * Boot 96: interposing reached only the programs' own calls (one line from fileproviderd, one from
 * Files): the shared cache's libraries call _os_log_impl directly. So the start of _os_log_impl,
 * _os_log_error_impl and _os_log_fault_impl (libsystem_trace) is overwritten, in this process only
 * (the page copied on write, as libsweet-gl does to QuartzCore), with a jump to mirror_entry. The
 * real function is not called afterwards: these three programs' os_log goes to the kernel log
 * instead of logd while the mirror is on.
 */
static void
mirror_entry(void *dso, void *log, uint8_t type, const char *format, uint8_t *buf, uint32_t size)
{
	(void)dso;
	(void)log;
	mirror(type, format, buf, size);
}

static int
hook_jump(const char *name, void *to)
{
	uint32_t *at = (uint32_t *)dlsym(RTLD_DEFAULT, name);
	uint32_t words[4];
	uintptr_t ps = (uintptr_t)getpagesize(), page;
	uint64_t target = (uint64_t)(uintptr_t)to;

	if (at == NULL) {
		return 0;
	}
	words[0] = 0x58000050u;         /* ldr x16, #8 */
	words[1] = 0xd61f0200u;         /* br x16 */
	words[2] = (uint32_t)target;
	words[3] = (uint32_t)(target >> 32);
	page = (uintptr_t)at & ~(ps - 1);
	if (vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)(((uintptr_t)(at + 4) - page + ps - 1) & ~(ps - 1)), FALSE,
	    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
		fprintf(stderr, "fixlog: %s: cannot make it writable\n", name);
		return 0;
	}
	memcpy(at, words, sizeof(words));
	(void)vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)(((uintptr_t)(at + 4) - page + ps - 1) & ~(ps - 1)), FALSE,
	    VM_PROT_READ | VM_PROT_EXECUTE);
	sys_icache_invalidate(at, sizeof(words));
	return 1;
}

__attribute__((constructor))
static void
sweet_fix_init(void)
{
	unsigned done = 0;

	/* Metal.framework is in the shared cache; make sure its classes are loaded */
	objc_getClass("MTLComputePipelineDescriptor");
	for (unsigned i = 0; i < FIXES; i++) {
		Class c = objc_getClass(fix_list[i].cls);
		Method m = c != Nil ? class_getInstanceMethod(c, sel_registerName(fix_list[i].sel)) : NULL;

		if (m == NULL) {
			continue;
		}
		fix_orig[i] = (setter_fn)method_setImplementation(m, fix_new[i]);
		done++;
	}
	fprintf(stderr, "sweet-fix: pid %d: %u of %u Metal setters accept a nil function\n", getpid(), done, FIXES);
	{
		static const char *const mirrored[] = { "fileproviderd", "Files", "LocalStorageFileProvider", NULL };
		const char *me = getprogname();

		for (int i = 0; me != NULL && mirrored[i] != NULL; i++) {
			if (strcmp(me, mirrored[i]) == 0) {
				mirror_on = 1;
			}
		}
		if (mirror_on) {
			int n = hook_jump("_os_log_impl", (void *)mirror_entry);
			int e = hook_jump("_os_log_error_impl", (void *)mirror_entry);
			int f = hook_jump("_os_log_fault_impl", (void *)mirror_entry);

			fprintf(stderr, "fixlog: %s[%d]: os_log mirrored (os_log_impl %s, error %s, fault %s)\n", me, getpid(),
			    n ? "hooked" : "NO", e ? "hooked" : "no", f ? "hooked" : "no");
		}
	}
}
