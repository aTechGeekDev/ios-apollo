#!/usr/bin/env python3
"""Validate repository integrity, patch sequences, and script syntax.

  tools/validate-repo.py [--verbose]

Checks:
  1. Patch sequence in xnu/patches/:
     - Sequential numbering starting at 0001 with no duplicates or gaps.
     - Patch files are non-empty and have valid unified diff markers.
     - Every hunk's line counts match its @@ header.
     - Files the series creates (bsd/dev/sweet_*.c, ...) replay through
       all later patches with `patch -p1` (no XNU checkout needed).
  2. Python script syntax:
     - All tools/*.py compile cleanly via py_compile.
  3. Shell script syntax:
     - All tools/*.sh, shim/*.sh, and xnu/patches/*.sh pass bash -n check.
"""
import argparse, glob, os, py_compile, re, subprocess, sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def green(text): return f"\033[92m{text}\033[0m"
def red(text): return f"\033[91m{text}\033[0m"
def bold(text): return f"\033[1m{text}\033[0m"


HUNK = re.compile(r'^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@')


def check_hunks(text):
    """Line counts of every hunk must match its @@ header (hand-edited
    patches break here first: `patch` reports "malformed patch")."""
    errors = []
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        m = HUNK.match(lines[i])
        if not m:
            i += 1
            continue
        start = i + 1
        old = int(m.group(1) or 1)
        new = int(m.group(2) or 1)
        i += 1
        while (old > 0 or new > 0) and i < len(lines):
            line = lines[i]
            tag = line[:1]
            if tag in (' ', ''):
                old -= 1
                new -= 1
            elif tag == '-':
                old -= 1
            elif tag == '+':
                new -= 1
            elif tag != '\\':
                break
            i += 1
        if old != 0 or new != 0:
            errors.append(f"hunk at line {start - 1} does not match its header "
                          f"({lines[start - 1].split('@@')[1].strip()})")
    return errors


def file_sections(text):
    """Yield (path, created, section_text) for each file in a unified diff."""
    lines = text.splitlines(keepends=True)
    cur = None
    for i, line in enumerate(lines):
        if line.startswith('--- ') and i + 1 < len(lines) and lines[i + 1].startswith('+++ '):
            if cur:
                yield cur[0], cur[1], ''.join(cur[2])
            path = re.sub(r'^[ab]/', '', lines[i + 1][4:].split('\t')[0].strip())
            cur = (path, line.startswith('--- /dev/null'), [])
        elif line.startswith('diff ') or line.startswith('Only in '):
            if cur:
                yield cur[0], cur[1], ''.join(cur[2])
            cur = None
            continue
        if cur:
            cur[2].append(line)
    if cur:
        yield cur[0], cur[1], ''.join(cur[2])


def replay_created_files(patch_files):
    """Apply, in series order, every hunk for files the series itself creates
    (bsd/dev/sweet_*.c and friends). Needs no XNU checkout and catches a patch
    written against an older version of one of our own files."""
    import shutil, tempfile
    if not shutil.which('patch'):
        return [], 0
    errors, created = [], set()
    with tempfile.TemporaryDirectory() as tmp:
        for path in patch_files:
            fname = os.path.basename(path)
            with open(path, 'r', errors='surrogateescape') as f:
                text = f.read()
            for rel, creates, section in file_sections(text):
                if creates:
                    created.add(rel)
                if rel not in created:
                    continue
                res = subprocess.run(['patch', '-p1', '-s', '-f', '--no-backup-if-mismatch',
                                      '-r', '-', '-d', tmp], input=section.encode('utf-8', 'surrogateescape'),
                                     capture_output=True)
                if res.returncode != 0:
                    errors.append(f"{fname}: does not apply to {rel} as left by the earlier patches")
    return errors, len(created)


def validate_patches(verbose=False):
    patch_dir = os.path.join(REPO_ROOT, 'xnu/patches')
    patch_files = sorted(glob.glob(os.path.join(patch_dir, '*.patch')))
    if not patch_files:
        print(red("[-] Error: No patch files found in xnu/patches/"))
        return False

    errors = []
    seen_numbers = {}

    for path in patch_files:
        fname = os.path.basename(path)
        m = re.match(r'^(\d{4})-(.+)\.patch$', fname)
        if not m:
            errors.append(f"Invalid patch filename format: {fname}")
            continue

        num = int(m.group(1))
        if num in seen_numbers:
            errors.append(f"Duplicate patch number {num:04d}: {fname} and {seen_numbers[num]}")
        seen_numbers[num] = fname

        size = os.path.getsize(path)
        if size == 0:
            errors.append(f"Patch is empty: {fname}")
            continue

        with open(path, 'r', errors='ignore') as f:
            text = f.read()
        head = text[:2048]
        if not ('--- ' in head or 'diff ' in head or 'Index:' in head):
            errors.append(f"Patch missing standard diff header: {fname}")
        errors.extend(f"{fname}: {e}" for e in check_hunks(text))

    # Check contiguous sequence
    if seen_numbers:
        sorted_nums = sorted(seen_numbers.keys())
        expected = 1
        for num in sorted_nums:
            if num != expected:
                errors.append(f"Gap in patch sequence: expected {expected:04d}, found {num:04d} ({seen_numbers[num]})")
                expected = num + 1
            else:
                expected += 1

    replay_errors, ncreated = replay_created_files(patch_files)
    errors.extend(replay_errors)

    if errors:
        print(red(f"[-] Patch validation failed with {len(errors)} error(s):"))
        for err in errors:
            print(f"    - {err}")
        return False

    print(green(f"[✓] Validated {len(patch_files)} patches (0001-{len(patch_files):04d} contiguous, format OK, "
                f"{ncreated} series-created files replay cleanly)"))
    return True


def validate_python_scripts(verbose=False):
    tools_dir = os.path.join(REPO_ROOT, 'tools')
    py_files = sorted(glob.glob(os.path.join(tools_dir, '*.py')))
    errors = []

    for path in py_files:
        fname = os.path.basename(path)
        try:
            py_compile.compile(path, doraise=True)
            if verbose:
                print(f"    [OK] {fname}")
        except py_compile.PyCompileError as e:
            errors.append(f"{fname}: {e}")

    if errors:
        print(red(f"[-] Python syntax validation failed with {len(errors)} error(s):"))
        for err in errors:
            print(f"    - {err}")
        return False

    print(green(f"[✓] Validated {len(py_files)} Python tools (syntax OK)"))
    return True


def validate_shell_scripts(verbose=False):
    sh_files = sorted(
        glob.glob(os.path.join(REPO_ROOT, 'tools/*.sh')) +
        glob.glob(os.path.join(REPO_ROOT, 'shim/*.sh')) +
        glob.glob(os.path.join(REPO_ROOT, 'xnu/patches/*.sh'))
    )
    errors = []

    for path in sh_files:
        rel = os.path.relpath(path, REPO_ROOT)
        res = subprocess.run(['bash', '-n', path], capture_output=True, text=True)
        if res.returncode != 0:
            errors.append(f"{rel}: {res.stderr.strip()}")
        elif verbose:
            print(f"    [OK] {rel}")

    if errors:
        print(red(f"[-] Shell syntax validation failed with {len(errors)} error(s):"))
        for err in errors:
            print(f"    - {err}")
        return False

    print(green(f"[✓] Validated {len(sh_files)} Shell scripts (syntax OK)"))
    return True


def main():
    ap = argparse.ArgumentParser(description="Validate repository integrity, patches, and scripts.")
    ap.add_argument('-v', '--verbose', action='store_true', help='Show detailed per-file output')
    a = ap.parse_args()

    print(bold("=== Running project-BadApple Repository Validation ==="))
    ok_patches = validate_patches(a.verbose)
    ok_python = validate_python_scripts(a.verbose)
    ok_shell = validate_shell_scripts(a.verbose)

    if ok_patches and ok_python and ok_shell:
        print(bold(green("\nAll repository integrity checks PASSED successfully!")))
        return 0
    else:
        print(bold(red("\nRepository integrity check FAILED.")))
        return 1


if __name__ == '__main__':
    sys.exit(main())
