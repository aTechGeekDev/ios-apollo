/*
 * libsweet-bt.dylib: what the kernel inserts into bluetoothd so iOS's Bluetooth stack talks to the
 * QCA6390 the kernel brought up (sweet_bt.c, boot-arg sweetbt=6: the firmware runs, the H4 kernel
 * control "com.sweet.bluetooth" and the registry entry "bluetooth" are up). Inserted with boot-arg
 *   sweetinject=/usr/local/lib/libsweet-bt.dylib:bluetoothd
 * (xnu 0114's sweetinject + AMFI dyld policy; launchd drops DYLD_ variables itself).
 *
 * Two jobs, both in bluetoothd, from the inserted library's constructor before main() runs:
 *
 * 1. Transport. bluetoothd's HCI transport is named by the environment variable BT_HCI_TRANSPORT,
 *    which launchd will not let us set in the job's plist (apollo boot 46), so this sets it. The
 *    value H4:POSIX:com.sweet.bluetooth,115200 makes bluetoothd open the kernel's H4 endpoint (a
 *    stream kernel control of that name, to which sweet_bt.c answers "SWEET BT: H4: connected").
 *    Boot-arg sweetbthci=STRING overrides it, sweetbthci=0 leaves bluetoothd's environment alone.
 *
 * 2. The BlueTool gate. To power the controller on, bluetoothd sends RunBuiltinScript to BlueTool
 *    (XPC, MachService com.apple.BlueTool) and will not proceed until the reply's "result" is 0.
 *    BlueTool's -R boot script can only open Apple's own transports (PCIe/ACIPC), not our UART, so
 *    every command fails "Device not open yet", the script's result is non-zero, and bluetoothd
 *    relaunches BlueTool forever (boots 66-69: Settings spins). But the chip is ALREADY running
 *    (the kernel loaded the firmware), so BlueTool's boot script is redundant -- bluetoothd just
 *    needs the green light. In bluetoothd's reply handler (20H392, image offset 0x272580) the
 *    result is read with
 *        bl _xpc_dictionary_get_int64      ; 0x940fbb92
 *        mov x20, x0
 *        ...
 *        cbz x0, <success>                 ; result == 0 -> "BlueTool finished running %s script"
 *    Replacing that bl with `mov x0, #0` makes the read yield 0, so bluetoothd always takes the
 *    success branch, stores status 0, and goes on to open the H4 transport and power on. (Found by
 *    disassembling the user's 20H392 bluetoothd; boot 69 showed the earlier BlueTool-side patch was
 *    the wrong lever -- bluetoothd is the gatekeeper.) Boot-arg sweetbtpatch=0 skips the patch.
 *
 * Output goes to stderr, the console log with bluetoothd in boot-arg sweetnull.
 */
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

extern const char *getprogname(void);
extern char ***_NSGetArgv(void);
extern int *_NSGetArgc(void);

#define BT_HCI_DEFAULT  "H4:POSIX:com.sweet.bluetooth,115200"

/*
 * bluetoothd (/usr/sbin/bluetoothd, 20H392 in bt-ios.tgz): in the RunBuiltinScript reply handler,
 * image offset 0x272580 is `bl _xpc_dictionary_get_int64` (0x940fbb92) which reads the reply's
 * "result"; the next `cbz x0` takes the success path when it is 0. Overwrite that one instruction
 * with `mov x0, #0` so the result is always read as 0. If the word is not the expected bl the build
 * differs and the patch is refused.
 */
#define BTD_RESULT_OFFSET 0x272580u
#define BTD_RESULT_ORIG   0x940fbb92u   /* bl _xpc_dictionary_get_int64 */
#define BTD_RESULT_PATCH  0xd2800000u   /* mov x0, #0 */

/*
 * Observability (boot-arg sweetbtlog=1): bluetoothd logs its power-on steps through os_log, which
 * sweetnull (stdout/stderr) never sees, so boots 68-70 were blind past the BlueTool gate. Redirect
 * the _os_log_impl GOT slot (20H392 image offset 0x7f5438; the stub at 0x10065fe2c is
 * `adrp x16,0x1007f5000; ldr x16,[x16,#0x438]; br x16`) to a thunk that mirrors each line to stderr
 * and then calls the real one. os_log passes the format string in register x3; for the common
 * "%{public}s" case (bluetoothd's printf-style debug helper formats into a string and logs that),
 * the string pointer sits in the encoded arg buffer, so pull it out too. A keyword filter keeps the
 * 4 MiB console ring from wrapping away the early power-on lines.
 */
#define BTD_OSLOG_GOT_OFFSET 0x7f5438u

typedef void (*os_log_impl_fn)(void *dso, void *log, unsigned int type,
    const char *format, uint8_t *buf, uint32_t size);
static os_log_impl_fn real_os_log_impl;

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
		n = (int)sizeof(line) - 1;
	}
	if (n > 0) {
		write(2, line, (size_t)n);
	}
}

/* the text after "NAME=" in the boot arguments, up to the next space, copied into out; or NULL */
static const char *
boot_arg(const char *arguments, const char *name, char *out, size_t size)
{
	size_t length = strlen(name);

	for (const char *at = arguments; (at = strstr(at, name)) != NULL; at += length) {
		if ((at == arguments || at[-1] == ' ') && at[length] == '=') {
			size_t value = strcspn(at + length + 1, " ");

			if (value == 0 || value >= size) {
				return NULL;
			}
			memcpy(out, at + length + 1, value);
			out[value] = 0;
			return out;
		}
	}
	return NULL;
}

/*
 * The running program's own Mach-O, not libsweet-bt.dylib's. dyld does NOT promise image 0 is the
 * main program once a library is inserted (boot 68: image 0 was our dylib), so find the one
 * MH_EXECUTE image; its header is at the slid load address, so offsets add directly.
 */
static const struct mach_header *
main_executable(void)
{
	uint32_t count = _dyld_image_count();

	for (uint32_t i = 0; i < count; i++) {
		const struct mach_header *h = _dyld_get_image_header(i);

		if (h != NULL && h->magic == MH_MAGIC_64 && h->filetype == MH_EXECUTE) {
			return h;
		}
	}
	return NULL;
}

/* Overwrite one instruction at OFFSET (expected to be ORIG) with VALUE in the main executable. */
static void
patch_word(const char *who, uint32_t offset, uint32_t orig, uint32_t value)
{
	const struct mach_header *base = main_executable();
	uint32_t *at;
	vm_address_t page;
	vm_size_t span;
	kern_return_t kr;
	uintptr_t ps = (uintptr_t)getpagesize();

	if (base == NULL) {
		say("sweet-bt: %s: no MH_EXECUTE image found; not patched\n", who);
		return;
	}
	at = (uint32_t *)((uintptr_t)base + offset);
	if (*at != orig) {
		say("sweet-bt: %s: word at %p is %#x, not %#x: NOT patched (different build?)\n",
		    who, (void *)at, *at, orig);
		return;
	}
	page = (vm_address_t)((uintptr_t)at & ~(ps - 1));
	span = (vm_size_t)((((uintptr_t)at + sizeof(*at)) - page + ps - 1) & ~(ps - 1));
	kr = vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
	if (kr != KERN_SUCCESS) {
		say("sweet-bt: %s: vm_protect(rw) at %p failed (%d); not patched\n", who, (void *)page, kr);
		return;
	}
	*at = value;
	(void)vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
	sys_icache_invalidate(at, sizeof(*at));
	say("sweet-bt: %s: patched %p (%#x -> %#x)\n", who, (void *)at, orig, value);
}

/* Power-on vocabulary, so the stderr mirror does not flood the console ring with every os_log. */
static int
interesting(const char *s)
{
	static const char *const words[] = {
		"ransport", "HCI", "ontroller", "ower", "Blue", "evice", "irmware", "eset",
		"endor", "nit", "pen", "onnect", "ail", "rror", "ctl", "H4", "UART", "ACIPC",
		"adio", "addr", "MAC", "tack", NULL
	};

	for (int i = 0; words[i] != NULL; i++) {
		if (strstr(s, words[i]) != NULL) {
			return 1;
		}
	}
	return 0;
}

/* Our stand-in for bluetoothd's _os_log_impl: mirror the line to stderr, then call the real one. */
static void
sweet_oslog(void *dso, void *log, unsigned int type, const char *format, uint8_t *buf, uint32_t size)
{
	const char *text = format;

	if (format != NULL) {
		/* bluetoothd's debug helper logs the already-formatted string as a %{public}s arg. */
		if (strcmp(format, "%{public}s") == 0 && buf != NULL && size >= 12 && buf[1] >= 1 && buf[3] == 8) {
			const char *s;

			memcpy(&s, buf + 4, sizeof(s));
			if (s != NULL && (uintptr_t)s > 0x1000 && ((uintptr_t)s >> 47) == 0) {
				text = s;
			}
		}
		if (text != NULL && interesting(text)) {
			say("btd: %s\n", text);
		}
	}
	if (real_os_log_impl != NULL) {
		real_os_log_impl(dso, log, type, format, buf, size);
	}
}

/* Redirect bluetoothd's _os_log_impl GOT slot to sweet_oslog (see the header comment). */
static void
hook_os_log(const struct mach_header *base)
{
	void **slot;
	void *cur, *expected;
	vm_address_t page;
	vm_size_t span;
	kern_return_t kr;
	uintptr_t ps = (uintptr_t)getpagesize();

	if (base == NULL) {
		return;
	}
	slot = (void **)((uintptr_t)base + BTD_OSLOG_GOT_OFFSET);
	cur = *slot;
	if (cur == NULL) {
		say("sweet-bt: bluetoothd: os_log GOT slot empty; not hooking\n");
		return;
	}
	expected = dlsym(RTLD_DEFAULT, "_os_log_impl");
	if (expected == NULL) {
		expected = dlsym(RTLD_DEFAULT, "os_log_impl");
	}
	if (expected != NULL && cur != expected) {
		say("sweet-bt: bluetoothd: os_log GOT %p != _os_log_impl %p; not hooking\n", cur, expected);
		return;
	}
	real_os_log_impl = (os_log_impl_fn)cur;
	page = (vm_address_t)((uintptr_t)slot & ~(ps - 1));
	span = (vm_size_t)((((uintptr_t)slot + sizeof(*slot)) - page + ps - 1) & ~(ps - 1));
	kr = vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
	if (kr != KERN_SUCCESS) {
		say("sweet-bt: bluetoothd: vm_protect os_log slot at %p failed (%d); not hooking\n", (void *)page, kr);
		return;
	}
	*slot = (void *)&sweet_oslog;
	(void)vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ);
	say("sweet-bt: bluetoothd: os_log hooked (real %p); power-on now mirrored to stderr (sweetbtlog=1)\n",
	    (void *)real_os_log_impl);
}

/* Make bluetoothd treat BlueTool's RunBuiltinScript as success (see the header comment). */
static void
patch_bluetoothd(void)
{
	say("sweet-bt: bluetoothd: main executable at %p (%u images)\n",
	    (const void *)main_executable(), _dyld_image_count());
	patch_word("bluetoothd: BlueTool result gate", BTD_RESULT_OFFSET, BTD_RESULT_ORIG, BTD_RESULT_PATCH);
}

__attribute__((constructor))
static void
sweet_bt_init(void)
{
	char arguments[1024] = "";
	char value[256];
	size_t size = sizeof(arguments) - 1;
	const char *name = getprogname();

	if (name == NULL) {
		return;
	}
	(void)sysctlbyname("kern.bootargs", arguments, &size, NULL, 0);

	if (strcmp(name, "bluetoothd") == 0) {
		const char *transport = BT_HCI_DEFAULT;
		int set_transport = 1;

		if (boot_arg(arguments, "sweetbthci", value, sizeof(value)) != NULL) {
			if (strcmp(value, "0") == 0) {
				set_transport = 0;
				say("sweet-bt: bluetoothd: sweetbthci=0: leaving BT_HCI_TRANSPORT as it is\n");
			} else {
				transport = value;
			}
		}
		if (set_transport) {
			setenv("BT_HCI_TRANSPORT", transport, 1);
			say("sweet-bt: bluetoothd: BT_HCI_TRANSPORT=%s (the kernel's H4 endpoint; sweetbt=6)\n", transport);
		}
		if (boot_arg(arguments, "sweetbtlog", value, sizeof(value)) != NULL && strcmp(value, "1") == 0) {
			hook_os_log(main_executable());
		}
		if (boot_arg(arguments, "sweetbtpatch", value, sizeof(value)) != NULL && strcmp(value, "0") == 0) {
			say("sweet-bt: bluetoothd: sweetbtpatch=0: not patching the BlueTool gate\n");
			return;
		}
		patch_bluetoothd();
	} else if (strcmp(name, "BlueTool") == 0) {
		/*
		 * Not needed any more (bluetoothd ignores BlueTool's result now); kept so injecting
		 * BlueTool is harmless and its launches stay visible in the log.
		 */
		char **argv = _NSGetArgv() != NULL ? *_NSGetArgv() : NULL;
		int argc = _NSGetArgc() != NULL ? *_NSGetArgc() : 0;

		for (int i = 0; argv != NULL && i < argc && argv[i] != NULL; i++) {
			say("sweet-bt: BlueTool argv[%d]=%s\n", i, argv[i]);
		}
	}
}
