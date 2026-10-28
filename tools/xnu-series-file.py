#!/usr/bin/env python3
"""Write files the xnu patch series creates, as the whole series leaves them, without an XNU checkout.

  xnu-series-file.py OUTDIR PATH [PATH ...]

PATH is a file's path in the XNU tree (bsd/dev/hakios.lx.h); it is written to OUTDIR under its
own name. Only files that one of the patches creates can be made this way: their hunks are
applied in series order, as validate-repo.py does to check them. The CI build of the Wi-Fi
driver (tools/mk-ath11k.sh) takes the kernel's headers from here.
"""
import importlib.util, os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip())
    out, wanted = sys.argv[1], sys.argv[2:]
    spec = importlib.util.spec_from_file_location('validate_repo', os.path.join(ROOT, 'tools/validate-repo.py'))
    validate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validate)
    series = sorted(os.path.join(ROOT, 'xnu/patches', name) for name in os.listdir(os.path.join(ROOT, 'xnu/patches'))
                    if name.endswith('.patch'))
    created = set()
    with tempfile.TemporaryDirectory() as tmp:
        for path in series:
            with open(path, errors='surrogateescape') as f:
                text = f.read()
            for rel, creates, section in validate.file_sections(text):
                if creates:
                    created.add(rel)
                if rel not in created:
                    continue
                res = subprocess.run(['patch', '-p1', '-s', '-f', '--no-backup-if-mismatch', '-r', '-', '-d', tmp],
                                     input=section.encode('utf-8', 'surrogateescape'), capture_output=True)
                if res.returncode != 0:
                    sys.exit(f"xnu-series-file.py: {os.path.basename(path)} does not apply to {rel}")
        os.makedirs(out, exist_ok=True)
        for rel in wanted:
            if rel not in created:
                sys.exit(f"xnu-series-file.py: no patch creates {rel}")
            shutil.copyfile(os.path.join(tmp, rel), os.path.join(out, os.path.basename(rel)))
            print(f"xnu-series-file.py: {rel} -> {os.path.join(out, os.path.basename(rel))}")


if __name__ == '__main__':
    main()
