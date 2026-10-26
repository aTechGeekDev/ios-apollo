#!/usr/bin/env python3
"""Make the kernel's WLFW message header from Linux's ath11k sources (xnu 0127, bsd/dev/sweet_wlfw.c).

  mk-wlfw-header.py ATH11K_DIR OUT.h [--patch OUT.patch] [--chip "qca6390 hw2.0"]

ATH11K_DIR holds Linux's drivers/net/wireless/ath/ath11k/{qmi.c,qmi.h,core.c,hw.c,ce.h,htc.h}. The
header is ath11k's qmi.h (its message structures) and the qmi_elem_info tables of its qmi.c, with
the copy-engine pipes and service map that the chip's entry in core.c names (for the firmware's
configuration message), on top of the names of a Linux kernel qmi.h uses. ath11k is
BSD-3-Clause-Clear: the header is made in CI for each kernel build (.github/workflows/xnu.yml) and
is never kept in this repository. --patch also writes it as a patch that creates
bsd/dev/sweet_wlfw_ath11k.h, for the xnu build script's patch step.

Adapted from HackiOS's tools/mk-wlfw.sh (github.com/oosexgang/hackios-xnu-kernel), which does the
same for the WCN6750.
"""
import re
import sys


def header(src, chip):
    c = open(src + '/qmi.c').read()
    h = open(src + '/qmi.h').read()
    core = open(src + '/core.c').read()
    hw = open(src + '/hw.c').read()
    ce = open(src + '/ce.h').read()
    htc = open(src + '/htc.h').read()
    out = []
    out.append("/* ath11k's qmi.h and the message tables of its qmi.c, Linux's drivers/net/wireless/ath/ath11k\n"
               " * (BSD-3-Clause-Clear), put together by tools/mk-wlfw-header.py for %s: made at build time,\n"
               " * not to be edited, not kept in git. */" % chip)
    out.append('''#ifndef _SWEET_WLFW_ATH11K_H_
#define _SWEET_WLFW_ATH11K_H_
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef uint16_t __le16;
typedef uint32_t __le32;
typedef uint64_t __le64;
typedef uint64_t dma_addr_t;
#define __iomem
#ifndef INT_MAX
#define INT_MAX __INT_MAX__
#endif
#ifndef INT_MIN
#define INT_MIN (-__INT_MAX__ - 1)
#endif
struct list_head { struct list_head *next, *prev; };
struct work_struct { int unused; };
struct workqueue_struct;
typedef struct { int unused; } spinlock_t;
typedef struct { int unused; } wait_queue_head_t;
''')
    out.append(re.sub(r'^#include <linux/[^>]*>\n', '', h, flags=re.M))
    tables = re.findall(r'static const struct qmi_elem_info \w+\[\] = \{.*?\n\};\n', c, re.S)
    if len(tables) < 20:
        sys.exit('mk-wlfw-header.py: only %d message tables in qmi.c: not the file expected' % len(tables))
    out.append('\n'.join(tables))
    at = core.find('"%s"' % chip)
    if at < 0:
        sys.exit('mk-wlfw-header.py: no entry "%s" in core.c' % chip)
    entry = core[at:]
    entry = entry[:entry.index('\n\t},')]

    def of(field):
        m = re.search(r'\.%s = (\w+),' % field, entry)
        if not m:
            sys.exit('mk-wlfw-header.py: the entry "%s" has no .%s' % (chip, field))
        return m.group(1)
    out.append("/* as Linux has it on a little-endian machine, whatever this kernel's headers define */")
    out.append('#undef __BIG_ENDIAN\n#define __cpu_to_le32(x) (x)')
    out.append(re.search(r'#define CE_ATTR_BYTE_SWAP_DATA.*?#endif\n', ce, re.S).group(0))
    out.append(''.join(re.findall(r'^#define PIPEDIR_\w+.*\n', ce, re.M)))
    for name in ('service_to_pipe', 'ce_pipe_config'):
        out.append(re.search(r'struct %s \{.*?\n\};\n' % name, ce, re.S).group(0))
    out.append(re.search(r'enum ath11k_htc_svc_gid \{.*?\n\};\n', htc, re.S).group(0))
    out.append(re.search(r'#define SVC\(group, idx\).*?\n.*?\n', htc).group(0))
    out.append(re.search(r'enum ath11k_htc_svc_id \{.*?\n\};\n', htc, re.S).group(0))
    out.append('#undef SVC')
    for kind, field in (('ce_pipe_config', 'target_ce_config'), ('service_to_pipe', 'svc_to_ce_map')):
        out.append('static ' + re.search(r'const struct %s %s\[\] = \{.*?\n\};\n' % (kind, of(field)), hw, re.S).group(0))
    out.append('#define WLFW_CHIP\t\t"%s"' % chip)
    out.append('#define WLFW_SERVICE_INSTANCE\t%s' % of('qmi_service_ins_id'))
    out.append('#define WLFW_PIPES\t\t%s\n#define WLFW_PIPE_COUNT\t\t%s' % (of('target_ce_config'), of('target_ce_count')))
    out.append('#define WLFW_SERVICES\t\t%s\n#define WLFW_SERVICE_COUNT\t%s' % (of('svc_to_ce_map'), of('svc_to_ce_map_len')))
    out.append('#define WLFW_SENDS_INI\t\t%d\t/* fw_wmi_diag_event */' % (of('fw_wmi_diag_event') == 'true'))
    out.append('#define WLFW_SHADOW_REGISTERS\t%d\t/* supports_shadow_regs */' % (of('supports_shadow_regs') == 'true'))
    out.append('#define WLFW_M3\t\t\t%d\t/* m3_fw_support */' % (of('m3_fw_support') == 'true'))
    out.append('#endif /* _SWEET_WLFW_ATH11K_H_ */')
    return '\n'.join(out) + '\n'


def main():
    args = sys.argv[1:]
    chip = 'qca6390 hw2.0'
    patch = None
    if '--chip' in args:
        i = args.index('--chip')
        chip = args[i + 1]
        del args[i:i + 2]
    if '--patch' in args:
        i = args.index('--patch')
        patch = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2:
        sys.exit(__doc__)
    text = header(args[0], chip)
    open(args[1], 'w').write(text)
    if patch:
        lines = text.split('\n')[:-1]
        with open(patch, 'w') as f:
            f.write('--- /dev/null\n+++ b/bsd/dev/sweet_wlfw_ath11k.h\n@@ -0,0 +1,%d @@\n' % len(lines))
            f.write(''.join('+' + line + '\n' for line in lines))
    print('mk-wlfw-header.py: %s for %s: %d tables, %d lines' % (args[1], chip, text.count('qmi_elem_info ') - 0,
                                                                   text.count('\n')), file=sys.stderr)


if __name__ == '__main__':
    main()
