#!/bin/bash
# Stage Apple's open source HFS for the SWEET built-in filesystem (bsd/sweet_hfs).
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ "${MACOS_VERSION:-}" == 26.* ]] || {
    echo 'SWEET HFS-715.120.4 integration requires xnu-12377 (macOS 26.x)' >&2
    exit 1
}
[[ -f bsd/kern/bsd_init.c ]] || exit 1

# hfs-715.120.4 is paired with xnu-12377.121.6 in Apple's macOS 26 OSS release.
# Fetch the immutable commit, never a moving branch/tag.
hfs_sha=124b970fd5390f1c2cd6f985478616a04f6eeb1f
hfs_tmp=""
if [[ -n "${XNU_LOCAL_DEPS_DIR:-}" && -d "${XNU_LOCAL_DEPS_DIR}/hfs/.git" ]]; then
    hfs_src="${XNU_LOCAL_DEPS_DIR}/hfs"
else
    hfs_tmp=$(mktemp -d)
    trap '[[ -n "$hfs_tmp" ]] && rm -rf "$hfs_tmp"' EXIT
    git init -q "$hfs_tmp"
    git -C "$hfs_tmp" fetch -q --depth 1 \
        https://github.com/apple-oss-distributions/hfs "$hfs_sha"
    git -C "$hfs_tmp" checkout -q FETCH_HEAD
    hfs_src="$hfs_tmp"
fi
[[ "$(git -C "$hfs_src" rev-parse HEAD)" == "$hfs_sha" ]]

python3 - "$hfs_src" <<'PY'
from pathlib import Path
import shutil
import sys

source = Path(sys.argv[1])
target = Path('bsd/sweet_hfs')
if target.exists():
    raise SystemExit(f'refusing to overwrite existing HFS sources: {target}')
# Preserve upstream copyright/license headers; no downloaded sources in git.
for directory in ('core', 'hfs_encodings'):
    shutil.copytree(source / directory, target / directory)

# SWEET has no AppleKeyStore (content protection is not built, see
# sweet_hfs_compat.h); its header is only needed for the key-wrapping API.
path = target / 'core' / 'hfs_iokit.h'
text = path.read_text()
include = '#include <AppleKeyStore/AppleKeyStoreFSServices.h>\n'
first = 'int hfs_unwrap_key('
end = '__END_DECLS'
if text.count(include) != 1 or text.count(first) != 1 or text.count(end) != 1:
    raise SystemExit(f'HFS source changed: {path}')
text = text.replace(include, '#if CONFIG_PROTECT\n' + include + '#endif\n')
i, j = text.index(first), text.index(end)
text = text[:i] + '#if CONFIG_PROTECT\n' + text[i:j].rstrip('\n') + '\n#endif\n\n' + text[j:]
path.write_text(text)
PY

# Kernel builds use -nostdinc/-nostdlibinc; HFS's kext-config.h needs target macros.
if [[ "$(uname -s)" == Darwin ]] || command -v xcrun >/dev/null 2>&1; then
    hfs_sdk=$(xcrun --sdk macosx --show-sdk-path)
    cp "$hfs_sdk/usr/include/TargetConditionals.h" bsd/sweet_hfs/
else
    cat << 'EOF' > bsd/sweet_hfs/TargetConditionals.h
#ifndef __TARGETCONDITIONALS__
#define __TARGETCONDITIONALS__
#define TARGET_OS_MAC 1
#define TARGET_OS_OSX 1
#define TARGET_OS_IPHONE 0
#define TARGET_OS_IOS 0
#define TARGET_OS_WATCH 0
#define TARGET_OS_TV 0
#define TARGET_OS_BRIDGE 0
#define TARGET_OS_DRIVERKIT 0
#define TARGET_OS_EMBEDDED 0
#define TARGET_OS_SIMULATOR 0
#define TARGET_CPU_ARM64 1
#endif
EOF
fi
echo "Staged hfs-715.120.4 ($hfs_sha) for SWEET"
