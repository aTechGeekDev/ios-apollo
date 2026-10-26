#!/usr/bin/env python3
"""launchd's job list without the jobs that only burn CPU here, as a file for the boot image.

  tools/launchd-edit.py ROOT OUT [--keep LABEL]... [--remove LABEL]...

ROOT is the iOS root mounted read-only (sudo mount -t hfsplus -o loop,ro
research/ios-root/ios16-root.img /mnt/iosroot): the image the phone's root was
flashed from, so its /System/Library/xpc/launchd.plist is the one on the phone
(launchd reads it with boot-arg launchd_unsecure_cache=1). OUT (research/launchd)
gets launchd.plist without the jobs below, a copy of the original, and the lists
for mkadt.py --files-from: launchd.txt (the edited one) and launchd-undo.txt (the
original back). The kernel writes it before launchd starts (xnu 0120-0123).

Removed by default (apollo boot 44: bluetoothd and fairplayd.H2 relaunched 412
times each in 40 minutes; a request to a job that keeps crashing is queued and
never answered, so a caller waits forever: ios-sailfish found locationd stuck on
fairplayd; Settings > About shows the Bluetooth address): fairplayd.H2 (no
FairPlay hardware), bluetoothd (no Bluetooth driver yet), vmd (voicemail, no
modem), and the diagnostics ios-sailfish removed (ReportCrash ~60% of a core
there, spindump, tailspind, aggregated). Our kernel prints crashes itself.
"""
import os, plistlib, shutil, sys

REMOVE = ['com.apple.fairplayd.H2', 'com.apple.bluetoothd', 'com.apple.voicemail.vmd', 'com.apple.ReportCrash',
          'com.apple.spindump', 'com.apple.tailspind', 'com.apple.aggregated', 'com.apple.aggregated.addaily']


def main():
    args, remove = [], list(REMOVE)
    i = 1
    while i < len(sys.argv):
        if sys.argv[i] in ('--keep', '--remove') and i + 1 < len(sys.argv):
            (remove.remove if sys.argv[i] == '--keep' else remove.append)(sys.argv[i + 1])
            i += 2
            continue
        args.append(sys.argv[i])
        i += 1
    if len(args) != 2:
        sys.exit(__doc__)
    root, out = args
    src = os.path.join(root, 'System/Library/xpc/launchd.plist')
    if not os.path.isfile(src):
        sys.exit(f'launchd-edit.py: no {src}: is the root mounted?')
    st = os.stat(src)
    raw = open(src, 'rb').read()
    fmt = plistlib.FMT_BINARY if raw.startswith(b'bplist') else plistlib.FMT_XML
    plist = plistlib.loads(raw)
    jobs = plist['LaunchDaemons']
    gone = [(k, j.get('Label')) for k, j in jobs.items() if j.get('Label') in remove]
    for k, _ in gone:
        del jobs[k]
    os.makedirs(out, exist_ok=True)
    edited, original = os.path.abspath(os.path.join(out, 'launchd.plist')), os.path.abspath(os.path.join(out, 'launchd-original.plist'))
    with open(edited, 'wb') as f:
        plistlib.dump(plist, f, fmt=fmt)
    shutil.copyfile(src, original)
    owner = f'{st.st_uid}:{st.st_gid}:{st.st_mode & 0o7777:04o}'
    with open(os.path.join(out, 'launchd.txt'), 'w') as f:
        f.write(f'# launchd.plist without {len(gone)} jobs (tools/launchd-edit.py); undo: launchd-undo.txt\n'
                f'/System/Library/xpc/launchd.plist={edited} {owner}\n')
    with open(os.path.join(out, 'launchd-undo.txt'), 'w') as f:
        f.write(f'# the phone\'s original launchd.plist back\n/System/Library/xpc/launchd.plist={original} {owner}\n')
    for key, label in gone:
        print(f'removed {label} ({key})')
    missing = sorted(set(remove) - {label for _, label in gone})
    if missing:
        print('not in this launchd.plist (already gone): ' + ', '.join(missing))
    print(f'{len(jobs)} jobs left; {os.path.join(out, "launchd.txt")} and launchd-undo.txt written')


main()
