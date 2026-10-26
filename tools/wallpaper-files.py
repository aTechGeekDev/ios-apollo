#!/usr/bin/env python3
"""The stock wallpapers' HEIC layers as PNG, as files for the boot image (mkadt.py --files-from).

  tools/wallpaper-files.py ROOT OUT [--only TEXT]

ROOT is the iOS root mounted read-only (sudo mount -t hfsplus -o loop,ro
research/ios-root/ios16-root.img /mnt/iosroot), OUT a directory of ours
(research/wallpaper). The layered wallpapers (/Library/Wallpaper/Collections/
*/Wallpapers/*.wallpaper/*.ca/assets/*.HEIC) need the A11's hardware HEVC
decoder, which the phone does not have: PosterBoard drew only their background
gradient (apollo: a red one). As ios-sailfish's wallpaper-heic2png.sh does, each
HEIC gets a PNG twin (heif-convert, opacity kept) and the layer's main.caml
names the PNG instead; the HEIC files stay.

OUT gets the PNGs and the edited main.caml files at their paths under
/Library/Wallpaper, and files-1.txt, files-2.txt, ... with the lines
"/Library/Wallpaper/...=OUT/..." for mkadt.py --files-from, each list 40 MiB at
most and 60 files (what one boot image carries well, with room for a library
or two). The kernel writes them onto the root before launchd starts (xnu 0120)
and they stay there, so the lists can go on one boot after another. --only
TEXT: only the wallpapers whose path has TEXT in it. Needs heif-convert
(Kali/Debian: sudo apt install libheif-examples); 16-bit PNGs (10-bit layers)
are made 8-bit with ImageMagick when it is there (half the size).
"""
import os, re, shutil, subprocess, sys

LIMIT = 40 << 20
MAX_FILES = 60


def converter():
    for name in ('heif-convert', 'heif-dec'):
        if shutil.which(name):
            return name
    sys.exit('wallpaper-files.py: no heif-convert (sudo apt install libheif-examples)')


def eight_bit(png):
    """A 16-bit PNG (heif-convert keeps a 10-bit layer's depth) to 8 bits, if ImageMagick is there."""
    with open(png, 'rb') as f:
        if f.read(25)[24] != 16:
            return
    tool = shutil.which('magick') or shutil.which('convert')
    if tool is None:
        print(f'note: {png} is 16-bit (no ImageMagick to make it 8-bit: twice the size)', file=sys.stderr)
        return
    r = subprocess.run([tool, png, '-depth', '8', 'PNG32:' + png + '.tmp.png'], capture_output=True, text=True)  # RGBA, 8 bits
    if r.returncode == 0:
        os.replace(png + '.tmp.png', png)
    else:
        print(f'note: {tool} {png}: {r.stderr.strip()}', file=sys.stderr)


def main():
    args = [a for a in sys.argv[1:] if a != '--only']
    only = sys.argv[sys.argv.index('--only') + 1] if '--only' in sys.argv else None
    if only is not None:
        args.remove(only)
    if len(args) != 2:
        sys.exit(__doc__)
    root, out = args
    tool = converter()
    base = os.path.join(root, 'Library/Wallpaper/Collections')
    if not os.path.isdir(base):
        sys.exit(f'wallpaper-files.py: no {base}: is the root mounted?')
    files = []                                  # (path on the phone, local file)
    per_wallpaper = {}
    for dirpath, _, names in sorted(os.walk(base)):
        if 'main.caml' not in names or (only is not None and only not in dirpath):
            continue
        caml = os.path.join(dirpath, 'main.caml')
        text = open(caml, 'rb').read().decode('utf-8', 'surrogateescape')
        if '.HEIC"' not in text:
            continue
        wallpaper = next((p for p in dirpath.split(os.sep) if p.endswith('.wallpaper')), dirpath)
        for ref in sorted(set(re.findall(r'"([^"]*\.HEIC)"', text))):
            heic = os.path.normpath(os.path.join(dirpath, ref))
            if not os.path.isfile(heic):
                print(f'warning: {os.path.relpath(caml, root)} names {ref}, which is not there', file=sys.stderr)
                continue
            png_rel = os.path.relpath(heic, root)[:-len('.HEIC')] + '.png'
            png = os.path.join(out, png_rel)
            if not os.path.exists(png):
                os.makedirs(os.path.dirname(png), exist_ok=True)
                r = subprocess.run([tool, heic, png], capture_output=True, text=True)
                if r.returncode != 0 or not os.path.exists(png):
                    sys.exit(f'wallpaper-files.py: {tool} {heic}: {r.stderr.strip() or r.stdout.strip()}')
                eight_bit(png)
            files.append(('/' + png_rel, png))
            per_wallpaper[wallpaper] = per_wallpaper.get(wallpaper, 0) + os.path.getsize(png)
        edited = os.path.join(out, os.path.relpath(caml, root))
        os.makedirs(os.path.dirname(edited), exist_ok=True)
        with open(edited, 'wb') as f:
            f.write(text.replace('.HEIC"', '.png"').encode('utf-8', 'surrogateescape'))
        files.append(('/' + os.path.relpath(caml, root), edited))
    if not files:
        sys.exit('wallpaper-files.py: no layered wallpaper with HEIC layers found' + (f' with "{only}"' if only else ''))
    for old in [n for n in os.listdir(out) if re.fullmatch(r'files-\d+\.txt', n)]:
        os.remove(os.path.join(out, old))
    lists, size = [[]], 0
    for dest, local in files:
        bytes_ = os.path.getsize(local)
        if lists[-1] and (size + bytes_ > LIMIT or len(lists[-1]) >= MAX_FILES):
            lists.append([])
            size = 0
        lists[-1].append(f'{dest}={os.path.abspath(local)}')
        size += bytes_
    for i, lines in enumerate(lists, 1):
        with open(os.path.join(out, f'files-{i}.txt'), 'w') as f:
            f.write('\n'.join(lines) + '\n')
    for wallpaper, bytes_ in sorted(per_wallpaper.items()):
        print(f'{bytes_ / 1048576:7.1f} MiB  {wallpaper}')
    total = sum(os.path.getsize(l) for _, l in files)
    print(f'{len(files)} files, {total / 1048576:.1f} MiB, in {len(lists)} list(s): '
          + ' '.join(os.path.join(out, f'files-{i}.txt') for i in range(1, len(lists) + 1)))


main()
