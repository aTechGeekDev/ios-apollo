#!/usr/bin/env python3
"""The apollo ADT while the SWEET kernel moves to UniXNU's format 2 device tree.

UniXNU's payload step writes kernel.macho.adt with its common generator from dts/apollo.dts and the
profiles (scripts/unixnu/devicetree.py). The SWEET kernel (project-BadApple xnu/patches) still reads
nodes that generator cannot express: root-level /sweet-* nodes carrying firmware, root files and
options, /arm-io/gic with virtual-timer-intid, /arm-io/disp0, /arm-io/wdt, /arm-io/wlan, the SMP cpu
properties and the full /product of the real D22AP tree. Until each of them moves into the DTS, the
profiles or the kernel, this tool bridges the two.

  gap  UNIXNU.adt MKADT.adt
      Print what MKADT.adt (tools/mkadt.py, what the SWEET kernel boots with today) has and UNIXNU.adt
      (the generator's) lacks or encodes differently: the migration worklist (porting.toml "packaging").

  merge UNIXNU.adt MKADT.adt OUT.adt [--window BASE:SIZE] [--pram BASE]
      OUT = MKADT's tree with what DarwinBoot needs from UNIXNU's: /chosen darwinboot-* and the
      /chosen/memory-map placeholders (DarwinBoot refuses a payload input without its placeholder).
      /chosen dram-base/dram-size become the kernel window (as mkadt.py --highmem has them: xnu-8796
      only uses them for is_dram_addr, so memory outside the window stays device memory), and /pram
      moves outside the window (DarwinBoot places the window itself; mkadt.py put the log at its top).

  payload PAYLOAD.img MKADT.adt [--window BASE:SIZE] [--pram BASE]
      merge, in place, inside the FAT payload "unixnu payload" wrote (mtools), and check that the
      command line fits xnu-8796's 608-byte boot_args field. Run "unixnu bootimg" afterwards.

--window: DarwinBoot takes the lowest run of free memory of [payload.adt] owned_memory_size and prints
it ("DARWINBOOT: ARM64 va=... pa=... owned=..."). Default 0xc0000000:0x100000000, a prediction from
uefi-apollo's memory map (everything below 0xb0000000 is reserved, 0xbbb00000-0xc0000000 is a hole), not
yet seen on the phone. --pram: default 0x27ff00000, the top MiB of the 8 GiB DRAM (dts/apollo.dts
panic_log). Run with the repository's tools/ on the path (tools/adt.py).
"""
import os
import re
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '../../tools'))
import adt  # noqa: E402  (project-BadApple tools/adt.py)

BOOT_LINE_LENGTH = 608          # xnu-8796 pexpert/pexpert/arm64/boot.h (DarwinBoot fills 1024)
PANIC_LOG_SIZE = 0x100000       # mkadt.py PANIC_LOG_SIZE, /chosen embedded-panic-log-size
DEFAULT_WINDOW = (0xc0000000, 0x100000000)
DEFAULT_PRAM = 0x27ff00000


def load(path):
    return adt.parse(open(path, 'rb').read())[0]


def child(node, name):
    return next((c for c in node.children if c.name == name), None)


def walk(node, path=None):
    """(path, node) of NODE and every node under it; the root is "/"."""
    here = '/' if path is None else f'{path.rstrip("/")}/{node.name}'
    yield here, node
    for c in node.children:
        yield from walk(c, here)


def props(node):
    return {k: v for k, _, v in node.props if k != 'name'}


def set_prop(node, key, value):
    for i, (k, f, _) in enumerate(node.props):
        if k == key:
            node.props[i] = (k, f, value)
            return
    node.props.append((key, 0, value))


def gap(unixnu_path, mkadt_path):
    ours = dict(walk(load(mkadt_path)))
    theirs = dict(walk(load(unixnu_path)))
    # Values that differ by design: each build makes a fresh seed and NVRAM image, phandles are numbered
    # independently, and the generator writes absolute window values the bridge replaces.
    volatile = {'random-seed', 'AAPL,phandle', 'phandle'}
    missing_nodes, missing_props, different = [], [], []
    for path, node in ours.items():
        other = theirs.get(path)
        if other is None:
            missing_nodes.append((path, sorted(props(node))))
            continue
        mine, gen = props(node), props(other)
        for key, value in mine.items():
            if key in volatile:
                continue
            if key not in gen:
                missing_props.append((path, key, len(value)))
            elif gen[key] != value:
                different.append((path, key, adt.fmt(value)[:60], adt.fmt(gen[key])[:60]))
    extra = [path for path in theirs if path not in ours]

    def grouped(rows):
        """Rows of /cpus/cpuN that are alike for every N, printed once as cpuN with the CPU numbers."""
        groups = {}
        for row in rows:
            key = (re.sub(r'^/cpus/cpu\d+', '/cpus/cpuN', row[0]),) + row[1:]
            groups.setdefault(key, []).append(re.match(r'^/cpus/cpu(\d+)', row[0]))
        for key, matches in groups.items():
            which = [m.group(1) for m in matches if m]
            yield (key[0].replace('cpuN', f'cpu{{{",".join(which)}}}') if len(which) > 1 else
                   key[0].replace('cpuN', f'cpu{which[0]}') if which else key[0]), *key[1:]

    print(f'nodes the SWEET kernel tree has and the generator does not ({len(missing_nodes)}):')
    for path, keys in missing_nodes:
        print(f'  {path}: {", ".join(k for k in keys if k not in volatile)}')
    print(f'properties missing in nodes both have ({len(missing_props)}):')
    for path, key, size in grouped(missing_props):
        print(f'  {path} {key} ({size} bytes)')
    print(f'properties both have with other values ({len(different)}):')
    for path, key, mine, gen in grouped(different):
        print(f'  {path} {key}: SWEET {mine} / generator {gen}')
    print(f'nodes only the generator writes ({len(extra)}): {", ".join(extra)}')
    return len(missing_nodes) + len(missing_props) + len(different)


def merge(unixnu_path, mkadt_path, out_path, window=DEFAULT_WINDOW, pram=DEFAULT_PRAM):
    root, generated = load(mkadt_path), load(unixnu_path)
    chosen, gen_chosen = child(root, 'chosen'), child(generated, 'chosen')
    if chosen is None or gen_chosen is None:
        sys.exit('apollo-adt.py: an ADT without /chosen')
    # DarwinBoot: the window size request, and any other darwinboot-* table the board asked for.
    for key, value in props(gen_chosen).items():
        if key.startswith('darwinboot-'):
            set_prop(chosen, key, value)
    if 'darwinboot-memory-size' not in props(chosen):
        sys.exit('apollo-adt.py: the generated ADT has no darwinboot-memory-size (board.toml [payload.adt] owned_memory_size)')
    # The placeholders DarwinBoot fills for its inputs (TrustCache, RAMDisk, ...).
    gen_map, memory_map = child(gen_chosen, 'memory-map'), child(chosen, 'memory-map')
    if gen_map is not None and memory_map is not None:
        for key, value in props(gen_map).items():
            set_prop(memory_map, key, value)
    base, size = window
    owned = struct.unpack('<Q', props(chosen)['darwinboot-memory-size'])[0]
    if size != owned:
        sys.exit(f'apollo-adt.py: --window size {size:#x} is not the window DarwinBoot allocates ({owned:#x})')
    if base <= pram < base + size or base < pram + PANIC_LOG_SIZE <= base + size:
        sys.exit(f'apollo-adt.py: /pram {pram:#x} lies in the kernel window {base:#x}+{size:#x}')
    set_prop(chosen, 'dram-base', struct.pack('<Q', base))
    set_prop(chosen, 'dram-size', struct.pack('<Q', size))
    set_prop(chosen, 'embedded-panic-log-size', struct.pack('<I', PANIC_LOG_SIZE))
    pram_node = child(root, 'pram')
    if pram_node is None:
        sys.exit('apollo-adt.py: the SWEET tree has no /pram (tools/mkadt.py)')
    set_prop(pram_node, 'reg', struct.pack('<QQ', pram, PANIC_LOG_SIZE))
    blob = adt.serialize(root)
    open(out_path, 'wb').write(blob)
    print(f'apollo-adt.py: {out_path}: {len(blob)} bytes; window {base:#x}+{size:#x}, /pram {pram:#x}', file=sys.stderr)


def mtools(*command):
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout


def payload(image, mkadt_path, window, pram):
    config = mtools('mtype', '-i', image, '::/EFI/UniXNU/unixnu.toml')
    for line in re.findall(r'^args = "(.*)"$', config, re.M):
        if len(line) >= BOOT_LINE_LENGTH:
            sys.exit(f'apollo-adt.py: the command line is {len(line)} bytes; xnu-8796 reads {BOOT_LINE_LENGTH - 1} at most')
    with tempfile.TemporaryDirectory() as work:
        generated, merged = os.path.join(work, 'unixnu.adt'), os.path.join(work, 'kernel.macho.adt')
        mtools('mcopy', '-n', '-i', image, '::/EFI/UniXNU/Payloads/kernel.macho.adt', generated)
        merge(generated, mkadt_path, merged, window, pram)
        mtools('mcopy', '-o', '-i', image, merged, '::/EFI/UniXNU/Payloads/kernel.macho.adt')
    print(f'apollo-adt.py: {image}: kernel.macho.adt replaced; now run "unixnu bootimg"', file=sys.stderr)


def option(name, default, parse):
    if name in sys.argv:
        i = sys.argv.index(name)
        value = sys.argv[i + 1]
        del sys.argv[i:i + 2]
        return parse(value)
    return default


def main():
    window = option('--window', DEFAULT_WINDOW, lambda v: tuple(int(x, 0) for x in v.split(':')))
    pram = option('--pram', DEFAULT_PRAM, lambda v: int(v, 0))
    command, *rest = sys.argv[1:] or ['']
    if command == 'gap' and len(rest) == 2:
        gap(*rest)
    elif command == 'merge' and len(rest) == 3:
        merge(*rest, window=window, pram=pram)
    elif command == 'payload' and len(rest) == 2:
        payload(*rest, window, pram)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
