# userland: programs for the phone

iOS arm64 programs, built by `.github/workflows/userland.yml` (Xcode's
iPhoneOS SDK, ad-hoc signed) into the `sweet-userland` artifact.

| Program | What it does |
|---|---|
| `gpu-test/sweet-gpu-test` | Opens the `SweetGPU` service (kernel 0112+, boot-args `sweetgpu=22 sweetgpukeep=1`), makes and maps two buffers, submits 64 `CP_MEM_WRITE` command buffers and waits for each fence. Success line: `A PROGRAM DRIVES THE GPU` |

## Putting a program on the phone

With the phone in recovery (`fastboot boot recovery/recovery.img`):

```sh
tools/sweet-root-add.sh sweet-userland/sweet-gpu-test com.sweet.gputest
```

It copies the phone's iOS root (the first 16 GiB of `userdata`, about 12
minutes, about 33 GB free needed under `research/`), adds the program to
`/usr/local/bin` and a launchd job that runs it at every boot (output in the
console log that `tools/sweet-log-pull.sh` reads), and builds an image of only
the changed blocks. It then asks before it writes anything: only `yes` makes it
reboot the phone to fastboot and flash those blocks to `userdata`.

Needs `hfsprogs` (`fsck.hfsplus`), the `hfsplus` kernel module and sudo. The
root is pulled fresh every time, because every boot with `rootrw=1` changes it.
Root images and the built programs stay out of git (`research/` and
`sweet-userland/` are ignored).
