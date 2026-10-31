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
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <spawn.h>

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
#define MIRROR_MAX 3000u
static int mirror_on;
static int mirror_all;          /* every level, not only errors and keyword lines (fileproviderd) */
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
		} else if ((desc & 0xf0) == 0x40 && sz == 8) {   /* an object (%@): its description */
			const void *obj;
			char text[320];
			CFStringRef d;

			memcpy(&obj, buf + p, sizeof(obj));
			text[0] = 0;
			if (obj != NULL && (uintptr_t)obj > 0x100000 && ((uintptr_t)obj >> 47) == 0 &&
			    (d = CFCopyDescription((CFTypeRef)obj)) != NULL) {
				(void)CFStringGetCString(d, text, sizeof(text), kCFStringEncodingUTF8);
				CFRelease(d);
			}
			for (char *c = text; *c != 0; c++) {
				if (*c == '\n') {
					*c = ' ';
				}
			}
			n += snprintf(out + n, outsz - (size_t)n, " |%.300s", text[0] ? text : "<nil>");
		} else {
			n += snprintf(out + n, outsz - (size_t)n, " |<%#x>", desc);   /* private data and others */
		}
		p += sz;
	}
}

static int
mirror_wanted(uint8_t type, const char *line)
{
	static const char *const words[] = {
		"ersona", "RDServer", "UMSyncServer", "rovider", "omain", "LocalStorage", "xtension", "lugIn", "plugin", "ontainer", "group.",
		"ail", "rror", "enied", "nvalid", "not ", "nable", "can't", "cannot", "missing", "ejected", NULL
	};

	static const char *const noise[] = {
		"oucher", "AllKeys", "Cache key", "container lookup", "Query;", "container_", "APS", "apsd",
		"Topics", "MessageSize", "xpc_activity", "XPC_ACTIVITY", "PASLazyPlist", "TRIClient", NULL
	};

	for (int i = 0; noise[i] != NULL; i++) {
		if (strstr(line, noise[i]) != NULL) {
			return 0;
		}
	}
	if (mirror_all || type == 0 || type >= 0x10) {   /* OS_LOG_TYPE_DEFAULT, _ERROR, _FAULT */
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
	static char last[1400];
	char line[1400];

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

/*
 * mach_vm_protect as a raw Mach trap (_kernelrpc_mach_vm_protect_trap, -14) from this library's own code:
 * hooking a system call stub (statfs, boot 103) makes a page of libsystem_kernel writable and so not executable,
 * and libsystem_kernel's own vm_protect sits on that page -- calling it to restore the page jumped into it
 * (usermanagerd: "Data/Stack execution not permitted", SIGBUS, no home screen).
 */
static kern_return_t
raw_vm_protect(mach_port_t task, uintptr_t address, uintptr_t size, int set_max, int prot)
{
	register long x0 __asm__("x0") = (long)task;
	register long x1 __asm__("x1") = (long)address;
	register long x2 __asm__("x2") = (long)size;
	register long x3 __asm__("x3") = set_max;
	register long x4 __asm__("x4") = prot;
	register long x16 __asm__("x16") = -14;

	__asm__ volatile ("svc #0x80" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x16) : "memory", "cc");
	return (kern_return_t)x0;
}

static int
hook_jump(const char *name, void *to)
{
	uint32_t *at = (uint32_t *)dlsym(RTLD_DEFAULT, name);
	uint32_t words[4];
	uintptr_t ps = (uintptr_t)getpagesize(), page, span;
	uint64_t target = (uint64_t)(uintptr_t)to;
	mach_port_t self = mach_task_self();

	if (at == NULL) {
		return 0;
	}
	words[0] = 0x58000050u;         /* ldr x16, #8 */
	words[1] = 0xd61f0200u;         /* br x16 */
	words[2] = (uint32_t)target;
	words[3] = (uint32_t)(target >> 32);
	page = (uintptr_t)at & ~(ps - 1);
	span = ((uintptr_t)(at + 4) - page + ps - 1) & ~(ps - 1);
	/* from here until the page is executable again: no calls into other libraries (they may be on this page) */
	if (raw_vm_protect(self, page, span, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
		return 0;
	}
	for (int i = 0; i < 4; i++) {
		((volatile uint32_t *)at)[i] = words[i];
	}
	(void)raw_vm_protect(self, page, span, 0, VM_PROT_READ | VM_PROT_EXECUTE);
	sys_icache_invalidate(at, sizeof(words));
	return 1;
}

/*
 * (boot 97) The fix itself: fileproviderd logged "[INFO] Not instantiating file providers until setup has
 * been run." and "[ERROR] denying connection because the device is not set up", so no provider (not even
 * "On My iPhone") was ever started. -[FPDServer _computeUnlockedStatusAndSetup] (FileProviderDaemon) asks
 * BYSetupAssistantNeedsToRun() (SetupAssistant.framework), which looks past com.apple.purplebuddy's
 * SetupDone (launch sentinel, MobileGestalt, dates) and answers YES on this port although Setup was
 * skipped (tools/sweet-root-tweaks.py). In the programs this library is inserted into it answers NO.
 */
/*
 * (boot 102) The real Files blocker: fileproviderd logs "Non-eligible device /dev/ufsroot0: non-apfs" and
 * "Volume /dev/ufsroot0 not eligible to store FP library, skipping": -[FPDVolume isEligibleForFPFS:] wants the
 * volume's statfs to be writable, MNT_LOCAL and f_fstypename "apfs" (strcasecmp). Our iOS root is HFS+, so no
 * file provider library, no domain, no "On My iPhone". In the Files programs statfs/fstatfs/getfsstat are done
 * here on the raw system calls and an "hfs" volume is reported as "apfs" (nothing else changes).
 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static void
fix_fstype(struct statfs *b)
{
	if (b != NULL && strcmp(b->f_fstypename, "hfs") == 0) {
		strlcpy(b->f_fstypename, "apfs", sizeof(b->f_fstypename));
	}
}

static int
fix_statfs(const char *path, struct statfs *buf)
{
	int r = syscall(SYS_statfs64, path, buf);

	if (r == 0) {
		fix_fstype(buf);
	}
	return r;
}

static int
fix_fstatfs(int fd, struct statfs *buf)
{
	int r = syscall(SYS_fstatfs64, fd, buf);

	if (r == 0) {
		fix_fstype(buf);
	}
	return r;
}

static int
fix_getfsstat(struct statfs *buf, int bufsize, int flags)
{
	int r = syscall(SYS_getfsstat64, buf, bufsize, flags);

	for (int i = 0; buf != NULL && i < r; i++) {
		fix_fstype(&buf[i]);
	}
	return r;
}
#pragma clang diagnostic pop

/* fileproviderd: every os_log level counts as enabled, so its debug lines are formatted and reach the mirror */
static int
fix_log_enabled(void)
{
	return 1;
}

static int
fix_setup_done(void)
{
	return 0;
}

/*
 * (jailbreak) In configd (root, alive for the whole boot; xnu 0168 inserts us): start userland/jb's sweet-jbinstall,
 * detached in its own session and without our DYLD_ variables, while its archive is there and
 * /var/jb/.sweet-jb-done is not. Boot 105 started it from usermanagerd instead: launchd ends that job after 15 s
 * idle (and its boot task sooner) and the processes it started with it, mid-unpack.
 */
static void
fix_start_jb_installer(void)
{
	static char *const argv[] = { "/usr/local/bin/sweet-jbinstall", NULL };
	static char *const env[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL };
	posix_spawnattr_t attr;
	struct stat st;
	pid_t pid;
	int err;

	if (stat("/var/jb/.sweet-jb-done", &st) == 0 || stat("/private/var/sweet-jb/bootstrap.tar.xz", &st) != 0 ||
	    stat(argv[0], &st) != 0) {
		return;
	}
	posix_spawnattr_init(&attr);
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
	err = posix_spawn(&pid, argv[0], NULL, &attr, argv, env);
	posix_spawnattr_destroy(&attr);
	fprintf(stderr, "fixlog: jailbreak installer %s (pid %d, error %d)\n", err == 0 ? "started" : "NOT started", err == 0 ? pid : -1, err);
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
		static const char *const mirrored[] = { "fileproviderd", "Files", "LocalStorageFileProvider", "usermanagerd", NULL };
		const char *me = getprogname();

		if (me != NULL && strcmp(me, "configd") == 0) {
			fix_start_jb_installer();
		}
		for (int i = 0; me != NULL && mirrored[i] != NULL; i++) {
			if (strcmp(me, mirrored[i]) == 0) {
				mirror_on = 1;
				mirror_all = strcmp(me, "fileproviderd") == 0;
			}
		}
		if (mirror_on && strcmp(me, "usermanagerd") != 0) {
			int a = hook_jump("statfs", (void *)fix_statfs);
			int b = hook_jump("fstatfs", (void *)fix_fstatfs);
			int c = hook_jump("getfsstat", (void *)fix_getfsstat);

			fprintf(stderr, "fixlog: %s: hfs volumes reported as apfs (statfs %d, fstatfs %d, getfsstat %d)\n", me, a, b, c);
			fprintf(stderr, "fixlog: %s: BYSetupAssistantNeedsToRun -> NO: %s\n", me,
			    hook_jump("BYSetupAssistantNeedsToRun", (void *)fix_setup_done) ? "hooked" : "NOT FOUND");
		}
		if (mirror_on) {
			if (mirror_all) {
				fprintf(stderr, "fixlog: %s: os_log_type_enabled -> always: %s\n", me,
				    hook_jump("os_log_type_enabled", (void *)fix_log_enabled) ? "hooked" : "NOT FOUND");
				(void)hook_jump("_os_log_debug_impl", (void *)mirror_entry);
			}
			int n = hook_jump("_os_log_impl", (void *)mirror_entry);
			int e = hook_jump("_os_log_error_impl", (void *)mirror_entry);
			int f = hook_jump("_os_log_fault_impl", (void *)mirror_entry);

			fprintf(stderr, "fixlog: %s[%d]: os_log mirrored (os_log_impl %s, error %s, fault %s)\n", me, getpid(),
			    n ? "hooked" : "NO", e ? "hooked" : "no", f ? "hooked" : "no");
		}
	}
}
