#!/bin/bash
# Stage Apple's open source IOHIDFamily-2238.120.5 user-client / event sources
# into iokit/Kernel/arm/hid/ for SWEET (iOS 26 HID wire format).
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ "${MACOS_VERSION:-}" == 26.* ]] || {
    echo 'SWEET IOHIDFamily-2238.120.5 integration requires xnu-12377 (macOS 26.x)' >&2
    exit 1
}
[[ -f iokit/KernelConfigTables.cpp ]] || exit 1

hid_sha=e31e90a24c27ad6cbe981650d12a1a4124065b03
hid_defs_sha=2365347f5147a1e2a46de21acd08d27fe0906e85
hid_tmp=""

if [[ -n "${XNU_LOCAL_DEPS_DIR:-}" && -d "${XNU_LOCAL_DEPS_DIR}/IOHIDFamily/.git" ]]; then
    hid_repo="${XNU_LOCAL_DEPS_DIR}/IOHIDFamily"
    if ! git -C "$hid_repo" cat-file -e "${hid_defs_sha}^{commit}" 2>/dev/null; then
        git -C "$hid_repo" fetch -q --depth 1 \
            https://github.com/apple-oss-distributions/IOHIDFamily "$hid_defs_sha"
    fi
else
    hid_tmp=$(mktemp -d)
    trap '[[ -n "$hid_tmp" ]] && rm -rf "$hid_tmp"' EXIT
    git init -q "$hid_tmp"
    git -C "$hid_tmp" fetch -q --depth 1 \
        https://github.com/apple-oss-distributions/IOHIDFamily "$hid_defs_sha"
    git -C "$hid_tmp" fetch -q --depth 1 \
        https://github.com/apple-oss-distributions/IOHIDFamily "$hid_sha"
    git -C "$hid_tmp" checkout -q FETCH_HEAD
    hid_repo="$hid_tmp"
fi
[[ "$(git -C "$hid_repo" rev-parse HEAD)" == "$hid_sha" ]]

sdk_hid_dir=""
if [[ "$(uname -s)" == Darwin ]] || command -v xcrun >/dev/null 2>&1; then
    sdk_root=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
    for cand in \
        "${KDKROOT:-}/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/IOKit/hid" \
        "${sdk_root}/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/IOKit/hid" \
        "${sdk_root}/System/Library/Frameworks/IOKit.framework/Versions/A/PrivateHeaders/hid"; do
        if [[ -f "$cand/IOHIDEventStructDefs.h" && -f "$cand/IOHIDEventMacroDefs.h" && \
              -f "$cand/IOHIDEventFieldDefs.h" && -f "$cand/IOHIDEventTypes.h" ]]; then
            sdk_hid_dir="$cand"
            break
        fi
    done
fi

python3 - "$hid_repo" "$hid_defs_sha" "$sdk_hid_dir" <<'PY'
from pathlib import Path
import re
import shutil
import subprocess
import sys

repo = Path(sys.argv[1])
defs_sha = sys.argv[2]
sdk_hid_dir = Path(sys.argv[3]) if sys.argv[3] else None

target = Path('iokit/Kernel/arm/hid')
if target.exists():
    raise SystemExit(f'refusing to overwrite existing HID directory: {target}')
target.mkdir(parents=True)

# 1. Stage IOHIDFamily-2238.120.5 sources and headers (preserve APSL headers).
family_files = (
    'AppleHIDUsageTables.h',
    'IOHIDDeviceKeys.h',
    'IOHIDDeviceTypes.h',
    'IOHIDEvent.cpp',
    'IOHIDEvent.h',
    'IOHIDEventData.h',
    'IOHIDEventServiceKeys.h',
    'IOHIDEventServiceKeys_Private.h',
    'IOHIDEventServiceQueue.cpp',
    'IOHIDEventServiceQueue.h',
    'IOHIDEventServiceTypes.h',
    'IOHIDEventServiceUserClient.cpp',
    'IOHIDEventServiceUserClient.h',
    'IOHIDFamilyTrace.h',
    'IOHIDKeys.h',
    'IOHIDPrivateKeys.h',
    'IOHIDProperties.h',
    'IOHIDTimeSyncKeys.h',
    'IOHIDUsageTables.h',
)
for name in family_files:
    shutil.copy2(repo / 'IOHIDFamily' / name, target / name)

hidsystem_files = (
    'IOHIDParameter.h',
    'IOHIDShared.h',
    'IOHIDTypes.h',
    'IOLLEvent.h',
    'ev_keymap.h',
)
for name in hidsystem_files:
    shutil.copy2(repo / 'IOHIDSystem/IOKit/hidsystem' / name, target / name)

def replace_exact(text: str, old: str, new: str, label: str, count: int = 1) -> str:
    actual = text.count(old)
    if actual != count:
        raise SystemExit(f'IOHIDFamily schema mismatch ({label}): expected {count}, got {actual}')
    return text.replace(old, new)

# 2. Stage IOHIDEvent{Types,StructDefs,FieldDefs,MacroDefs}.h:
#    Use SDK PrivateHeaders if present; otherwise deterministically upgrade the
#    APSL generated headers from IOHIDFamily-1915.140.3 to 2238.120.5 schema.
gen_names = (
    'IOHIDEventTypes.h',
    'IOHIDEventStructDefs.h',
    'IOHIDEventFieldDefs.h',
    'IOHIDEventMacroDefs.h',
)
if sdk_hid_dir is not None:
    for name in gen_names:
        shutil.copy2(sdk_hid_dir / name, target / name)
else:
    raw = {}
    for name in gen_names:
        raw[name] = subprocess.check_output(
            ['git', '-C', str(repo), 'show', f'{defs_sha}:IOHIDFamily/{name}']
        ).decode('utf-8')

    # --- IOHIDEventTypes.h ---
    t = raw['IOHIDEventTypes.h']
    t = replace_exact(
        t,
        '    kIOHIDEventTypeGenericGesture,\n    kIOHIDEventTypeCount, // This should always be last',
        '    kIOHIDEventTypeGenericGesture,\n'
        '    kIOHIDEventTypeDynamicButton,\n'
        '    kIOHIDEventTypeForceStage,\n'
        '    kIOHIDEventTypeTouchSensitiveButton,\n'
        '    kIOHIDEventTypeHeartRate,\n'
        '    kIOHIDEventTypeCount, // This should always be last',
        'IOHIDEventType tail',
    )
    t = replace_exact(
        t,
        '    kIOHIDDigitizerEventEstimatedPressure                   = 1<<30,\n',
        '    kIOHIDDigitizerEventEstimatedPressure                   = 1<<30,\n'
        '    kIOHIDDigitizerEventEstimatedRoll                       = 1U<<31,\n',
        'kIOHIDDigitizerEventEstimatedRoll',
    )
    t = replace_exact(
        t,
        '    kIOHIDDigitizerEventUpdateQualityRadiiAccuracyMask      = 1<<IOHIDEventFieldOffsetOf(kIOHIDEventFieldDigitizerQualityRadiiAccuracy),\n',
        '    kIOHIDDigitizerEventUpdateQualityRadiiAccuracyMask      = 1<<IOHIDEventFieldOffsetOf(kIOHIDEventFieldDigitizerQualityRadiiAccuracy),\n'
        '    kIOHIDDigitizerEventUpdateRollMask                      = 1<<IOHIDEventFieldOffsetOf(kIOHIDEventFieldDigitizerRoll),\n',
        'kIOHIDDigitizerEventUpdateRollMask',
    )
    t = replace_exact(
        t,
        '#endif /* _IOKIT_HID_IOHIDEVENTTYPES_H } */',
        'enum {\n'
        '    kIOHIDHeartRateSensorLocationUnknown        = 0,\n'
        '    kIOHIDHeartRateSensorLocationLeftHeadphone  = 1,\n'
        '    kIOHIDHeartRateSensorLocationRightHeadphone = 2,\n'
        '    kIOHIDHeartRateSensorLocationWatch          = 3,\n'
        '};\n'
        'typedef uint32_t IOHIDHeartRateSensorLocation;\n\n'
        '#endif /* _IOKIT_HID_IOHIDEVENTTYPES_H } */',
        'IOHIDHeartRateSensorLocation',
    )
    (target / 'IOHIDEventTypes.h').write_text(t)

    # --- IOHIDEventFieldDefs.h ---
    f = raw['IOHIDEventFieldDefs.h']
    f = replace_exact(
        f,
        'static const IOHIDEventField kIOHIDEventFieldDigitizerTwist                                    =  (kIOHIDEventFieldDigitizerBase | 12);\n',
        'static const IOHIDEventField kIOHIDEventFieldDigitizerTwist                                    =  (kIOHIDEventFieldDigitizerBase | 12);\n'
        'static const IOHIDEventField kIOHIDEventFieldDigitizerRoll                                     =  (kIOHIDEventFieldDigitizerBase | 23);\n',
        'kIOHIDEventFieldDigitizerRoll',
    )
    f = replace_exact(
        f,
        '#endif\n',
        '#define kIOHIDEventFieldHeartRateBase IOHIDEventFieldBase(kIOHIDEventTypeHeartRate)\n'
        'static const IOHIDEventField kIOHIDEventFieldHeartRateRate                                     =  (kIOHIDEventFieldHeartRateBase | 0);\n'
        'static const IOHIDEventField kIOHIDEventFieldHeartRateConfidence                               =  (kIOHIDEventFieldHeartRateBase | 1);\n'
        'static const IOHIDEventField kIOHIDEventFieldHeartRateLocation                                 =  (kIOHIDEventFieldHeartRateBase | 2);\n'
        'static const IOHIDEventField kIOHIDEventFieldHeartRateGenerationCount                          =  (kIOHIDEventFieldHeartRateBase | 3);\n'
        '#endif\n',
        'kIOHIDEventFieldHeartRateBase',
    )
    (target / 'IOHIDEventFieldDefs.h').write_text(f)

    # --- IOHIDEventStructDefs.h ---
    s = raw['IOHIDEventStructDefs.h']
    s = replace_exact(
        s,
        'typedef struct {\n'
        '    uint32_t size;\n'
        '    IOHIDEventType type;\n'
        '    uint32_t options;\n'
        '    uint8_t depth;\n'
        '    uint8_t reserved[3];\n'
        '} IOHIDCollectionEventData;',
        'typedef struct {\n'
        '    uint32_t size;\n'
        '    IOHIDEventType type;\n'
        '    uint32_t options;\n'
        '    uint8_t depth;\n'
        '    uint8_t reserved[3];\n'
        '    uint16_t usagePage;\n'
        '    uint16_t usage;\n'
        '    uint32_t ungroupForLegacy:1;\n'
        '    uint32_t reservedFlags:31;\n'
        '} IOHIDCollectionEventData;',
        'IOHIDCollectionEventData',
    )
    s = replace_exact(
        s,
        'typedef struct {\n'
        '    uint32_t size;\n'
        '    IOHIDEventType type;\n'
        '    uint32_t options;\n'
        '    uint8_t depth;\n'
        '    uint8_t reserved[3];\n'
        '    struct {\n'
        '        IOFixed x;\n'
        '        IOFixed y;\n'
        '        IOFixed z;\n'
        '    } position;\n'
        '} IOHIDTranslationEventData;',
        'typedef struct {\n'
        '    uint32_t size;\n'
        '    IOHIDEventType type;\n'
        '    uint32_t options;\n'
        '    uint8_t depth;\n'
        '    uint8_t reserved[3];\n'
        '    struct {\n'
        '        IOHIDDouble x;\n'
        '        IOHIDDouble y;\n'
        '        IOHIDDouble z;\n'
        '    } position;\n'
        '} IOHIDTranslationEventData;',
        'IOHIDTranslationEventData',
    )
    s = replace_exact(
        s,
        'typedef struct {\n'
        '    uint32_t size;\n'
        '    IOHIDEventType type;\n'
        '    uint32_t options;\n'
        '    uint8_t depth;\n'
        '    uint8_t reserved[3];\n'
        '    struct {\n'
        '        IOFixed x;\n'
        '        IOFixed y;\n'
        '        IOFixed z;\n'
        '    } position;\n'
        '    struct {\n'
        '        uint32_t mask;\n'
        '    } button;\n'
        '} IOHIDPointerEventData;',
        'typedef struct {\n'
        '    uint32_t size;\n'
        '    IOHIDEventType type;\n'
        '    uint32_t options;\n'
        '    uint8_t depth;\n'
        '    uint8_t reserved[3];\n'
        '    struct {\n'
        '        IOHIDDouble x;\n'
        '        IOHIDDouble y;\n'
        '        IOHIDDouble z;\n'
        '    } position;\n'
        '    struct {\n'
        '        uint32_t mask;\n'
        '    } button;\n'
        '} IOHIDPointerEventData;',
        'IOHIDPointerEventData',
    )

    old_dig = re.search(
        r'typedef struct \{[^{}]*(?:\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}[^{}]*)*\}\s*IOHIDDigitizerEventData;',
        s,
    )
    if not old_dig:
        raise SystemExit('IOHIDDigitizerEventData not found')
    new_dig = old_dig.group(0).replace('IOFixed ', 'IOHIDDouble ')
    new_dig = replace_exact(
        new_dig,
        '    IOHIDDouble twist;\n',
        '    union {\n'
        '        IOHIDDouble roll;\n'
        '        IOHIDDouble twist;\n'
        '    } angle;\n',
        'IOHIDDigitizerEventData.angle',
    )
    s = replace_exact(s, old_dig.group(0), new_dig, 'IOHIDDigitizerEventData')

    s = replace_exact(
        s,
        'typedef struct {\n'
        '    IOHIDGameControllerEventData base;\n'
        '    uint32_t thumbstickButtonLeft:1;\n'
        '    uint32_t thumbstickButtonRight:1;\n'
        '    IOFixed l4;\n'
        '    IOFixed l5;\n'
        '    IOFixed r4;\n'
        '    IOFixed r5;\n'
        '} __IOHIDGameControllerEventData;',
        'typedef struct {\n'
        '    IOHIDGameControllerEventData base;\n'
        '    uint32_t thumbstickButtonLeft:1;\n'
        '    uint32_t thumbstickButtonRight:1;\n'
        '    IOFixed l4;\n'
        '    IOFixed r4;\n'
        '    struct {\n'
        '        IOFixed m1;\n'
        '        IOFixed m2;\n'
        '        IOFixed m3;\n'
        '        IOFixed m4;\n'
        '    } bottom;\n'
        '} __IOHIDGameControllerEventData;',
        '__IOHIDGameControllerEventData',
    )
    s = replace_exact(
        s,
        '#endif\n',
        'typedef struct {\n'
        '    uint32_t size;\n'
        '    IOHIDEventType type;\n'
        '    uint32_t options;\n'
        '    uint8_t depth;\n'
        '    uint8_t reserved[3];\n'
        '    uint32_t rate;\n'
        '    IOHIDDouble confidence;\n'
        '    uint32_t location;\n'
        '    uint32_t generationCount;\n'
        '} IOHIDHeartRateEventData;\n\n'
        'typedef struct {\n'
        '    IOHIDHeartRateEventData base;\n'
        '} __IOHIDHeartRateEventData;\n\n'
        '#endif\n',
        'IOHIDHeartRateEventData',
    )
    (target / 'IOHIDEventStructDefs.h').write_text(s)

    # --- IOHIDEventMacroDefs.h ---
    m = raw['IOHIDEventMacroDefs.h']
    m = m.replace(
        '((IOHIDDigitizerEventData*)event)->twist',
        '((IOHIDDigitizerEventData*)event)->angle.twist',
    )
    m = m.replace('->l5', '->bottom.m1').replace('->r5', '->bottom.m2')

    # Upgrade CAST_* macros for structs whose fields moved from IOHIDFixed to IOHIDDouble:
    for stype in ('IOHIDTranslationEventData', 'IOHIDPointerEventData', 'IOHIDDigitizerEventData'):
        # Getter conversions (reading IOHIDDouble field into integer/double/fixed):
        m = m.replace(f'CAST_FIXED_TO_INTEGER((({stype}*)event)->',
                      f'CAST_DOUBLE_TO_INTEGER((({stype}*)event)->')
        m = m.replace(f'CAST_FIXED_TO_DOUBLE((({stype}*)event)->',
                      f'CAST_DOUBLE_TO_DOUBLE((({stype}*)event)->')
        m = m.replace(f'CAST_FIXED_TO_FIXED((({stype}*)event)->',
                      f'CAST_DOUBLE_TO_FIXED((({stype}*)event)->')
        # Setter conversions (writing integer/double/fixed value into IOHIDDouble field):
        # Match lines assigning to float/double fields (which previously used CAST_*_TO_FIXED)
        m = re.sub(
            rf'(\(\({stype}\*\)event\)->[^\n=]+=\s*\(typeof\(\(\({stype}\*\)event\)->[^\n=]+\)\)\s*)CAST_INTEGER_TO_FIXED\(value\)',
            r'\1CAST_INTEGER_TO_DOUBLE(value)',
            m,
        )
        m = re.sub(
            rf'(\(\({stype}\*\)event\)->[^\n=]+=\s*\(typeof\(\(\({stype}\*\)event\)->[^\n=]+\)\)\s*)CAST_DOUBLE_TO_FIXED\(value\)',
            r'\1CAST_DOUBLE_TO_DOUBLE(value)',
            m,
        )
        m = re.sub(
            rf'(\(\({stype}\*\)event\)->[^\n=]+=\s*\(typeof\(\(\({stype}\*\)event\)->[^\n=]+\)\)\s*)CAST_FIXED_TO_FIXED\(value\)',
            r'\1CAST_FIXED_TO_DOUBLE(value)',
            m,
        )

    # Add kIOHIDEventFieldDigitizerRoll alongside kIOHIDEventFieldDigitizerTwist in Digitizer macros:
    m = re.sub(
        r'(case kIOHIDEventFieldDigitizerTwist:\s*\\\n(?:\s*[^\n]+\\\n)+?\s*break;\s*\\\n)',
        lambda match: match.group(1) + match.group(1)
            .replace('kIOHIDEventFieldDigitizerTwist', 'kIOHIDEventFieldDigitizerRoll')
            .replace('->angle.twist', '->angle.roll'),
        m,
    )

    # Add kIOHIDEventTypeHeartRate to IOHIDEventGetSize:
    m = replace_exact(
        m,
        '      case kIOHIDEventTypePointer:\\\n'
        '          size = sizeof (__IOHIDPointerEventData);\\\n'
        '          break; \\',
        '      case kIOHIDEventTypePointer:\\\n'
        '          size = sizeof (__IOHIDPointerEventData);\\\n'
        '          break; \\\n'
        '      case kIOHIDEventTypeHeartRate:\\\n'
        '          size = sizeof (__IOHIDHeartRateEventData);\\\n'
        '          break; \\',
        'IOHIDEventGetSize HeartRate',
    )
    (target / 'IOHIDEventMacroDefs.h').write_text(m)

# 3. Rewrite framework-style includes into local includes for in-kernel build.
for p in sorted(target.iterdir()):
    if p.suffix not in ('.h', '.cpp'):
        continue
    text = p.read_text(encoding='utf-8', errors='surrogateescape')
    text = re.sub(r'#include\s*<IOKit/(?:hid|hidsystem|graphics)/([^>]+)>', r'#include "\1"', text)
    text = text.replace(
        '#include <TargetConditionals.h>',
        '/* SWEET: kernel build, no SDK TargetConditionals.h */\n'
        '#ifndef TARGET_OS_DRIVERKIT\n'
        '#define TARGET_OS_DRIVERKIT 0\n'
        '#endif',
    )
    text = text.replace(
        '#include <math.h>',
        '/* SWEET: no <math.h> in the kernel; only NAN is used */\n'
        '#ifndef NAN\n'
        '#define NAN __builtin_nanf("")\n'
        '#endif',
    )
    p.write_text(text, encoding='utf-8', errors='surrogateescape')
PY

echo "Staged IOHIDFamily-2238.120.5 ($hid_sha) for SWEET"
