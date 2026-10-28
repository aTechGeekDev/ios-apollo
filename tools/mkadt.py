#!/usr/bin/env python3
"""Build the minimal Apple Device Tree that the SWEET xnu needs to boot.

Only what the early boot path actually reads (see NOTES.md); every MMIO
address comes from the sweet live FDT. Usage:
  mkadt.py OUT.adt [--dump] [--qemu] [--highmem] [--p3] [--touch-fw FW.bin] [--gmu-fw a650_gmu.bin]
            [--sqe-fw a650_sqe.fw] [--zap-mdt a650_zap.mdt] [--zap-seg a650_zap.b02] [--wifi-fw DIR|amss.bin] [--wifi-board FILE] [--wifi-mac aa:bb:cc:dd:ee:ff]
            [--bt-fw DIR]
/product says the display is sRGB, not the iPhone X's P3 (--p3 keeps P3): see build().
--file /usr/local/PATH=LOCAL (as many as wanted) carries a file in /sweet-files; the kernel
writes it onto the root before launchd starts (xnu 0120-0122, bsd/dev/sweet_files.c): a new
build of the CoreAnimation bridge or of Mesa without a new root image. --files-from LIST: the
same for every line "DEST=LOCAL [UID:GID:MODE]" of LIST (owner and octal mode; default root,
0755 under /usr/local/, 0644 elsewhere; folders made on the way get the owner), and a line
"-DEST" (or --delete DEST) removes DEST first, a line "?PATH" (or --list PATH) prints PATH's
matches (a folder: its entries) into the kernel log; in those two a component may hold one '*'
(xnu 0123; only files are removed that way). A line ">FROM=TO" (or --move FROM=TO) renames a file
or folder on the root, unless something is at TO already (xnu 0140; after the removals, before the
files). tools/wallpaper-files.py writes such lists; tools/root-files/ has settings. Only
FILE_PREFIXES paths; 64 files and 48 MiB at most.
--touch-fw embeds the NT36675 touch firmware (Xiaomi's
novatek_nt36675_j3s_fw01.bin, not in git) as /sweet-touch "firmware"; the
apollo touch driver downloads it into the chip over SPI. --gmu-fw embeds the
Adreno 650 GMU firmware (from the phone's /vendor/firmware, not in git) as
/sweet-gpu "gmu-firmware" for sweet_gpu.c (sweetgpu=11 and up). --sqe-fw adds
the 3D core's microcode as "sqe-firmware" (sweetgpu=18 and up). --zap-mdt and
--zap-seg add the GPU zap shader's metadata (a650_zap.mdt) and its loadable
segment (a650_zap.b02) as "zap-metadata" / "zap-segment"; TrustZone unlocks
the 3D core from secure mode with them (sweetgpu=20 and up). --wifi-fw embeds the
QCA6390 Wi-Fi firmware (the phone's amss20.bin / amss.bin, tools/pull-wifi-fw.sh, not in git)
as /sweet-wifi "amss" for sweet_wifi.c (sweetwifi=4 and up, xnu 0126). Given the folder
(research/apollo-wifi/) it also carries m3.bin as "m3", regdb.bin as "regdb" and the board file
(the one bdwlan*/bd_* .elf there, bd_j3sgl.elf if there are several, or --wifi-board FILE) as "board" for sweet_wlfw.c (sweetwifi=9,
xnu 0127). --bt-fw DIR embeds the QCA6390 Bluetooth firmware (the phone's htbtfw20.tlv and
htnv20.bin, tools/pull-bt-fw.sh, not in git) as /sweet-bt "patch" and "nvm" for sweet_bt.c
(sweetbt=5 and up, xnu 0136); its address is the Wi-Fi's + 1 (/chosen mac-address-bluetooth0,
made with --wifi-fw).
"""
import hashlib, os, re, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402

# Kernel-managed RAM: above every Qualcomm XPU carve-out (see NOTES.md)
PHYS_BASE = 0xb0000000
MEM_SIZE = 0x4d000000
# Panic log buffer, carved from the TOP of the dram range and exposed to XNU as
# /pram + /chosen/embedded-panic-log-size. Without it, pe_init.c's
# check_for_panic_log() leaves gPanicBase == 0, debug_log_init() bails out twice
# and the kernel hangs right after "kdp_core zlib memory" — reproduced on QEMU
# and independently on ios-fajita.
PANIC_LOG_SIZE = 0x100000
# --highmem (phone only): the whole upper DDR bank. The live FDT memory node is
# <0x80000000 2G>, <0x1_00000000 0xfcc00000>; every fixed reserved-memory
# carve-out is in the low bank and the dynamic pools are limited below 4G.
HIGH_PHYS_BASE = 0x100000000
# apollo: 4 GiB from 0x1_00000000 (sweet used 0xfcc00000); not yet checked
# against apollo's /memory node
HIGH_MEM_SIZE = 0x100000000
# /arm-io children are relative to this; it must not be 0 (serial_init bails)
SOC_BASE = 0x01000000

GICD, GICD_SIZE = 0x17a00000, 0x10000
GICR, GICR_SIZE = 0x17a60000, 0x100000
# cont_splash_region@9c000000 from live.dts = 0x2300000
FB, FB_SIZE = 0x9c000000, 0x2300000
SWEET_ECID = 0x5357454554000001  # 'SWEET' + 1, synthetic
# Mi 10T 5G 1080x2400, a8r8g8b8
FB_W, FB_H, FB_STRIDE = 1080, 2400, 1080 * 4
# Internal UFS host (ufshc@1d84000 "ufs_mem"); QEMU virt has none
UFS, UFS_SIZE = 0x01d84000, 0x3000
TIMEBASE = 19200000
VTIMER_INTID = 27
# QEMU virt (-M virt,gic-version=3 -cpu cortex-a76): GICD/GICR and the generic timer's CNTFRQ
QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE = 0x08000000, 0x080a0000, 62500000
QEMU_VTIMER_INTID = 27

BOOT_MANIFEST_HASH = hashlib.sha384(b'sweet boot manifest').digest()

# The iOS userland is the iPhone X (iPhone10,3 / D22AP) IPSW. MobileGestalt
# derives product type, device class, home-button-less UI, artwork etc. from
# the root identity and /product of the real D22AP device tree. That tree is
# an Apple artifact (kept out of git): extract it from the IPSW with
#   tools/remotezip.py URL DeviceTree.d22ap.im4p DIR
#   ipsw img4 im4p extract DIR/Firmware/all_flash/DeviceTree.d22ap.im4p -o d22ap.adt
# the paths the kernel writes (xnu 0120/0121 bsd/dev/sweet_files.c sweet_files_prefixes)
FILE_PREFIXES = ('/usr/local/', '/Library/Wallpaper/', '/private/var/', '/System/Library/xpc/',
                 # the sound (tools/root-files/audio-on.txt): iOS's VirtualAudio.plugin and our HakiosAudio.driver
                 '/Library/Audio/Plug-Ins/', '/System/Library/Audio/Plug-Ins/HAL/')
D22AP_ADT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../research/ipsw-x/d22ap.adt')


def d22ap_product(path=D22AP_ADT):
    """/product properties of the real D22AP tree, without the syscfg
    placeholders iBoot would fill in (flag bit set) and the node bookkeeping."""
    if not os.path.exists(path):
        print(f'warning: {path} missing, no /product node', file=sys.stderr)
        return None
    root, _ = adt.parse(open(path, 'rb').read())
    for c in root.children:
        if dict((k, v) for k, f, v in c.props).get('name') == b'product\0':
            return [(k, v) for k, f, v in c.props if not f and k not in ('name', 'AAPL,phandle')]
    raise SystemExit(f'{path}: no /product node')

u32 = lambda *v: struct.pack('<%dI' % len(v), *v)
u64 = lambda *v: struct.pack('<%dQ' % len(v), *v)
cstr = lambda s: s.encode() + b'\0'


def node(name, props=(), children=()):
    n = adt.Node()
    n.props = [('name', 0, cstr(name))] + [(k, 0, v) for k, v in props]
    n.children = list(children)
    return n


def build(seed=None, qemu=False, highmem=False, touch_fw=None, gmu_fw=None, gpu_extra=(), p3=False, files=(),
          deletes=(), lists=(), wifi=(), macs=(), bt=(), moves=()):
    """qemu=True: same tree, but with QEMU virt's GIC addresses and CNTFRQ (tools/qemu-sweet.py)."""
    phys_base, mem_size = (HIGH_PHYS_BASE, HIGH_MEM_SIZE) if highmem else (PHYS_BASE, MEM_SIZE)
    # Carve the panic log off the top so the kernel never allocates over it.
    panic_base = phys_base + mem_size - PANIC_LOG_SIZE
    mem_size -= PANIC_LOG_SIZE
    gicd, gicr, timebase = (QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE) if qemu else (GICD, GICR, TIMEBASE)
    seed = seed if seed is not None else os.urandom(64)
    phandle = iter(range(1, 1000))
    ph = lambda: ('AAPL,phandle', u32(next(phandle)))

    chosen = node('chosen', [
        ph(),
        ('dram-base', u64(phys_base)),
        ('dram-size', u64(mem_size)),
        ('random-seed', seed),
        ('debug-enabled', u32(1)),
        ('embedded-panic-log-size', u32(PANIC_LOG_SIZE)),
        ('firmware-version', cstr('sweet-shim')),
        ('system-firmware-version', cstr('sweet-shim')),
        # iBoot's SHA-384 of the boot manifest; /sbin/mount -P 1 exits unless
        # it exists (bind mounts /private/preboot/<hex>/usr/standalone/firmware,
        # tolerating a missing directory). Fixed stand-in value.
        ('boot-manifest-hash', BOOT_MANIFEST_HASH),
        # libimg4 (cryptexd) aborts "failed to get crypto algorithm" without
        # it; real A11+ device trees say sha2-384.
        ('crypto-hash-method', cstr('sha2-384')),
        # MobileGestalt's screen class: display-scale (u32, default 0) comes
        # from /chosen, the pixel size from IOMobileFramebuffer. Scale 0 makes
        # SpringBoard's FBSDisplayMode "infxinf@0x" invalid. 1080x2400 @3x =
        # 360x800 points (like iPhone X class devices).
        ('display-scale', u32(3)),
        # XNU derives IOPlatformUUID (gethostuuid) from these on arm; without
        # them CFPreferences cannot use kCFPreferencesCurrentHost (no ByHost
        # files), so e.g. DataMigration never records LastSystemVersion and
        # migrates on every boot. Synthetic ECID (not the phone's); chip-id
        # of the A11 that the iPhone X userland expects.
        ('unique-chip-id', struct.pack('<Q', SWEET_ECID)),
        ('chip-id', u32(0x8015)),
        # Security status as on a dev-fused, undemoted board (tuple 0,0,1,1):
        # MobileGestalt reads these from /chosen, and mobileactivationd's
        # DeviceType then takes its native "Hactivation" branch (state
        # Activated without an activation record; no SEP, no baseband here).
        ('certificate-production-status', u32(0)),
        ('effective-production-status-ap', u32(0)),
        ('certificate-security-mode', u32(1)),
        ('effective-security-mode-sep', u32(1)),
        # The device's MAC addresses, as iBoot puts them here (--wifi-fw): without them MobileGestalt
        # waits for an IONetworkController on every Wi-Fi address query (Settings > About), as
        # iOSPlus10 found; mac-address-wifi0 is also en0's address (sweet_wifi.c, xnu 0129).
    ] + [(f'mac-address-{name}', mac) for name, mac in macs], [node('memory-map', [ph()]),
        # Local boot policy (kern_csr.c): SIP relaxed like `csrutil disable`
        # (lp-sip0: untrusted kexts, unrestricted FS, task_for_pid, kernel
        # debugger, dtrace, nvram), lp-sip1: unauthenticated (unsealed) root.
        # The iOS shared cache is in no trust cache, so dyld can only map it
        # with CSR_ALLOW_UNRESTRICTED_FS (vm_unix.c shared region checks).
        node('asmb', [ph(), ('lp-sip0', u64(0x6f)), ('lp-sip1', u32(1))])])

    # SWEET SMP: all eight cores in physical-core order (0-5 Cortex-A55,
    # 6-7 Cortex-A76), one homogeneous cluster. The kernel defaults to one
    # and uses cpus=N to select an initial prefix (N <= 8).
    # QEMU retains its original single-CPU tree: its MPIDRs differ from sweet.
    cpu_nodes = []
    for core in range(1 if qemu else 8):
        cpu_nodes.append(node(f'cpu{core}', [
            ph(),
            ('device_type', cstr('cpu')),
            ('compatible', cstr('qcom,kryo470') + cstr('ARM,v8')),
            ('reg', u32(core << 8)),  # actual MPIDR Aff1:Aff0, NOT logical ID
            ('cpu-id', u32(core)),   # descriptive: XNU assigns IDs by DT order
            ('cluster-id', u32(0)),  # descriptive; see ml_parse_cpu_topology
            ('cluster-type', u32(0)),  # homogeneous CLUSTER_TYPE_SMP, not AMP
            ('die-cluster-id', u32(0)),
            ('cluster-core-id', u32(core)),
            ('l2-cache-id', u32(core)),  # distinct per-core L2 nodes in live FDT
            ('l3-cache-id', u32(0)),     # shared L3
            ('state', cstr('running' if core == 0 else 'stopped')),
            ('timebase-frequency', u32(timebase)),
            ('clock-frequency', u32(2304000000 if core >= 6 else 1804800000)),
            ('bus-frequency', u32(100000000)),
            ('memory-frequency', u32(1866000000)),
            ('peripheral-frequency', u32(timebase)),
            ('fixed-frequency', u32(timebase)),
        ]))
    cpus = node('cpus', [ph(), ('#address-cells', u32(1)),
                         ('#size-cells', u32(0))], cpu_nodes)

    gic = node('gic', [
        ph(),
        ('compatible', cstr('arm,gic-v3')),
        ('interrupt-controller', b''),
        ('virtual-timer-intid', u32(QEMU_VTIMER_INTID if qemu else VTIMER_INTID)),
        ('reg', u64(gicd - SOC_BASE, GICD_SIZE, gicr - SOC_BASE, GICR_SIZE)),
    ])
    arm_io = node('arm-io', [
        ph(),
        ('device_type', cstr('sweet-io')),
        ('compatible', cstr('sweet-io') + cstr('arm-io')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
        ('ranges', u64(0, SOC_BASE, 0x100000000 - SOC_BASE)),
    ], [gic,
        # No hardware: watchdogd checks IODeviceTree:/arm-io/wdt for no-pmu and
        # otherwise crashes trying to set the PMU boot stage (customer builds
        # ignore the -wdt_no_pmu boot-arg).
        node('wdt', [ph(), ('no-pmu', u32(1))]),
        # Main display: IOMobileFramebuffer.framework counts /arm-io children
        # with this device_type and reads the canvas size from the node
        # (the presented iPhone X size, see SweetFramebuffer.cpp);
        # the kernel's AppleCLCD matches the compatible string.
        node('disp0', [
            ph(),
            ('device_type', cstr('display-subsystem')),
            ('compatible', cstr('sweet,display')),
            ('canvas-width', u32(1125)),
            ('canvas-height', u32(2436)),
        ])] + (
        # launchd starts wifid only when the device tree has a node named "wlan" or "marconi-wifi"
        # (com.apple.wifid _LimitLoadToDeviceTree; launchd asks io_device_tree_entry_exists_with_name):
        # without it Settings shows Wi-Fi greyed out (boot 53). As iOSPlus10 and ios-spes found.
        # Only with --wifi-fw: the radio's driver (sweetwifi=12) is what wifid then talks to.
        [node('wlan', [
            ph(),
            ('device_type', cstr('wlan')),
            ('compatible', cstr('apollo,qca6390')),
        ])] if wifi else []))

    fbcon = node('sweet-fbcon', [
        ph(),
        ('reg', u64(FB, FB_SIZE)),
        ('width', u32(FB_W)),
        ('height', u32(FB_H)),
        ('stride', u32(FB_STRIDE)),
    ])

    # bsd/dev/sweet_ufs.c: the UFS host ABL leaves running (absolute physical reg).
    ufs = node('sweet-ufs', [
        ph(),
        ('compatible', cstr('qcom,ufshc')),
        ('reg', u64(UFS, UFS_SIZE)),
    ])

    # pmap_compute_max_asids requires the node even when no overrides are set.
    # An absent pmap-max-asids property selects XNU's own MAX_ASIDS default.
    # No effaceable storage: keybagd then reads /private/var/keybags/systembag.kb
    # as a plain plist instead of decrypting it with the effaceable key.
    defaults = node('defaults', [ph(), ('no-effaceable-storage', u32(1))])

    # MobileGestalt HomeButtonType = IODeviceTree:/buttons home-button-type
    # (D22AP: 2, no Home button; absent = 0 = Home-button device).
    buttons = node('buttons', [
        ph(),
        ('button-names', cstr('volup') + cstr('voldown') + cstr('hold')),
        ('home-button-type', u32(2)),
        ('opposed-power-vol-buttons', u32(1)),
    ])

    product_props = d22ap_product()
    if product_props and not p3:
        # The panel gets 8-bit 'BGRA' (the kernel copies every frame as such). With the iPhone X's
        # "P3", iOS picks deep-colour surfaces: with a GPU renderer CoreAnimation draws the screen
        # in 'b3a8' (apollo boots 35/36: the CoreAnimation bridge, backboardd crash loop), and
        # MaterialKit's 'b3a8' / CoreAnimation's 'w30r' snapshots are ones its software renderer
        # cannot draw into (white dock backgrounds; as ios-sailfish found). MobileGestalt reads
        # these two at the first boot of a root.
        product_props = [(k, cstr('sRGB') if k in ('artwork-display-gamut', 'display-gamut') else v)
                         for k, v in product_props]
    product = [node('product', [ph()] + product_props)] if product_props else []

    # Panic log region. /pram reg = <phys size>; it sits just above the
    # dram-size we expose, so XNU maps it but never allocates into it.
    pram = node('pram', [ph(), ('reg', u64(panic_base) + u64(PANIC_LOG_SIZE))])

    # Identity of the iPhone X whose userland runs here: compatible[0] is
    # hw.model/hw.target (D22AP), model is hw.machine/hw.product
    # (iPhone10,3). 'xiaomi,sweet' MUST stay — SweetPlatformExpert matches
    # only that string (patch 0016). Keep apollo/sm8250 for identification.
    return node('device-tree', [
        ph(),
        ('compatible', cstr('D22AP') + cstr('iPhone10,3') + cstr('xiaomi,sweet') + cstr('xiaomi,apollo') + cstr('qcom,sm8250') + cstr('AppleARM')),
        ('model', cstr('iPhone10,3')),
        ('target-type', cstr('D22')),
        ('target-sub-type', cstr('D22AP')),
        ('manufacturer', cstr('Apple Inc.')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
    ], [chosen, defaults, cpus, arm_io, fbcon, buttons, pram] + product + ([] if qemu else [ufs]) +
       ([node('sweet-touch', [ph(), ('firmware', touch_fw)])] if touch_fw else []) +
       ([node('sweet-gpu', [ph(), ('gmu-firmware', gmu_fw)] + list(gpu_extra))] if gmu_fw else []) +
       ([node('sweet-wifi', [ph()] + list(wifi))] if wifi else []) +
       ([node('sweet-bt', [ph()] + list(bt))] if bt else []) +
       ([node('sweet-files', [ph()] + [(f'list{i}', path.encode() + b'\0') for i, path in enumerate(lists)]
                              + [(f'delete{i}', path.encode() + b'\0') for i, path in enumerate(deletes)]
                              + [(f'move{i}', a.encode() + b'\0' + b.encode() + b'\0') for i, (a, b) in enumerate(moves)]
                              + [(f'file{i}', path.encode() + b'\0' + data) for i, (path, data, _) in enumerate(files)]
                              + [(f'owner{i}', struct.pack('<3I', *owner))
                                 for i, (_, _, owner) in enumerate(files) if owner is not None])]
        if files or deletes or lists or moves else []))


if __name__ == '__main__':
    touch_fw = None
    if '--touch-fw' in sys.argv:
        touch_fw = open(sys.argv[sys.argv.index('--touch-fw') + 1], 'rb').read()
        print(f'touch firmware: {len(touch_fw)} bytes', file=sys.stderr)
    gmu_fw = None
    if '--gmu-fw' in sys.argv:
        gmu_fw = open(sys.argv[sys.argv.index('--gmu-fw') + 1], 'rb').read()
        print(f'GMU firmware: {len(gmu_fw)} bytes', file=sys.stderr)
    gpu_extra = []
    if '--sqe-fw' in sys.argv:
        sqe = open(sys.argv[sys.argv.index('--sqe-fw') + 1], 'rb').read()
        print(f'SQE microcode: {len(sqe)} bytes', file=sys.stderr)
        gpu_extra.append(('sqe-firmware', sqe))
    if '--zap-mdt' in sys.argv:
        zap_mdt = open(sys.argv[sys.argv.index('--zap-mdt') + 1], 'rb').read()
        print(f'zap metadata: {len(zap_mdt)} bytes', file=sys.stderr)
        gpu_extra.append(('zap-metadata', zap_mdt))
    if '--zap-seg' in sys.argv:
        zap_seg = open(sys.argv[sys.argv.index('--zap-seg') + 1], 'rb').read()
        print(f'zap segment: {len(zap_seg)} bytes', file=sys.stderr)
        gpu_extra.append(('zap-segment', zap_seg))
    if gpu_extra and not gmu_fw:
        sys.exit('--sqe-fw, --zap-mdt and --zap-seg need --gmu-fw')
    wifi = []                                   # (property, bytes) of /sweet-wifi
    macs = []                                   # (name, 6 bytes) for /chosen mac-address-NAME
    if '--wifi-fw' in sys.argv:
        where = sys.argv[sys.argv.index('--wifi-fw') + 1]
        if not os.path.exists(where):
            sys.exit(f'--wifi-fw {where}: not there. Pull the firmware from the phone first (in recovery): '
                     'tools/pull-wifi-fw.sh')
        picked = {}
        if os.path.isdir(where):
            names = sorted(os.listdir(where))
            lower = {n.lower(): n for n in names}       # (FAT names may come in capitals: AMSS20.BIN)
            for prop, choices in (('amss', ('amss20.bin', 'amss.bin')), ('m3', ('m3.bin',)), ('regdb', ('regdb.bin',))):
                found = [lower[n] for n in choices if n in lower]
                if found:
                    picked[prop] = os.path.join(where, found[0])
            boards = [n for n in names if re.fullmatch(r'(bdwlan|bd_).*\.elf', n, re.I)]
            if '--wifi-board' in sys.argv:
                picked['board'] = sys.argv[sys.argv.index('--wifi-board') + 1]
            elif len(boards) == 1:
                picked['board'] = os.path.join(where, boards[0])
            elif 'bd_j3sgl.elf' in [n.lower() for n in boards]:
                # the modem partition carries the board files of several Xiaomi phones; apollo is J3S, and
                # j3sgl its global version (bd_j3s.elf: China, the Redmi K30S Ultra; bd_j3sin.elf: India)
                picked['board'] = os.path.join(where, [n for n in boards if n.lower() == 'bd_j3sgl.elf'][0])
                print('Wi-Fi board: several there; bd_j3sgl.elf (apollo, global) taken; --wifi-board FILE for another',
                      file=sys.stderr)
            elif boards:
                sys.exit(f'--wifi-fw {where}: board files {", ".join(boards)}: say which with --wifi-board FILE')
        else:
            picked['amss'] = where
            if '--wifi-board' in sys.argv:
                picked['board'] = sys.argv[sys.argv.index('--wifi-board') + 1]
        if 'amss' not in picked:
            sys.exit(f'--wifi-fw {where}: no amss20.bin or amss.bin')
        for prop in ('amss', 'm3', 'regdb', 'board'):
            if prop in picked:
                data = open(picked[prop], 'rb').read()
                wifi.append((prop, data))
                print(f'Wi-Fi {prop}: {picked[prop]}, {len(data)} bytes', file=sys.stderr)
        if not 512 * 1024 <= len(wifi[0][1]) <= 16 << 20:
            sys.exit('--wifi-fw: the QCA6390 firmware (amss) is between 512 KiB and 16 MiB')
        if 'board' in picked and len(dict(wifi)['board']) > 256 * 1024:
            sys.exit('--wifi-board: a board file of more than 256 KiB is not one the firmware takes')
        # The radio's address: --wifi-mac, else the one kept in the firmware folder (made once, at random,
        # locally administered: never in git), so that it stays the same from boot to boot.
        mac_text = sys.argv[sys.argv.index('--wifi-mac') + 1] if '--wifi-mac' in sys.argv else None
        mac_file = os.path.join(where, 'mac.txt') if os.path.isdir(where) else None
        if mac_text is None and mac_file and os.path.exists(mac_file):
            mac_text = open(mac_file).read().strip()
        if mac_text is None:
            made = bytearray(os.urandom(6))
            made[0] = (made[0] & 0xfe) | 0x02
            mac_text = ':'.join(f'{b:02x}' for b in made)
            if mac_file:
                with open(mac_file, 'w') as f:
                    f.write(mac_text + '\n')
        if not re.fullmatch(r'([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', mac_text) or int(mac_text[:2], 16) & 1:
            sys.exit(f'--wifi-mac {mac_text}: not a station address (aa:bb:cc:dd:ee:ff, first byte even)')
        wifi_mac = bytes(int(x, 16) for x in mac_text.split(':'))
        # Bluetooth and Ethernet: the next two, as on Apple's devices
        macs = [(name, wifi_mac[:5] + bytes([(wifi_mac[5] + i) & 0xff])) for i, name in
                enumerate(('wifi0', 'bluetooth0', 'ethernet0'))]
        print(f'Wi-Fi address (/chosen mac-address-wifi0, en0): {"--wifi-mac" if "--wifi-mac" in sys.argv else mac_file or "random"}',
              file=sys.stderr)
    bt = []                                     # (property, bytes) of /sweet-bt
    if '--bt-fw' in sys.argv:
        where = sys.argv[sys.argv.index('--bt-fw') + 1]
        if not os.path.isdir(where):
            sys.exit(f'--bt-fw {where}: not a folder. Pull the firmware from the phone first (in recovery): '
                     'tools/pull-bt-fw.sh')
        lower = {n.lower(): n for n in os.listdir(where)}
        for prop, name, low, high in (('patch', 'htbtfw20.tlv', 28, 512 * 1024), ('nvm', 'htnv20.bin', 16, 16 * 1024)):
            if name not in lower:
                sys.exit(f'--bt-fw {where}: no {name} (tools/pull-bt-fw.sh puts it there)')
            data = open(os.path.join(where, lower[name]), 'rb').read()
            # (the kernel checks the same: a TLV whose 3-byte length is the rest of the file)
            if not low <= len(data) <= high or int.from_bytes(data[1:4], 'little') != len(data) - 4:
                sys.exit(f'--bt-fw: {name} ({len(data)} bytes) is not a QCA firmware record of {low} to {high} bytes')
            bt.append((prop, data))
            print(f'Bluetooth {prop}: {name}, {len(data)} bytes', file=sys.stderr)
        if not macs:
            print('Bluetooth: no --wifi-fw, so no /chosen mac-address-bluetooth0: the chip keeps its NVM address',
                  file=sys.stderr)
    files, deletes, lists, moves = [], [], [], []   # (path, data, (uid, gid, mode) or None); paths; paths; (from, to)
    wanted = []                                 # (where it came from, "DEST=LOCAL [UID:GID:MODE]" or "-DEST")
    for i, arg in enumerate(sys.argv):
        if arg == '--file':
            wanted.append(('--file', sys.argv[i + 1]))
        elif arg == '--delete':
            wanted.append(('--delete', '-' + sys.argv[i + 1]))
        elif arg == '--list':
            wanted.append(('--list', '?' + sys.argv[i + 1]))
        elif arg == '--move':
            wanted.append(('--move', '>' + sys.argv[i + 1]))
        elif arg == '--files-from':
            wanted += [(f'{sys.argv[i + 1]} line {n}', line.strip())
                       for n, line in enumerate(open(sys.argv[i + 1]), 1) if line.strip() and not line.startswith('#')]
    for where, spec in wanted:
        if spec.startswith('>'):
            source, _, dest = spec[1:].partition('=')
            if not all(p.startswith(FILE_PREFIXES) and '/../' not in p + '/' and '*' not in p and p.rstrip('/') == p
                       for p in (source, dest)) or source == dest:
                sys.exit(f'{where}: {spec}: give >FROM=TO, both under ' + ', '.join(FILE_PREFIXES) + " (no '*', no '..')")
            moves.append((source, dest))
            print(f'moved on the root: {source} -> {dest}', file=sys.stderr)
            continue
        owner = None
        parts = spec.rsplit(None, 1)
        if len(parts) == 2 and re.fullmatch(r'\d+:\d+:[0-7]{3,4}', parts[1]):
            spec, owner = parts[0], tuple(int(x, 8 if k == 2 else 10) for k, x in enumerate(parts[1].split(':')))
        special = spec[:1] in ('-', '?')
        dest, _, local = spec[1:].partition('=') if special else spec.partition('=')
        if (not dest.startswith(FILE_PREFIXES) or '/../' in dest + '/' or (not local) != special or
                ('*' in dest and not special) or any(c.count('*') > 1 for c in dest.split('/')) or dest.count('*') > 3):
            sys.exit(f'{where}: {spec}: give DEST=LOCAL_FILE [UID:GID:MODE], -DEST or ?PATH, under ' + ', '.join(FILE_PREFIXES)
                     + " ('*' only in -DEST/?PATH: one a component, three at most)")
        if spec.startswith('-'):
            deletes.append(dest)
            print(f'removed from the root: {dest}', file=sys.stderr)
            continue
        if spec.startswith('?'):
            lists.append(dest)
            print(f'listed into the kernel log: {dest}', file=sys.stderr)
            continue
        files.append((dest, open(local, 'rb').read(), owner))
        print(f'file for the root: {dest} ({len(files[-1][1])} bytes' +
              (f', {owner[0]}:{owner[1]} {owner[2]:o})' if owner else ')'), file=sys.stderr)
    if len(files) > 64 or len(deletes) > 64 or len(lists) > 64 or len(moves) > 64:
        sys.exit(f'--file/--files-from: {len(files)} files, {len(deletes)} removals, {len(lists)} lists, {len(moves)} moves: '
                 '64 of each at most')
    if sum(len(d) for _, d, _ in files) > 48 << 20:
        sys.exit(f'--file/--files-from: {sum(len(d) for _, d, _ in files) / 1048576:.1f} MiB in all, more than 48 MiB; '
                 'the boot image would grow too much')
    if files:
        print(f'files for the root: {len(files)}, {sum(len(d) for _, d, _ in files) / 1048576:.1f} MiB', file=sys.stderr)
    root = build(qemu='--qemu' in sys.argv, highmem='--highmem' in sys.argv, touch_fw=touch_fw, gmu_fw=gmu_fw,
                 gpu_extra=gpu_extra, p3='--p3' in sys.argv, files=files, deletes=deletes, lists=lists, wifi=wifi, macs=macs, bt=bt,
                 moves=moves)
    blob = adt.serialize(root)
    open(sys.argv[1], 'wb').write(blob)
    if '--dump' in sys.argv:
        adt.dump(adt.parse(blob)[0])
    print(f'{sys.argv[1]}: {len(blob)} bytes', file=sys.stderr)
