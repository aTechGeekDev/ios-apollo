# Device agent guide (unixnu-apollo)

This directory is the UniXNU format 2 device repository of project-BadApple: the apollo board DTS,
the iOS 16.7.16 OS profile, payload policy, the ADT bridge and the porting record. The repository root
`AGENTS.md` and `NOTES.md` still apply (handoff in NOTES.md after each milestone; device dumps, serials
and Apple files stay out of git; destructive phone steps need the user's confirmation).

## Read first

| Task | Required reading |
| --- | --- |
| Every change | README.md, porting.toml, [Porting](https://unixnu.com/porting/), [device repository](https://unixnu.com/porting/device-repository), [records](https://unixnu.com/porting/records) |
| Hardware | [Device tree](https://unixnu.com/porting/device-tree), UniXNU-sm8250-common's `dts/sm8250.dtsi`, `tools/mkadt.py` (what the SWEET kernel reads) |
| Images | [Payload](https://unixnu.com/concepts/payload), [boot chain](https://unixnu.com/concepts/boot-chain), DarwinBoot's `DarwinBoot.c` |
| Kernel | `xnu/README.md`, `xnu/patches/`, `.github/workflows/xnu.yml` at the repository root |

## Rules

- Hardware values come from this phone (NOTES.md, tools/mkadt.py) or name another measured source in a
  comment (Pistachio-Project's Mi 10T, uefi-apollo's memory map).
- Every change updates the owning porting.toml area's findings or evidence; host and device results are
  separate evidence entries with the full commit. Run `python3 scripts/porting-record.py check --device`
  from the UniXNU checkout before committing.
- Each item `scripts/apollo-adt.py gap` lists moves out of the bridge into dts/apollo.dts, the profiles or
  a kernel patch, one at a time, and the gap report shrinks with it. The bridge must never hide a value the
  generator also writes without a comment saying why (today: dram-base/dram-size = the kernel window).
- The kernel command line stays under 608 bytes (xnu-8796 BOOT_LINE_LENGTH); options go into
  /sweet-options (`mkadt.py --option`).
- SoC-wide resources go to UniXNU-sm8250-common (Pistachio-Project), not here.
