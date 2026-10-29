/*
 * libsweet-bt.dylib: what the kernel puts into bluetoothd (and, later, BlueTool) so iOS's
 * Bluetooth stack talks to the QCA6390 the kernel brought up (sweet_bt.c, boot-arg sweetbt=6:
 * the firmware runs, the H4 kernel control "com.sweet.bluetooth" and the registry entry
 * "bluetooth" are up). Inserted with boot-arg
 *   sweetinject=/usr/local/lib/libsweet-bt.dylib:bluetoothd         (and later ...,BlueTool)
 * (xnu 0114's sweetinject + AMFI dyld policy; launchd drops DYLD_ variables itself).
 *
 * bluetoothd's HCI transport is named by the environment variable BT_HCI_TRANSPORT. launchd will
 * not let us edit its job's plist (apollo boot 46), so this sets the variable from the inserted
 * library's constructor, before bluetoothd's main() reads it. Its value
 *   H4:POSIX:com.sweet.bluetooth,115200
 * makes bluetoothd open the kernel's H4 endpoint: a stream kernel control of that name, to which
 * sweet_bt.c (sweetbt=6) answers "SWEET BT: H4: connected" and then bridges the bytes to the chip.
 * Boot-arg sweetbthci=STRING overrides the value (another endpoint name or baud); sweetbthci=0
 * leaves bluetoothd's own environment alone.
 *
 * Stage 2a (this): the transport environment only -- the data-first half of the Mi 10 port's
 * iOS-side work, to see from bluetoothd's own log how far it gets before the chip's answers or the
 * BlueTool boot handshake need more. BlueTool's RunBuiltinScript answer and bluetoothd's
 * compatibility edits come next.
 *
 * The output goes to stderr, which is the console log with bluetoothd (and BlueTool) in boot-arg
 * sweetnull. After the CoreAnimation bridge's sweet_ca.c (its constructor, getprogname() dispatch
 * and kern.bootargs reading), itself after HackiOS's userland/src/inject.c (MIT, LICENSE.HackiOS).
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

extern const char *getprogname(void);

#define BT_HCI_DEFAULT  "H4:POSIX:com.sweet.bluetooth,115200"

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

__attribute__((constructor))
static void
sweet_bt_init(void)
{
	char arguments[1024] = "";
	char value[256];
	size_t size = sizeof(arguments) - 1;
	const char *name = getprogname();
	const char *transport = BT_HCI_DEFAULT;

	if (name == NULL) {
		return;
	}
	(void)sysctlbyname("kern.bootargs", arguments, &size, NULL, 0);

	if (strcmp(name, "bluetoothd") == 0) {
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
		/* stage 2b: answer its RunBuiltinScript boot request (the kernel already ran the firmware) */
		say("sweet-bt: BlueTool started; observing (the chip is already up in the kernel)\n");
	}
}
