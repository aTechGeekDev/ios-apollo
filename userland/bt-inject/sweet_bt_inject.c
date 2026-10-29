/*
 * libsweet-bt.dylib: what the kernel puts into bluetoothd and BlueTool so iOS's Bluetooth stack
 * talks to the QCA6390 the kernel brought up (sweet_bt.c, boot-arg sweetbt=6: the firmware runs,
 * the H4 kernel control "com.sweet.bluetooth" and the registry entry "bluetooth" are up). Inserted
 * with boot-arg
 *   sweetinject=/usr/local/lib/libsweet-bt.dylib:bluetoothd,BlueTool
 * (xnu 0114's sweetinject + AMFI dyld policy; launchd drops DYLD_ variables itself).
 *
 * Two jobs, dispatched on getprogname() like the CoreAnimation bridge's sweet_ca.c:
 *
 * bluetoothd: its HCI transport is named by the environment variable BT_HCI_TRANSPORT, which
 *   launchd will not let us set in the job's plist (apollo boot 46), so this sets it from the
 *   inserted library's constructor before main() reads it. The value
 *     H4:POSIX:com.sweet.bluetooth,115200
 *   makes bluetoothd open the kernel's H4 endpoint (a stream kernel control of that name, to which
 *   sweet_bt.c answers "SWEET BT: H4: connected"). Boot-arg sweetbthci=STRING overrides it,
 *   sweetbthci=0 leaves bluetoothd's own environment alone.
 *
 * BlueTool: bluetoothd will not power the controller on until BlueTool's boot script finishes
 *   (boot 66/67: `exec BlueTool` loops, Settings spins forever). BlueTool -R can only open Apple's
 *   own transports (PCIe AppleConvergedTransport, ACIPC) -- not our UART chip, which the kernel
 *   already brought up -- so every command fails "Device not open yet" and the script never
 *   completes. This makes BlueTool's per-command executor a no-op that returns success, so the
 *   whole builtin script "succeeds" (result 0) and bluetoothd powers on and opens the H4 transport
 *   itself; the chip is already running, and bluetoothd sends its own HCI reset next. This is the
 *   Mi 10 port's umi_bluetool.c idea, found anew in this 20H392 BlueTool by disassembly. Boot-arg
 *   sweetbtpatch=0 skips the patch (then BlueTool runs unchanged, for comparison).
 *
 * The output goes to stderr, the console log with bluetoothd/BlueTool in boot-arg sweetnull.
 */
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <stdarg.h>
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
 * BlueTool (/usr/sbin/BlueTool, 20H392 build in bt-ios.tgz): the function at image offset 0x1ba48
 * (vmaddr 0x10001ba48) parses and runs one command line, writing its output to *x1 and returning a
 * status; the RunBuiltinScript handler loops it over the script's lines and replies with the last
 * status as "result". Replacing it with `str xzr, [x1]; mov w0, #0; ret` makes every line a
 * successful no-op (null output, status 0). If the first word is not the expected prologue the
 * build differs and the patch is refused.
 */
#define BLUETOOL_EXEC_OFFSET 0x1ba48u
#define BLUETOOL_EXEC_ORIG   0xa9bb6ffcu   /* stp x28, x27, [sp, #-0x50]! */

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

/* Make BlueTool's builtin boot/init script always succeed (see the header comment). */
static void
patch_bluetool(void)
{
	static const uint32_t patch[3] = { 0xf900003fu, 0x52800000u, 0xd65f03c0u };  /* str xzr,[x1]; mov w0,#0; ret */
	const struct mach_header *base = _dyld_get_image_header(0);     /* image 0 is always the main program */
	uint32_t *at, orig;
	vm_address_t page;
	vm_size_t span;
	kern_return_t kr;
	uintptr_t ps = (uintptr_t)getpagesize();

	if (base == NULL) {
		say("sweet-bt: BlueTool: no image base; not patched\n");
		return;
	}
	at = (uint32_t *)((uintptr_t)base + BLUETOOL_EXEC_OFFSET);
	orig = *at;
	if (orig != BLUETOOL_EXEC_ORIG) {
		say("sweet-bt: BlueTool: executor at %p is %#x, not %#x: NOT patched (different build?)\n",
		    (void *)at, orig, BLUETOOL_EXEC_ORIG);
		return;
	}
	page = (vm_address_t)((uintptr_t)at & ~(ps - 1));
	span = (vm_size_t)((((uintptr_t)at + sizeof(patch)) - page + ps - 1) & ~(ps - 1));
	kr = vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
	if (kr != KERN_SUCCESS) {
		say("sweet-bt: BlueTool: vm_protect(rw) at %p failed (%d); not patched\n", (void *)page, kr);
		return;
	}
	at[0] = patch[0];
	at[1] = patch[1];
	at[2] = patch[2];
	(void)vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
	sys_icache_invalidate(at, sizeof(patch));
	say("sweet-bt: BlueTool: command executor no-op'd (%#x -> %#x); the builtin script now succeeds, "
	    "so bluetoothd can power on\n", orig, *at);
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

		if (boot_arg(arguments, "sweetbthci", value, sizeof(value)) != NULL) {
			if (strcmp(value, "0") == 0) {
				say("sweet-bt: bluetoothd: sweetbthci=0: leaving BT_HCI_TRANSPORT as it is\n");
				return;
			}
			transport = value;
		}
		setenv("BT_HCI_TRANSPORT", transport, 1);
		say("sweet-bt: bluetoothd: BT_HCI_TRANSPORT=%s (the kernel's H4 endpoint; sweetbt=6)\n", transport);
	} else if (strcmp(name, "BlueTool") == 0) {
		char **argv = _NSGetArgv() != NULL ? *_NSGetArgv() : NULL;
		int argc = _NSGetArgc() != NULL ? *_NSGetArgc() : 0;

		for (int i = 0; argv != NULL && i < argc && argv[i] != NULL; i++) {
			say("sweet-bt: BlueTool argv[%d]=%s\n", i, argv[i]);
		}
		if (boot_arg(arguments, "sweetbtpatch", value, sizeof(value)) != NULL && strcmp(value, "0") == 0) {
			say("sweet-bt: BlueTool: sweetbtpatch=0: not patching\n");
			return;
		}
		patch_bluetool();
	}
}
