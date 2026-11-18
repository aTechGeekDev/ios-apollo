#!/bin/bash
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ "${MACOS_VERSION:-}" == 26.* ]] || {
    echo 'SWEET libpthread-539.100.4 integration requires xnu-12377 (macOS 26.x)' >&2
    exit 1
}
[[ -f bsd/pthread/pthread_shims.c ]] || exit 1

# libpthread-539.100.4 is paired with xnu-12377 in Apple's macos-26
# release.json. Fetch the immutable commit, never a moving branch/tag.
pthread_sha=1f4f5265b319111142f1bf3a27d4484ef5a98314
pthread_tmp=""
if [[ -n "${XNU_LOCAL_DEPS_DIR:-}" && -d "${XNU_LOCAL_DEPS_DIR}/libpthread/.git" ]]; then
    pthread_src="${XNU_LOCAL_DEPS_DIR}/libpthread"
else
    pthread_tmp=$(mktemp -d)
    trap '[[ -n "$pthread_tmp" ]] && rm -rf "$pthread_tmp"' EXIT
    git init -q "$pthread_tmp"
    git -C "$pthread_tmp" fetch -q --depth 1 \
        https://github.com/apple-oss-distributions/libpthread "$pthread_sha"
    git -C "$pthread_tmp" checkout -q FETCH_HEAD
    pthread_src="$pthread_tmp"
fi
[[ "$(git -C "$pthread_src" rev-parse HEAD)" == "$pthread_sha" ]]

python3 - "$pthread_src" <<'PY'
from pathlib import Path
import shutil
import sys

source = Path(sys.argv[1])
target = Path('bsd/pthread/sweet_libpthread')
if target.exists():
    raise SystemExit(f'refusing to overwrite existing provider: {target}')
# Preserve upstream copyright/license headers; no downloaded sources in git.
for directory in ('kern', 'private', 'include'):
    shutil.copytree(source / directory, target / directory)

def replace(file, old, new, count):
    path = target / 'kern' / file
    text = path.read_text()
    if text.count(old) != count:
        raise SystemExit(f'libpthread source changed: {file}: {old!r}')
    path.write_text(text.replace(old, new))

# The public kernel source has stricter address types than the kext SDK.
# Keep the address bits intact with explicit casts; user addresses use zero.
replace('kern_trace.h', 'vm_kernel_unslide_or_perm_external(ptr,',
        'vm_kernel_unslide_or_perm_external((vm_offset_t)ptr,', 1)
for callback, count in (('psynch_wait_update_owner', 4),
                        ('psynch_wait_complete', 1), ('psynch_wait_wakeup', 2)):
    replace('kern_synch.c', f'pthread_kern->{callback}(kwq,',
            f'pthread_kern->{callback}((uintptr_t)kwq,', count)
replace('kern_support.c', '*kevent_list_out = NULL;', '*kevent_list_out = 0;', 1)
replace('kern_support.c', 'user_addr_t kevent_list = NULL;',
        'user_addr_t kevent_list = 0;', 2)
replace('kern_support.c', 'workq_kevent(p, &th_addrs, NULL,',
        'workq_kevent(p, &th_addrs, 0,', 1)
replace('kern_support.c',
        'panic(__func__ ": thread_set_wq_state failed: %d", error);',
        'panic("%s: thread_set_wq_state failed: %d", __func__, error);', 4)
PY

# Kernel builds use -nostdinc/-nostdlibinc. Carry the real SDK target definitions
# beside the provider on macOS; provide a minimal stub when staging offline on Linux.
if [[ "$(uname -s)" == Darwin ]] || command -v xcrun >/dev/null 2>&1; then
    pthread_sdk=$(xcrun --sdk macosx --show-sdk-path)
    cp "$pthread_sdk/usr/include/TargetConditionals.h" bsd/pthread/sweet_libpthread/
else
    cat << 'EOF' > bsd/pthread/sweet_libpthread/TargetConditionals.h
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
echo "Staged libpthread-539.100.4 ($pthread_sha) for SWEET"
