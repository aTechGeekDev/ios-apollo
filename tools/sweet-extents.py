#!/usr/bin/env python3
"""Where a file of a mounted iOS root lies on the volume, for tools/sweet-push.sh.

  sudo sweet-extents.py MOUNTED_FILE OUT.extents

Run by tools/sweet-root-install.sh on the files it pads (libraries we change
often). Asks the kernel for every block of the file (FIBMAP; Linux hfsplus has
no FIEMAP), joins them into runs, reads each run back from the device the
root is mounted from (the loop device of the image) and compares it with the
file: the runs are then byte offsets into the image, which is flashed to the
start of userdata, so they are offsets into userdata as well. Also written
down: the volume's creation date (the volume header at 1024, +0x10), which
sweet-push.sh compares with the phone's before it writes anything, and the
file's size and sha256.
"""
import fcntl, hashlib, os, struct, subprocess, sys

FIBMAP, FIGETBSZ = 1, 2


def device_of(path):
    """The block device the filesystem holding path is mounted from (the image's loop device)."""
    out = subprocess.run(['findmnt', '-n', '-o', 'SOURCE', '--target', path], capture_output=True, text=True, check=True)
    return out.stdout.strip()


def volume_created(d):
    """The HFS+ volume header's creation date, from the open device."""
    d.seek(1024)
    header = d.read(512)
    if header[:2] not in (b'H+', b'HX'):
        sys.exit('sweet-extents.py: no HFS+ volume header at 1024')
    return struct.unpack('>I', header[0x10:0x14])[0]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    path, out = sys.argv[1], sys.argv[2]
    os.sync()
    size = os.path.getsize(path)
    with open(path, 'rb') as f:
        data = f.read()
        bsz = struct.unpack('i', fcntl.ioctl(f.fileno(), FIGETBSZ, struct.pack('i', 0)))[0]
        blocks = []
        for i in range((size + bsz - 1) // bsz):
            phys = struct.unpack('i', fcntl.ioctl(f.fileno(), FIBMAP, struct.pack('i', i)))[0]
            if phys <= 0:
                sys.exit(f'sweet-extents.py: {path}: block {i} has no place on the volume ({phys})')
            blocks.append(phys)
    runs = []                                   # [logical block, physical block, blocks]
    for i, phys in enumerate(blocks):
        if runs and runs[-1][1] + runs[-1][2] == phys and runs[-1][0] + runs[-1][2] == i:
            runs[-1][2] += 1
        else:
            runs.append([i, phys, 1])
    dev = device_of(path)
    with open(dev, 'rb') as d:
        created = volume_created(d)
        for logical, phys, count in runs:
            d.seek(phys * bsz)
            want = data[logical * bsz:(logical + count) * bsz]
            if d.read(len(want)) != want:
                sys.exit(f'sweet-extents.py: {dev} at {phys * bsz} does not hold {path} block {logical}')
    with open(out, 'w') as o:
        o.write(f'# {os.path.basename(path)} size {size} sha256 {hashlib.sha256(data).hexdigest()} '
                f'created {created:#010x} block {bsz}\n')
        o.write('# logical byte, byte in the volume (= in userdata), bytes\n')
        for logical, phys, count in runs:
            o.write(f'{logical * bsz} {phys * bsz} {count * bsz}\n')
    print(f'{os.path.basename(path)}: {size} bytes in {len(runs)} run{"s" if len(runs) != 1 else ""} on the volume '
          f'(checked against {dev}) -> {out}')


if __name__ == '__main__':
    main()
