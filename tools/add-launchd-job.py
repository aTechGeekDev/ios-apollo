#!/usr/bin/env python3
"""Add a run-at-boot launchd job (SWEET bring-up tests).

  add-launchd-job.py IN.plist OUT.plist LABEL PROGRAM [ARG ...]

IN is /System/Library/xpc/launchd.plist (binary plist, read by launchd when
booted with launchd_unsecure_cache=1). The job runs PROGRAM once at boot as
root. Its stdout/stderr stay launchd's default /dev/null: the kernel copies
what the programs named in boot-arg sweetnull write there into its console
log (patch 0048; tools/sweet-log-pull.sh), e.g.
sweetnull=backboardd,SpringBoard,sweet-gpu-test. (/dev/console does not reach
that log: boot 29 has no line of sweet-gpu-test's.) An existing job with the
same LABEL is replaced.
"""
import plistlib, sys


def main():
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    src, dst, label, program, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
    with open(src, 'rb') as f:
        plist = plistlib.load(f)
    daemons = plist['LaunchDaemons']
    for key in [k for k, job in daemons.items() if job.get('Label') == label]:
        del daemons[key]
    daemons[f'/System/Library/LaunchDaemons/{label}.plist'] = {
        'Label': label,
        'ProgramArguments': [program] + args,
        'RunAtLoad': True,
        'KeepAlive': False,
        'UserName': 'root',
    }
    with open(dst, 'wb') as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)
    print(f'{dst}: job {label} runs {" ".join([program] + args)} at boot ({len(daemons)} jobs)')


if __name__ == '__main__':
    main()
