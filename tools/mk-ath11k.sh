#!/bin/bash
# Build the Wi-Fi driver object for the kernel (xnu 0128): Linux's ath11k, unmodified, compiled as
# FreeBSD kernel code on FreeBSD's LinuxKPI headers (patched with wifi/lx/patches) and on wifi/lx,
# tied into one object that shows only its entry points (lx_prepare, lx_start, lx_stop, lx_transmit).
# Adapted from HackiOS's tools/mk-ath11k.sh (github.com/oosexgang/hackios-xnu-kernel, MIT) with the
# Xiaomi Mi 10 (umi) port's QCA6390 layer.
#
#   tools/mk-ath11k.sh LINUX FREEBSD KHDR OUT
#
#   LINUX    Linux 7.0.14 with drivers/net/wireless/ath/ath11k/ and spectral_common.h
#            (a sparse clone of github.com/gregkh/linux at v7.0.14 is enough)
#   FREEBSD  FreeBSD 15.1.0 with sys/ (a sparse clone of github.com/freebsd/freebsd-src, release/15.1.0)
#   KHDR     the kernel's hakios.lx.h, hakios.sta.h, hakios.qmi.h, hakios.qrtr.h (bsd/dev of the patched
#            tree; tools/xnu-series-file.py writes them from xnu/patches)
#   OUT      work directory; OUT/ath11k.o is the result
#
#   tools/mk-ath11k.sh --freebsd-paths     the parts of FREEBSD it reads (for a sparse checkout)
#
# CHECK_ONLY=1: compile every file and list what the objects want of the kernel, but do not link (for
# machines without Apple's ld; the CI build on macOS links). CC, LD, NM and TARGET (the kernel's own:
# it is built with the macOS SDK) may be overridden. Nothing of Linux or FreeBSD is kept in this
# repository.
set -e
FSYS="compat/linuxkpi sys arm64/include net net80211 netinet netinet6 vm kern tools libkern ddb
	security fs/pseudofs crypto opencrypto geom bsm isa cam rpc xdr x86/include ofed/include
	dev/pci dev/ofw dev/fdt dev/acpica dev/usb dev/iicbus dev/backlight
	contrib/ck/include contrib/dev/acpica/include contrib/libnv"
if [ "$1" = --freebsd-paths ]; then
	for d in $FSYS; do echo "/sys/$d/"; done
	exit 0
fi
[ $# -eq 4 ] || { sed -n '2,22p' "$0"; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LINUX=$(cd "$1" && pwd)
FREEBSD=$(cd "$2" && pwd)
KHDR=$(cd "$3" && pwd)
mkdir -p "$4"
B=$(cd "$4" && pwd)
W=$ROOT/wifi/lx
ATH=drivers/net/wireless/ath
CC=${CC:-clang}
LD=${LD:-ld}
NM=${NM:-nm}
TARGET=${TARGET:-arm64-apple-macos13.0}
for h in lx sta qmi qrtr; do
	[ -f "$KHDR/hakios.$h.h" ] || { echo "mk-ath11k.sh: no hakios.$h.h in $KHDR" >&2; exit 1; }
done

# --- the driver's sources: every file must say itself that it may be used so
rm -rf "$B/src"
mkdir -p "$B/src"
cp -R "$LINUX/$ATH/ath11k" "$B/src/ath11k"
cp "$LINUX/$ATH/spectral_common.h" "$B/src/"
for f in "$B"/src/ath11k/*.[ch] "$B/src/spectral_common.h"; do
	case "$(head -6 "$f")" in
	*"SPDX-License-Identifier: BSD-3-Clause-Clear"*) ;;
	*"Permission to use, copy, modify, and/or distribute this software"*) ;;      # (ISC, spelt out)
	*) echo "mk-ath11k.sh: $f does not carry the licence expected" >&2; exit 1 ;;
	esac
done

# --- FreeBSD's LinuxKPI and the kernel headers under it, with the layer's patches
rm -rf "$B/freebsd" "$B/gen" "$B/obj" "$B/out"
mkdir -p "$B/freebsd/sys"
for d in $FSYS; do
	mkdir -p "$B/freebsd/sys/$(dirname "$d")"
	cp -R "$FREEBSD/sys/$d" "$B/freebsd/sys/$d"
done
for p in "$W"/patches/*.patch; do
	patch -s -d "$B/freebsd" -p1 < "$p"
done
S=$B/freebsd/sys

# --- what FreeBSD's build would have generated: the interfaces of its device framework, and the
# option headers, which here say only that there is an Internet
mkdir -p "$B/gen"
(
	cd "$B/gen"
	ln -s "$S/arm64/include" machine
	for m in kern/device_if.m kern/bus_if.m dev/pci/pci_if.m dev/pci/pci_iov_if.m dev/pci/pcib_if.m \
		dev/iicbus/iicbus_if.m dev/iicbus/iicbb_if.m dev/backlight/backlight_if.m dev/usb/usb_if.m \
		dev/ofw/ofw_bus_if.m; do
		awk -f "$S/tools/makeobjops.awk" "$S/$m" -h
	done
	for o in h p q; do awk -f "$S/tools/vnode_if.awk" "$S/kern/vnode_if.src" -$o; done
	for o in $(grep -rhoE "opt_[a-z0-9_]+\.h" "$S" | sort -u) lkpi_iic_if.h; do : > "$o"; done
	printf '#define INET 1\n#define INET6 1\n' > opt_inet.h
	printf '#define INET6 1\n' > opt_inet6.h
	printf '#define SMP 1\n' > opt_global.h
)

# --- compile: the driver's files that are built so far, and the layer's
DRIVER="core hal qmi ce hw fw htc wmi mac reg peer dp dp_rx dp_tx hal_rx hal_tx dbring p2p"
CFLAGS="-target $TARGET -mkernel -mgeneral-regs-only -fno-builtin -fno-common -ffreestanding
	-fno-strict-aliasing -funsigned-char -nostdinc -std=gnu17 -O2 -g -w
	-D__FreeBSD__=15 -D_KERNEL -DKLD_MODULE -DHAVE_KERNEL_OPTION_HEADERS -include opt_global.h
	-I$W/include -I$B/gen -I$S -I$S/contrib/ck/include
	-I$S/compat/linuxkpi/common/include -I$S/compat/linuxkpi/dummy/include
	-include $S/compat/linuxkpi/common/include/linux/kconfig.h -DLINUXKPI_VERSION=70000"
DFLAGS="-I$B/src/ath11k -I$B/src -include $W/include/lx_prelude.h -DCONFIG_ATH11K_AHB -DCONFIG_ATH11K_DEBUG
	-DKBUILD_MODNAME=\"ath11k\" -DLX_HAKIOS_LX_H=\"$KHDR/hakios.lx.h\" -DLX_HAKIOS_QMI_H=\"$KHDR/hakios.qmi.h\""
mkdir -p "$B/obj" "$B/out"
compile() {		# compile SOURCE OBJECT [FLAGS]
	local src=$1 obj=$2
	shift 2
	$CC $CFLAGS "$@" -c "$src" -o "$obj" 2> "$obj.err" || rm -f "$obj"
}
for f in $DRIVER; do compile "$B/src/ath11k/$f.c" "$B/obj/ath11k_$f.o" $DFLAGS & done
for f in "$W"/src/*.c; do compile "$f" "$B/obj/lx_$(basename "$f" .c).o" $DFLAGS -I"$W/src" & done
wait
bad=
for f in "$B"/obj/*.err; do
	[ -s "$f" ] && [ ! -f "${f%.err}" ] && { echo "--- $(basename "$f" .o.err)"; grep -m6 -A3 "error:" "$f"; bad=1; }
done
[ -z "$bad" ] || exit 1
OBJECTS=$(for f in $DRIVER; do echo "$B/obj/ath11k_$f.o"; done; for f in "$W"/src/*.c; do echo "$B/obj/lx_$(basename "$f" .c).o"; done)

# --- what the objects still want. It may be one of three things: a call of the kernel's
# (hakios.lx.h, the QMI helpers, the C library functions XNU has under the same names), a function of
# a part of the driver that is not built yet (a stub each, which says its name and answers 0), or a
# mistake, which ends the build.
KERNEL="memcmp memcpy memmove memset strcmp strncmp strlen strchr strrchr strlcpy strlcat bzero
	snprintf vsnprintf __stack_chk_fail __stack_chk_guard"
$NM -u -j $OBJECTS 2>/dev/null | grep -v ':$' | grep -v '^$' | sed 's/^_//' | sort -u > "$B/out/wanted.txt"
# (defined somewhere among the objects themselves: not wanted from outside)
$NM -g -U -j $OBJECTS 2>/dev/null | grep -v ':$' | grep -v '^$' | sed 's/^_//' | sort -u > "$B/out/defined.txt"
comm -23 "$B/out/wanted.txt" "$B/out/defined.txt" > "$B/out/undefined.txt"
: > "$B/out/stubs.txt"
: > "$B/out/stubs.s"
missing=
for s in $(cat "$B/out/undefined.txt"); do
	case " $(echo $KERNEL) " in *" $s "*) continue ;; esac
	case $s in
	lx_os_*|qmi_*|hakios_qmi_*|section\$*) continue ;;
	ath11k_*|__ath11k_*) ;;
	*) echo "mk-ath11k.sh: nothing defines $s" >&2; missing=1; continue ;;
	esac
	echo "$s" >> "$B/out/stubs.txt"
	printf '\t.globl _%s\n_%s:\n\tadrp x0, 1f@PAGE\n\tadd x0, x0, 1f@PAGEOFF\n\tb _lx_stub\n\t.cstring\n1:\t.asciz "%s"\n\t.text\n\t.p2align 2\n' \
		"$s" "$s" "$s" >> "$B/out/stubs.s"
done
[ -z "$missing" ] || exit 1
grep -E '^(lx_os_|qmi_|hakios_qmi_)' "$B/out/undefined.txt" > "$B/out/kernel-calls.txt" || true
echo "mk-ath11k.sh: $(echo $OBJECTS | wc -w) objects compiled; $(wc -l < "$B/out/stubs.txt") functions stubbed" \
	"(out/stubs.txt); the kernel is asked for $(wc -l < "$B/out/kernel-calls.txt") calls (out/kernel-calls.txt)"
if [ -n "$CHECK_ONLY" ]; then
	exit 0
fi
$CC -target "$TARGET" -c "$B/out/stubs.s" -o "$B/out/stubs.o"
$LD -r -arch arm64 $OBJECTS -o "$B/out/all.o"
printf '_lx_prepare\n_lx_start\n_lx_stop\n_lx_transmit\n' > "$B/out/exported.txt"
$LD -r -arch arm64 -exported_symbols_list "$B/out/exported.txt" "$B/out/all.o" "$B/out/stubs.o" -o "$B/out/ath11k.o"
rm -f "$B/out/all.o"
echo "mk-ath11k.sh: $B/out/ath11k.o, $(wc -c < "$B/out/ath11k.o") bytes"
