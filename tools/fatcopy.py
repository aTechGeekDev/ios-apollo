#!/usr/bin/env python3
"""Read files out of a FAT12/16/32 image (the phone's modem partition) without mounting it.

  fatcopy.py IMAGE list DIR                 every entry of DIR ("image/qca6390"): "d|- size name"
  fatcopy.py IMAGE get DIR PATTERN OUTDIR   the files of DIR whose names match PATTERN (fnmatch, any
                                            case), written to OUTDIR under their names in lower case

Long names are read; short names come out in lower case, as Android mounts the partition
(shortname=lower). The image is only read. It is untrusted input: run as python3 -I.
"""
import fnmatch, os, struct, sys


class Fat:
    def __init__(self, path):
        self.f = open(path, 'rb')
        self.base = 0
        boot = self.read(0, 512)
        if not self.plausible(boot) and boot[510:512] == b'\x55\xaa':
            # a partition table in front: the first partition's start
            self.base = struct.unpack_from('<I', boot, 446 + 8)[0] * 512
            boot = self.read(0, 512)
        if not self.plausible(boot):
            sys.exit(f'fatcopy.py: {path}: not a FAT file system')
        self.sector, self.per_cluster, reserved, fats, root_entries, total16 = struct.unpack_from('<HBHBHH', boot, 11)
        fat16, = struct.unpack_from('<H', boot, 22)
        total32, fat32 = struct.unpack_from('<II', boot, 32)
        fat_sectors = fat16 or fat32
        total = total16 or total32
        root_sectors = (root_entries * 32 + self.sector - 1) // self.sector
        self.fat_at = reserved * self.sector
        self.root_at = (reserved + fats * fat_sectors) * self.sector
        self.data_at = self.root_at + root_sectors * self.sector
        clusters = (total - (reserved + fats * fat_sectors + root_sectors)) // self.per_cluster
        self.bits = 12 if clusters < 4085 else 16 if clusters < 65525 else 32
        self.root_cluster = struct.unpack_from('<I', boot, 44)[0] if self.bits == 32 else 0
        self.root_size = root_sectors * self.sector
        self.cluster_size = self.sector * self.per_cluster
        self.fat = self.read(self.fat_at, fat_sectors * self.sector)

    @staticmethod
    def plausible(boot):
        sector, per_cluster, reserved, fats = struct.unpack_from('<HBHB', boot, 11)
        return (sector in (512, 1024, 2048, 4096) and per_cluster and per_cluster & (per_cluster - 1) == 0 and
                reserved and fats in (1, 2))

    def read(self, at, size):
        self.f.seek(self.base + at)
        return self.f.read(size)

    def next(self, cluster):
        if self.bits == 32:
            value = struct.unpack_from('<I', self.fat, cluster * 4)[0] & 0x0fffffff
            return None if value >= 0x0ffffff8 or value < 2 else value
        if self.bits == 16:
            value = struct.unpack_from('<H', self.fat, cluster * 2)[0]
            return None if value >= 0xfff8 or value < 2 else value
        value = struct.unpack_from('<H', self.fat, cluster * 3 // 2)[0]
        value = value >> 4 if cluster & 1 else value & 0xfff
        return None if value >= 0xff8 or value < 2 else value

    def chain(self, cluster, size=None):
        out, seen = bytearray(), set()
        while cluster is not None and cluster not in seen and (size is None or len(out) < size):
            seen.add(cluster)
            out += self.read(self.data_at + (cluster - 2) * self.cluster_size, self.cluster_size)
            cluster = self.next(cluster)
        return bytes(out if size is None else out[:size])

    def entries(self, cluster):
        """(name, is_dir, first_cluster, size) of a directory (cluster 0: the FAT12/16 root)."""
        raw = self.read(self.root_at, self.root_size) if cluster == 0 else self.chain(cluster)
        long_parts, out = [], []
        for at in range(0, len(raw) - 31, 32):
            e = raw[at:at + 32]
            if e[0] == 0:
                break
            if e[0] == 0xe5:
                long_parts = []
                continue
            if e[11] == 0x0f:                           # a piece of a long name, last piece first
                text = e[1:11] + e[14:26] + e[28:32]
                long_parts.insert(0, text.decode('utf-16-le', 'replace').split('\x00')[0].rstrip('￿'))
                continue
            if e[11] & 0x08:                            # the volume label
                long_parts = []
                continue
            short = e[0:8].decode('latin-1').rstrip() + ('.' + e[8:11].decode('latin-1').rstrip()
                                                          if e[8:11].strip() else '')
            name = ''.join(long_parts) or short.lower()
            long_parts = []
            if name in ('.', '..'):
                continue
            first = struct.unpack_from('<H', e, 26)[0] | (struct.unpack_from('<H', e, 20)[0] << 16 if self.bits == 32 else 0)
            out.append((name, bool(e[11] & 0x10), first, struct.unpack_from('<I', e, 28)[0]))
        return out

    def directory(self, path):
        cluster = self.root_cluster
        for part in [p for p in path.split('/') if p]:
            match = [e for e in self.entries(cluster) if e[1] and e[0].lower() == part.lower()]
            if not match:
                sys.exit(f'fatcopy.py: no directory {path}')
            cluster = match[0][2]
        return cluster


def main():
    a = sys.argv[1:]
    if len(a) == 3 and a[1] == 'list':
        fat = Fat(a[0])
        for name, is_dir, _, size in fat.entries(fat.directory(a[2])):
            print('d' if is_dir else '-', size, name)
    elif len(a) == 5 and a[1] == 'get':
        fat = Fat(a[0])
        os.makedirs(a[4], exist_ok=True)
        got = 0
        for name, is_dir, first, size in fat.entries(fat.directory(a[2])):
            if is_dir or not fnmatch.fnmatch(name.lower(), a[3].lower()) or '/' in name or name.startswith('.'):
                continue
            data = fat.chain(first, size) if size else b''
            if len(data) != size:
                sys.exit(f'fatcopy.py: {name}: {len(data)} of {size} bytes')
            with open(os.path.join(a[4], name.lower()), 'wb') as f:
                f.write(data)
            print(f'{name.lower()} {size}')
            got += 1
        if not got:
            sys.exit(f'fatcopy.py: nothing in {a[2]} matches {a[3]}')
    else:
        sys.exit(__doc__.strip())


if __name__ == '__main__':
    main()
