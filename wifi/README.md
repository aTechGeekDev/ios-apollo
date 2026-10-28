# wifi/: the Wi-Fi driver's layer (QCA6390, xnu 0128)

`lx/` is HackiOS's Linux-compatibility layer for the Wi-Fi driver (github.com/oosexgang/hackios-xnu-kernel,
`wifi/lx`, MIT: `LICENSE.HackiOS`), with the Xiaomi Mi 10 (umi) port's QCA6390 versions of `src/lx_*.c`
(github.com/JopangJovan/hackios-xnu-kernel-umi, `devices/xiaomi-mi-10/overlays/wifi`, MIT). Apollo has the same
SoC and radio as the Mi 10.

`tools/mk-ath11k.sh` builds the driver: Linux 7.0.14's `drivers/net/wireless/ath/ath11k` (BSD-3-Clause-Clear) compiled
unmodified as FreeBSD 15.1 kernel code against FreeBSD's LinuxKPI headers (BSD-2-Clause, patched with `lx/patches`)
and this layer, tied into one object (`ath11k.o`) that the kernel links (xnu 0128, `SWEET_OBJECTS`). Neither Linux's
nor FreeBSD's sources are kept here: CI fetches them at pinned commits.

The kernel side of the interface is `bsd/dev/hakios.lx.h` of the kernel tree (from the patch series).
