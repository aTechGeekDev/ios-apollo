#!/usr/bin/env python3
"""Symbolicate SWEET console crash reports (patch 0043) and process samples (0054).

  sweet-crash.py [--last] CACHE ROOT [REPORT.txt]       (report on stdin if omitted)

CACHE is the dyld_shared_cache_arm64 (in a writable directory: ipsw keeps a
symbol cache next to it), ROOT the mounted iOS root image. Lines look like

  CRASH name[pid] sig 6 code 0x... sub 0x... slide 0x... mh 0x...
  CRASH name pc 0x... lr 0x... sp 0x... fp 0x... far 0x...
  CRASH name bt 0x... 0x... ...
  SMP name[pid] slide 0x... mh 0x...
  SMP name tN pc 0x... lr 0x... sp 0x... bt 0x... ...

Other lines are skipped, so a whole pulled log can be given; --last keeps
only the last "SMP --- sample". Addresses inside the shared cache are unslid
(addr - slide) and resolved with `ipsw dyld a2s` (each address once);
addresses in the main binary are shown as its own vmaddr (address - mh +
0x100000000), and for the binaries in MAIN followed by `ipsw macho disass`
of the instructions before that return address in ROOT's executable.
"""
import os, re, subprocess, sys

CACHE_LO, CACHE_HI = 0x180000000, 0x300000000
MAIN = {'SpringBoard': 'System/Library/CoreServices/SpringBoard.app/SpringBoard',
        'backboardd': 'usr/libexec/backboardd'}
known = {}


ANSI = re.compile(r'\x1b\[[0-9;]*m')
said_raw = False


def a2s(cache, addr):
    """ipsw's answer for addr, whichever of its output styles it uses (they changed between
    versions): "0x...: image`symbol", a "symbol=... image=..." log line, or the last plain line."""
    global said_raw
    if addr not in known:
        r = subprocess.run(['ipsw', 'dyld', 'a2s', '--no-color', cache, hex(addr)], capture_output=True, text=True)
        if r.returncode != 0 and 'unknown flag' in r.stderr:
            r = subprocess.run(['ipsw', 'dyld', 'a2s', cache, hex(addr)], capture_output=True, text=True)
        out = ANSI.sub('', r.stdout + '\n' + r.stderr)
        name = None
        for line in out.splitlines():
            line = line.strip()
            m = re.match(r'0x[0-9a-fA-F]+:\s*(.+)', line)
            if m:
                name = m.group(1)
            m = re.search(r'symbol=("[^"]*"|\S+)', line)
            if m:
                image = re.search(r'(?:image|dylib)=("[^"]*"|\S+)', line)
                name = m.group(1).strip('"') + (f' ({os.path.basename(image.group(1).strip(chr(34)))})' if image else '')
        if name is None and not said_raw:
            said_raw = True
            print(f'    (ipsw dyld a2s {hex(addr)} said, exit {r.returncode}: {out.strip()[:600]!r})', file=sys.stderr)
        known[addr] = name or '?'
    return known[addr]


def disass(root, name, vaddr):
    """The 12 instructions up to the call that returns to vaddr, in ROOT's executable."""
    if (name, vaddr) in known or name not in MAIN or not root:
        return []
    r = subprocess.run(['ipsw', 'macho', 'disass', os.path.join(root, MAIN[name]),
                        '--vaddr', hex(vaddr - 44), '--count', '12'], capture_output=True, text=True)
    known[(name, vaddr)] = True
    out = (r.stdout or r.stderr).strip().splitlines()
    return out[-12:] if r.returncode == 0 else out[:1]


def main():
    args = sys.argv[1:]
    last = '--last' in args
    args = [a for a in args if a != '--last']
    if len(args) < 2:
        sys.exit(__doc__)
    cache, root = args[0], args[1]
    text = open(args[2]).read() if len(args) > 2 else sys.stdin.read()
    if last and 'SMP --- sample' in text:
        text = text[text.rindex('SMP --- sample'):]
    slide = mh = 0
    name = ''
    # the kernel's line buffer cuts long sample lines; the next one then follows
    # on the same line ("... 0x1d18b83SMP backboardd t10 ..."), its cut address
    # falls outside both ranges below
    lines = [part for line in text.splitlines() for part in re.split(r'(?<=\S)(?=(?:SMP|CRASH) )', line)]
    for line in lines:
        if not line.startswith(('CRASH ', 'SMP ')):
            continue
        print(line)
        m = re.search(r'^\w+ (\S+?)\[\d+\].*slide (0x[0-9a-f]+) mh (0x[0-9a-f]+)', line)
        if m:
            name, slide, mh = m.group(1), int(m.group(2), 16), int(m.group(3), 16)
            continue
        for a in re.findall(r'(?:pc|lr|bt|\s)(?: )?(0x[0-9a-f]{6,})', line):
            v = int(a, 16)
            if CACHE_LO <= v - slide < CACHE_HI:
                print(f'    {a} = cache {hex(v - slide)} {a2s(cache, v - slide)}')
            elif mh and mh <= v < mh + 0x10000000:
                print(f'    {a} = main binary {hex(v - mh + 0x100000000)}')
                for d in disass(root, name, v - mh + 0x100000000):
                    print(f'        {d}')
        sys.stdout.flush()


if __name__ == '__main__':
    main()
