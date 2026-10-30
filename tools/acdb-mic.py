#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# From the Mi 10T port github.com/enesuzun2002/hakios-apollo (devices/mi-10t/tools/acdb-mic.py, f998fc2; MIT,
# Copyright (c) 2025-2026 the HakiOS authors), unchanged below: the files it writes are what sweet_mic.c (xnu 0146) loads
# from /usr/local/fw/ (tools/pull-mic-haptic-fw.sh runs it).
"""
acdb-mic.py [--device N] [--app N] [--rate N] HANDSET.acdb GLOBAL.acdb OUTDIR

The Mi 10T's (apollo) main microphone path 1 (bsd/dev/hakios.apollo_mic.c, apollo_mic_path=1) records as Android
does, through the device path Xiaomi's calibration sets up. That data is Xiaomi's and is not in this repository:
this reads it out of the phone's own ACDB files (/vendor/etc/acdbdata/Tutu/Tutu_Handset_cal.acdb and
Tutu_Global_cal.acdb, which pull-firmware.sh fetches) and writes what the driver loads from the image's fw/:

  mic_topology_v2.bin      the definition of the device path's topology, as AVCS_CMD_REGISTER_TOPOLOGIES takes it
                           (v2: with the modules' instance IDs; global property 0x132ac), that topology alone (count 1)
  mic_topology_v1.bin      the same, v1 (no instance IDs; global property 0x131a7)
  mic_topology_legacy.bin  the same, as ADM_CMD_ADD_TOPOLOGIES takes it (16 module slots; global property 0x12e47)
  mic_audproc.bin          the ADM's processing calibration for the device, app type and rate (the instance table,
                           AGIILUT0/AGIICDFT/AGIICDOT), packed as ADM_CMD_SET_PP_PARAMS_V6 takes it: each parameter a
                           param_hdr_v3 {u32 module; u16 instance; u16 reserved; u32 parameter; u32 size} and its data

Defaults: device 4 (HANDSET_MIC), app type 0x11132 (general recording), 48000 Hz; the topology is the one the
device's property 0x113ad gives that app type (0x10010315 on this phone).

The ACDB format, as found in the files (the tool says what it finds):
  "QCMSNDDB", u32 0, u32 0, char[4] kind ("AVDB" a device file, "GCDB" the global one), u32 0, u32 size, u32 size;
  then from 0x20 chunks { char id[8]; u32 size; data[size] }.
  DATAPOOL  entries { u32 length; data }; everything else points into it by its offset from the chunk's data
  GPROPLUT  u32 count, then { u32 property; u32 pool offset }                 (the global file)
  DPROPLUT  u32 count, then { u32 device; u32 property; u32 pool offset }      (a device file)
  AGIILUT0  u32 count, then { u32 device; u32 rate; u32 app; u32 cdft offset; u32 cdot offset }
  AGIICDFT  at that offset: u32 count, then { u32 module; u32 instance; u32 parameter }
  AGIICDOT  at that offset: u32 count, then u32 pool offsets, one per parameter
  Topology definitions (the global properties): u32 count, then per topology
    v2      { u32 version; u32 topology; u32 config; u32 modules; { u32 module; u32 instance } x modules }
    v1      { u32 version; u32 topology; u32 config; u32 modules; u32 module x modules }
    legacy  { u32 topology; u32 modules; 16 x { u32 module; u32 x5 } }
"""
import argparse
import os
import struct
import sys

MAGIC = b"QCMSNDDB"


class Acdb:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.data = f.read()
        d = self.data
        if d[:8] != MAGIC or len(d) < 0x20:
            raise SystemExit("%s: not an ACDB file (no %r)" % (path, MAGIC))
        self.kind = d[16:20].decode("latin1")
        self.chunks = {}
        o = 0x20
        while o + 12 <= len(d):
            cid = d[o:o + 8].decode("latin1")
            size = struct.unpack_from("<I", d, o + 8)[0]
            if o + 12 + size > len(d):
                raise SystemExit("%s: chunk %r at %d runs past the end" % (path, cid, o))
            self.chunks.setdefault(cid, (o + 12, size))
            o += 12 + size
        if o != len(d):
            raise SystemExit("%s: the chunks end at %d, the file at %d" % (path, o, len(d)))
        print("%s: %s, %d bytes, %d chunks" % (os.path.basename(path), self.kind, len(d), len(self.chunks)))
        if "DATAPOOL" not in self.chunks:
            raise SystemExit("%s: no DATAPOOL" % path)

    def u32(self, offset, count=1):
        return struct.unpack_from("<%dI" % count, self.data, offset)

    def chunk(self, cid):
        if cid not in self.chunks:
            raise SystemExit("%s: no chunk %s" % (self.path, cid))
        return self.chunks[cid]

    def pool(self, offset):
        base, size = self.chunk("DATAPOOL")
        if offset + 4 > size:
            raise SystemExit("%s: a pool offset %d past the pool's %d bytes" % (self.path, offset, size))
        length = self.u32(base + offset)[0]
        if offset + 4 + length > size:
            raise SystemExit("%s: a pool entry at %d runs past the pool" % (self.path, offset))
        return self.data[base + offset + 4:base + offset + 4 + length]

    def table(self, cid, words):
        base, size = self.chunk(cid)
        n = self.u32(base)[0]
        if 4 + 4 * words * n != size:
            raise SystemExit("%s: %s: %d entries of %d words do not make its %d bytes" % (self.path, cid, n, words, size))
        return [self.u32(base + 4 + 4 * words * i, words) for i in range(n)]


def topologies(blob, kind):
    """{topology: its definition's bytes}, the whole blob walked exactly to its end"""
    w = struct.unpack_from("<%dI" % (len(blob) // 4), blob)
    found, i = {}, 1
    for _ in range(w[0]):
        start = i
        if kind == "legacy":
            topology, i = w[i], i + 2 + 16 * 6
        elif kind == "v1":
            topology, i = w[i + 1], i + 4 + w[i + 3]
        else:
            topology, i = w[i + 1], i + 4 + 2 * w[i + 3]
        if i > len(w):
            raise SystemExit("topology definitions (%s): one runs past the end" % kind)
        found[topology] = blob[4 * start:4 * i]
    if 4 * i != len(blob):
        raise SystemExit("topology definitions (%s): %d topologies end at byte %d of %d" % (kind, w[0], 4 * i, len(blob)))
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--device", type=lambda x: int(x, 0), default=4)
    ap.add_argument("--app", type=lambda x: int(x, 0), default=0x11132)
    ap.add_argument("--rate", type=lambda x: int(x, 0), default=48000)
    ap.add_argument("handset")
    ap.add_argument("glob")
    ap.add_argument("outdir")
    a = ap.parse_args()

    dev = Acdb(a.handset)
    glb = Acdb(a.glob)

    # the device: its name, and the topology its property 0x113ad gives the app type
    props = {}
    for device, prop, offset in dev.table("DPROPLUT", 3):
        if device == a.device:
            props[prop] = dev.pool(offset)
    if not props:
        raise SystemExit("%s: no device %d" % (a.handset, a.device))
    name = props.get(0x113b8, b"").decode("utf-16-le", "replace").rstrip("\0")
    topology = None
    if 0x113ad in props:
        pairs = props[0x113ad]
        for i in range(0, len(pairs) - 7, 8):
            app, top = struct.unpack_from("<II", pairs, i)
            if app == a.app:
                topology = top
    print("device %d (%s): app type %#x -> ADM topology %s" % (a.device, name or "?", a.app,
                                                            "%#x" % topology if topology else "NOT FOUND"))
    if topology is None:
        raise SystemExit("no topology for app type %#x" % a.app)

    # the topology's three definitions
    gprops = {}
    for prop, offset in glb.table("GPROPLUT", 2):
        gprops[prop] = glb.pool(offset)
    os.makedirs(a.outdir, exist_ok=True)
    for prop, kind, fname in ((0x132ac, "v2", "mic_topology_v2.bin"), (0x131a7, "v1", "mic_topology_v1.bin"),
                              (0x12e47, "legacy", "mic_topology_legacy.bin")):
        if prop not in gprops:
            raise SystemExit("%s: no global property %#x (%s definitions)" % (a.glob, prop, kind))
        defs = topologies(gprops[prop], kind)
        if topology not in defs:
            raise SystemExit("%s: topology %#x is not among the %d %s definitions" % (a.glob, topology, len(defs), kind))
        out = struct.pack("<I", 1) + defs[topology]
        with open(os.path.join(a.outdir, fname), "wb") as f:
            f.write(out)
        print("%s: %d topologies (%s), %#x's definition: %d bytes" % (fname, len(defs), kind, topology, len(out)))

    # the calibration
    cdft_base, cdft_size = dev.chunk("AGIICDFT")
    cdot_base, cdot_size = dev.chunk("AGIICDOT")
    rows = [r for r in dev.table("AGIILUT0", 5) if r[0] == a.device and r[1] == a.rate and r[2] == a.app]
    if len(rows) != 1:
        raise SystemExit("%s: %d calibration entries for device %d, %d Hz, app %#x" % (a.handset, len(rows), a.device, a.rate,
                                                                                         a.app))
    _, _, _, cdft, cdot = rows[0]
    n = dev.u32(cdft_base + cdft)[0]
    defs = [dev.u32(cdft_base + cdft + 4 + 12 * i, 3) for i in range(n)]
    m = dev.u32(cdot_base + cdot)[0]
    if m != n or cdft + 4 + 12 * n > cdft_size or cdot + 4 + 4 * m > cdot_size:
        raise SystemExit("%s: the calibration's tables do not agree (%d parameters, %d data)" % (a.handset, n, m))
    offsets = dev.u32(cdot_base + cdot + 4, m)
    blob = b""
    for (module, instance, param), offset in zip(defs, offsets):
        data = dev.pool(offset)
        data += b"\0" * (-len(data) % 4)
        blob += struct.pack("<IHHII", module, instance, 0, param, len(data)) + data
        print("  module %#07x instance %#06x parameter %#07x: %d bytes" % (module, instance, param, len(data)))
    with open(os.path.join(a.outdir, "mic_audproc.bin"), "wb") as f:
        f.write(blob)
    print("mic_audproc.bin: device %d, %d Hz, app %#x: %d parameters, %d bytes" % (a.device, a.rate, a.app, n, len(blob)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
