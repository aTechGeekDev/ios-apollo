#!/bin/bash
# Stage KDK-free CoreEntitlements/V2 headers for xnu-12377.121.6 (macOS/iOS 26).
# Can be run standalone with KDKROOT=<dir> before dxb/build.sh (to satisfy
# dxb/patches/26.0/00_setup_coreentitlements.sh without a 1.2 GB KDK DMG) and
# again from the XNU source root during patches() to install the full V2 API.
set -euo pipefail

if [[ -n "${MACHINE_CONFIG:-}" && "${MACHINE_CONFIG}" != SWEET ]]; then
    exit 0
fi

write_ce_v2_headers() {
    local dest="$1"
    mkdir -p "$dest"

    cat << 'EOF' > "$dest/Return.h"
#ifndef CORE_ENTITLEMENTS_V2_RETURN_H
#define CORE_ENTITLEMENTS_V2_RETURN_H

#include <stdint.h>

typedef uint32_t CEReturn_t;

enum {
    kCEReturnSuccess = 0,
    kCEReturnError = 1,
    kCEReturnV1NotEligibleForAcceleration = 2,
};

#endif /* CORE_ENTITLEMENTS_V2_RETURN_H */
EOF

    cat << 'EOF' > "$dest/Context.h"
#ifndef CORE_ENTITLEMENTS_V2_CONTEXT_H
#define CORE_ENTITLEMENTS_V2_CONTEXT_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <CoreEntitlements/CoreEntitlements.h>

typedef enum {
    kCEContextTypeEntitlements = 0,
    kCEContextTypeProvisioningProfile = 1,
    kCEContextTypeProvisioningProfileEntitlements = 2,
} CEContextType_t;

typedef struct _CEContext {
    void *opaque[8];
} CEContext_t;

typedef struct _CEElement {
    void *opaque[4];
} CEElement_t;

typedef CEBuffer CEBuffer_t;

#endif /* CORE_ENTITLEMENTS_V2_CONTEXT_H */
EOF

    cat << 'EOF' > "$dest/API.h"
#ifndef CORE_ENTITLEMENTS_V2_API_H
#define CORE_ENTITLEMENTS_V2_API_H

#include <CoreEntitlements/CoreEntitlements.h>
#include <CoreEntitlements/V2/Return.h>
#include <CoreEntitlements/V2/Context.h>

#endif /* CORE_ENTITLEMENTS_V2_API_H */
EOF

    cat << 'EOF' > "$dest/Kernel.h"
#ifndef CORE_ENTITLEMENTS_V2_KERNEL_H
#define CORE_ENTITLEMENTS_V2_KERNEL_H

#include <CoreEntitlements/V2/API.h>
#include <CoreEntitlements/CoreEntitlementsPriv.h>

typedef struct coreentitlements_kernel_api {
    uint32_t version;
    CEReturn_t (*contextGetLegacyContext)(const CEContext_t *ctx, const void **legacy_ctx);
    CEReturn_t (*contextValueForKey)(const CEContext_t *ctx, const char *key, CEElement_t *out);
    CEReturn_t (*elementMatchBool)(const CEElement_t *elem, bool expected);
    CEReturn_t (*elementGetCEBuffer)(const CEElement_t *elem, CEBuffer_t *out);
    CEReturn_t (*contextInitWithTypeLegacy)(
        CERuntime_t rt,
        CEContextType_t type,
        CEContext_t *ctx,
        const uint8_t *data,
        size_t length);
    CEReturn_t (*contextCheckAcceleration)(const CEContext_t *ctx);
    CEReturn_t (*contextEvaluateAcceleration)(const CEContext_t *ctx, size_t *out_length);
    CEReturn_t (*contextAccelerate)(CEContext_t *ctx);
} CEKernelAPI_t;

#endif /* CORE_ENTITLEMENTS_V2_KERNEL_H */
EOF
}

if [[ -n "${KDKROOT:-}" ]]; then
    write_ce_v2_headers "${KDKROOT}/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/platform/CoreEntitlements/V2"
fi

if [[ -d EXTERNAL_HEADERS ]]; then
    write_ce_v2_headers "EXTERNAL_HEADERS/CoreEntitlements/V2"
    mkdir -p EXTERNAL_HEADERS/os
    if [[ ! -f EXTERNAL_HEADERS/os/firehose_buffer_private.h ]]; then
        cat << 'EOF' > EXTERNAL_HEADERS/os/firehose_buffer_private.h
#ifndef __OS_FIREHOSE_BUFFER_PRIVATE__
#define __OS_FIREHOSE_BUFFER_PRIVATE__
#include <os/base.h>
#include <stdint.h>
typedef union firehose_buffer_u *firehose_buffer_t;
#endif
EOF
    fi
    echo "Staged KDK-free CoreEntitlements/V2 headers for SWEET"
fi
