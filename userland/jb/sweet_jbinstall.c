/*
 * sweet-jbinstall: puts a rootless jailbreak userland (Procursus, in /var/jb) and Sileo onto the iOS root that
 * is already on the phone, once. Started as root by libsweet-fix.dylib in usermanagerd (userland/fix) when
 * /private/var/sweet-jb/bootstrap.tar.xz is there and /var/jb/.sweet-jb-done is not; the files come with the
 * boot image (tools/jb-fetch.sh, tools/root-files/jb-install.txt). This port has no sandbox or code-signing
 * enforcement to defeat, so "jailbreaking" is only installing the userland:
 *
 *   1. the Procursus bootstrap (./var/jb/... entries only) unpacked to /var/jb: xz through libcompression,
 *      ustar/pax/GNU tar read here (files, directories, symlinks, hard links, owners, modes incl. setuid);
 *   2. after the system is up: NO_PASSWORD_PROMPT=1 /var/jb/prep_bootstrap.sh (Procursus' own first-run script);
 *   3. dpkg -i of Sileo's .deb, then uicache for Sileo.app (its icon on the home screen);
 *   4. /var/jb/.sweet-jb-done.
 *
 * Every step is written to /dev/console (the kernel log: "sweet-jb: ...") and /private/var/sweet-jb/install.log.
 * A failed step leaves no done marker: the next boot tries again from the first step not yet done.
 */
#include <compression.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define DIR_IN          "/private/var/sweet-jb"
#define ARCHIVE         DIR_IN "/bootstrap.tar.xz"
#define SILEO_DEB       DIR_IN "/sileo.deb"
#define LOG_FILE        DIR_IN "/install.log"
#define DONE            "/var/jb/.sweet-jb-done"
#define UNPACKED        "/var/jb/.sweet-jb-unpacked"
#define PREPPED         "/var/jb/.sweet-jb-prepped"

extern char **environ;
static FILE *logfile;
static int console = -1;

static void
say(const char *format, ...)
{
	char line[1024];
	va_list ap;
	int n;

	va_start(ap, format);
	n = vsnprintf(line, sizeof(line) - 1, format, ap);
	va_end(ap);
	if (n < 0) {
		return;
	}
	if (n > (int)sizeof(line) - 2) {
		n = (int)sizeof(line) - 2;
	}
	line[n++] = '\n';
	line[n] = 0;
	if (console >= 0) {
		(void)write(console, "sweet-jb: ", 10);
		(void)write(console, line, (size_t)n);
	}
	if (logfile != NULL) {
		fputs(line, logfile);
		fflush(logfile);
	}
}

/* ---- xz through libcompression, as a byte stream ---- */
static struct {
	int fd;
	compression_stream s;
	uint8_t in[1 << 16], out[1 << 16];
	size_t out_at, out_len;
	int in_eof, done;
} xz;

static int
xz_open(const char *path)
{
	xz.fd = open(path, O_RDONLY);
	if (xz.fd < 0 || compression_stream_init(&xz.s, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) != COMPRESSION_STATUS_OK) {
		return -1;
	}
	xz.s.src_size = 0;
	return 0;
}

/* n bytes of the unpacked stream into buf (buf NULL: skipped); 0 or -1 */
static int
xz_read(void *buf, size_t n)
{
	uint8_t *to = buf;

	while (n > 0) {
		if (xz.out_at < xz.out_len) {
			size_t k = xz.out_len - xz.out_at < n ? xz.out_len - xz.out_at : n;

			if (to != NULL) {
				memcpy(to, xz.out + xz.out_at, k);
				to += k;
			}
			xz.out_at += k;
			n -= k;
			continue;
		}
		if (xz.done) {
			return -1;
		}
		if (xz.s.src_size == 0 && !xz.in_eof) {
			ssize_t r = read(xz.fd, xz.in, sizeof(xz.in));

			if (r < 0) {
				return -1;
			}
			xz.in_eof = r == 0;
			xz.s.src_ptr = xz.in;
			xz.s.src_size = (size_t)r;
		}
		xz.s.dst_ptr = xz.out;
		xz.s.dst_size = sizeof(xz.out);
		compression_status st = compression_stream_process(&xz.s, xz.in_eof ? COMPRESSION_STREAM_FINALIZE : 0);
		if (st == COMPRESSION_STATUS_ERROR) {
			say("the archive does not decompress (xz)");
			return -1;
		}
		xz.out_at = 0;
		xz.out_len = sizeof(xz.out) - xz.s.dst_size;
		xz.done = st == COMPRESSION_STATUS_END && xz.out_len == 0;
	}
	return 0;
}

/* ---- tar ---- */
static uint64_t
tar_number(const char *p, size_t n)
{
	uint64_t v = 0;

	if ((unsigned char)p[0] & 0x80) {               /* base-256 */
		for (size_t i = 1; i < n; i++) {
			v = (v << 8) | (unsigned char)p[i];
		}
		return v;
	}
	for (size_t i = 0; i < n && p[i] != 0 && p[i] != ' '; i++) {
		if (p[i] >= '0' && p[i] <= '7') {
			v = v * 8 + (uint64_t)(p[i] - '0');
		}
	}
	return v;
}

/* "./var/jb/x" or "var/jb/x" -> "/var/jb/x"; NULL for anything outside /var/jb or with ".." */
static const char *
target_path(const char *name, char *out, size_t size)
{
	while (name[0] == '.' && name[1] == '/') {
		name += 2;
	}
	while (name[0] == '/') {
		name++;
	}
	if (strncmp(name, "var/jb", 6) != 0 || (name[6] != 0 && name[6] != '/') || strstr(name, "..") != NULL) {
		return NULL;
	}
	snprintf(out, size, "/%s", name);
	size_t len = strlen(out);
	while (len > 1 && out[len - 1] == '/') {
		out[--len] = 0;
	}
	return out;
}

static void
make_parents(const char *path)
{
	char tmp[1024];

	strlcpy(tmp, path, sizeof(tmp));
	for (char *p = tmp + 1; *p != 0; p++) {
		if (*p == '/') {
			*p = 0;
			(void)mkdir(tmp, 0755);
			*p = '/';
		}
	}
}

/* pax extended header: "len key=value\n" records; path and linkpath taken */
static void
pax_parse(const char *data, size_t size, char *path, char *link)
{
	size_t at = 0;

	while (at < size) {
		char *end;
		unsigned long len = strtoul(data + at, &end, 10);
		const char *rec = end + 1, *eq;

		if (len == 0 || at + len > size) {
			break;
		}
		eq = memchr(rec, '=', data + at + len - rec);
		if (eq != NULL) {
			size_t klen = (size_t)(eq - rec), vlen = (size_t)(data + at + len - 1 - (eq + 1));

			if (klen == 4 && memcmp(rec, "path", 4) == 0 && vlen < 1024) {
				memcpy(path, eq + 1, vlen);
				path[vlen] = 0;
			} else if (klen == 8 && memcmp(rec, "linkpath", 8) == 0 && vlen < 1024) {
				memcpy(link, eq + 1, vlen);
				link[vlen] = 0;
			}
		}
		at += len;
	}
}

static int
unpack(void)
{
	char hdr[512], name[1024], lnk[1024], long_name[1024] = "", long_link[1024] = "", path[1024], lpath[1024];
	unsigned files = 0, dirs = 0, links = 0, skipped = 0, failed = 0;
	static uint8_t buf[1 << 16];

	if (xz_open(ARCHIVE) != 0) {
		say("cannot open %s (%s)", ARCHIVE, strerror(errno));
		return -1;
	}
	for (;;) {
		if (xz_read(hdr, sizeof(hdr)) != 0) {
			break;
		}
		if (hdr[0] == 0) {
			break;                                  /* the end blocks */
		}
		uint64_t size = tar_number(hdr + 124, 12), padded = (size + 511) & ~511ull;
		char type = hdr[156];

		if (type == 'x' || type == 'L' || type == 'K') {
			char *data = malloc((size_t)padded + 1);

			if (data == NULL || xz_read(data, (size_t)padded) != 0) {
				free(data);
				return -1;
			}
			data[size] = 0;
			if (type == 'x') {
				pax_parse(data, (size_t)size, long_name, long_link);
			} else {
				strlcpy(type == 'L' ? long_name : long_link, data, sizeof(long_name));
			}
			free(data);
			continue;
		}
		if (long_name[0] != 0) {
			strlcpy(name, long_name, sizeof(name));
		} else if (memcmp(hdr + 257, "ustar", 5) == 0 && hdr[345] != 0) {
			snprintf(name, sizeof(name), "%.155s/%.100s", hdr + 345, hdr);
		} else {
			snprintf(name, sizeof(name), "%.100s", hdr);
		}
		if (long_link[0] != 0) {
			strlcpy(lnk, long_link, sizeof(lnk));
		} else {
			snprintf(lnk, sizeof(lnk), "%.100s", hdr + 157);
		}
		long_name[0] = long_link[0] = 0;
		mode_t mode = (mode_t)tar_number(hdr + 100, 8) & 07777;
		uid_t uid = (uid_t)tar_number(hdr + 108, 8);
		gid_t gid = (gid_t)tar_number(hdr + 116, 8);

		if (target_path(name, path, sizeof(path)) == NULL) {
			if (type != '5') {
				skipped++;
			}
			if (xz_read(NULL, (size_t)padded) != 0) {
				return -1;
			}
			continue;
		}
		make_parents(path);
		if (type == '5') {
			struct stat st;

			if (lstat(path, &st) != 0) {
				(void)mkdir(path, mode);
			}
			if (lstat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
				(void)lchown(path, uid, gid);
				(void)chmod(path, mode);
				dirs++;
			}
		} else if (type == '2') {
			(void)unlink(path);
			if (symlink(lnk, path) == 0) {
				(void)lchown(path, uid, gid);
				links++;
			} else {
				failed++;
			}
		} else if (type == '1') {
			(void)unlink(path);
			if (target_path(lnk, lpath, sizeof(lpath)) != NULL && link(lpath, path) == 0) {
				links++;
			} else {
				failed++;
			}
		} else if (type == '0' || type == 0 || type == '7') {
			(void)unlink(path);
			int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
			uint64_t left = size;

			while (left > 0) {
				size_t k = left < sizeof(buf) ? (size_t)left : sizeof(buf);

				if (xz_read(buf, k) != 0) {
					if (fd >= 0) {
						close(fd);
					}
					say("the archive ends inside %s", path);
					return -1;
				}
				if (fd >= 0 && write(fd, buf, k) != (ssize_t)k) {
					close(fd);
					fd = -1;
					failed++;
				}
				left -= k;
			}
			if (xz_read(NULL, (size_t)(padded - size)) != 0) {
				return -1;
			}
			if (fd >= 0) {
				close(fd);
				(void)chown(path, uid, gid);
				(void)chmod(path, mode);    /* after chown: setuid bits survive */
				files++;
			} else {
				failed++;
			}
			continue;
		} else {
			skipped++;
		}
		if (xz_read(NULL, (size_t)padded) != 0) {
			return -1;
		}
	}
	say("unpacked: %u files, %u directories, %u links; %u entries outside /var/jb or of other kinds skipped, %u failed",
	    files, dirs, links, skipped, failed);
	return failed == 0 && files > 0 ? 0 : -1;
}

/* run argv with a jailbreak PATH and without DYLD_ variables; its exit status, or -1 */
static int
run(const char *const argv[])
{
	static char *const env[] = {
		"PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
		"HOME=/var/root", "USER=root", "LOGNAME=root", "TERM=xterm", "NO_PASSWORD_PROMPT=1",
		"DEBIAN_FRONTEND=noninteractive", NULL
	};
	posix_spawn_file_actions_t fa;
	pid_t pid;
	int status = 0, err;

	posix_spawn_file_actions_init(&fa);
	if (logfile != NULL) {
		posix_spawn_file_actions_adddup2(&fa, fileno(logfile), 1);
		posix_spawn_file_actions_adddup2(&fa, fileno(logfile), 2);
	}
	err = posix_spawn(&pid, argv[0], &fa, NULL, (char *const *)argv, env);
	posix_spawn_file_actions_destroy(&fa);
	if (err != 0) {
		say("%s: cannot start (%s)", argv[0], strerror(err));
		return -1;
	}
	if (waitpid(pid, &status, 0) < 0) {
		return -1;
	}
	if (WIFSIGNALED(status)) {
		say("%s: killed by signal %d", argv[0], WTERMSIG(status));
		return -1;
	}
	say("%s: exit %d", argv[0], WEXITSTATUS(status));
	return WEXITSTATUS(status);
}

static void
touch(const char *path)
{
	int fd = open(path, O_WRONLY | O_CREAT, 0644);

	if (fd >= 0) {
		close(fd);
	}
}

int
main(void)
{
	struct stat st;

	console = open("/dev/console", O_WRONLY | O_NOCTTY | O_NONBLOCK);
	(void)mkdir(DIR_IN, 0755);
	logfile = fopen(LOG_FILE, "a");
	if (stat(DONE, &st) == 0) {
		return 0;
	}
	say("pid %d, uid %d: installing the jailbreak userland", getpid(), getuid());

	if (stat(UNPACKED, &st) != 0) {
		say("step 1: unpacking %s into /var/jb", ARCHIVE);
		if (unpack() != 0) {
			say("step 1 FAILED; trying again at the next boot");
			return 1;
		}
		touch(UNPACKED);
	}
	/* prep_bootstrap and uicache want lsd, containermanagerd and SpringBoard: let the boot finish */
	say("waiting 90 s for the system to come up");
	sleep(90);
	if (stat(PREPPED, &st) != 0) {
		const char *const prep[] = { "/var/jb/bin/sh", "/var/jb/prep_bootstrap.sh", NULL };

		say("step 2: Procursus' prep_bootstrap.sh");
		if (stat("/var/jb/prep_bootstrap.sh", &st) == 0 && run(prep) != 0) {
			say("step 2 FAILED; trying again at the next boot");
			return 1;
		}
		touch(PREPPED);
	}
	if (stat(SILEO_DEB, &st) == 0) {
		const char *const dpkg[] = { "/var/jb/usr/bin/dpkg", "-i", SILEO_DEB, NULL };
		const char *const uic[] = { "/var/jb/usr/bin/uicache", "-p", "/var/jb/Applications/Sileo.app", NULL };

		say("step 3: Sileo");
		if (run(dpkg) != 0) {
			say("step 3 FAILED (dpkg); trying again at the next boot");
			return 1;
		}
		(void)run(uic);
	}
	touch(DONE);
	say("DONE: /var/jb is installed%s", stat("/var/jb/Applications/Sileo.app", &st) == 0 ? ", Sileo is on the home screen" : "");
	return 0;
}
