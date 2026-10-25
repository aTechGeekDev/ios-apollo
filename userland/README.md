# userland: programs for the phone

iOS arm64 programs, built by `.github/workflows/userland.yml` (Xcode's
iPhoneOS SDK, ad-hoc signed) into the `sweet-userland` artifact.

| Program | What it does |
|---|---|
| `gpu-test/sweet-gpu-test` | Opens the `SweetGPU` service (kernel 0113+, boot-args `sweetgpu=22 sweetgpukeep=1`), makes and maps two buffers, submits 64 `CP_MEM_WRITE` command buffers and waits for each fence. Success line: `A PROGRAM DRIVES THE GPU` (boot 30) |
| `gl-test/sweet-gl-test` | OpenGL ES 2 through Mesa (`lib/libOSMesa.8.dylib`): one triangle drawn by the GPU into a 256 x 256 texture, read back and checked (background, the three corner colours, the covered area), then 100 frames timed. Says when Mesa fell back to software. Success line: `MESA DRAWS WITH THE GPU` |
| `ca-bridge/` | The CoreAnimation bridge: `libsweet-gl.dylib` is HackiOS's `eagl.c` (MIT, `LICENSE.HackiOS`), OpenGL ES behind `EAGLContext` so backboardd's CoreAnimation draws with Mesa on the GPU (IOSurfaces as GPU buffers through kernel 0114); `libsweet-ca.dylib` is what the kernel inserts into backboardd (boot-arg `sweetinject=/usr/local/lib/libsweet-ca.dylib:backboardd`): it waits for `SweetGPU` (up to `sweetgl_wait` s, default 60), then loads the bridge; `sweetgl=0` or no GPU: software rendering as before. Log lines `sweet-ca:` and `sweet-gl:` (stderr of backboardd: `sweetnull=backboardd,...`) |
| `mesa/` | `build.sh` builds Mesa 25.0.7 (`libOSMesa.8.dylib`: OpenGL ES 2/3, freedreno on the GPU, softpipe without it; installed to `/usr/local/lib`). `patches/` and `sweet-drm/` (the libdrm stand-in that turns DRM requests into `SweetGPU` calls) are adapted from [HackiOS](https://github.com/oosexgang/hackios-xnu-userland) (MIT) |

A program's output reaches the kernel's console log only with its name in
boot-arg `sweetnull` (patch 0048 copies what those programs write to
`/dev/null`, launchd's default for a job's stdout):
`sweetnull=backboardd,SpringBoard,sweet-gpu-test,sweet-gl-test`. Writing to
`/dev/console` does not reach that log.

## Putting a program on the phone

The root on the phone has done its first-boot setup (that once took hours), so
add to it (`sweet-root-add.sh`, below) rather than flash a fresh one. Both
scripts install through `tools/sweet-root-install.sh`: with no program named,
every test program of `sweet-userland/` that is there, each with its launchd
job, and `sweet-userland/lib/*` into `/usr/local/lib`.

### A fresh iOS root with the programs

On the Linux PC, with the built programs in `sweet-userland/`:

```sh
tools/build-ios-root.sh
```

It downloads the three disk images of the iPhone X iOS 16.7.16 IPSW (OS,
SystemOS, AppOS, about 7.5 GB, into `research/ipsw/`; kept, so a second run
skips this), builds the 16 GiB HFS+ root (`tools/mkiosroot.sh`), applies the
repo's changes (`tools/sweet-root-tweaks.py`), adds
`sweet-userland/sweet-gpu-test` to `/usr/local/bin` with a launchd job that
runs it at every boot, and makes `research/ios-root/ios16-root.simg`.
`--reuse` starts from the image an earlier run left instead (no download, no
rebuild): for a changed `sweet-root-tweaks.py` or a new program build. Then it
asks: only `yes` flashes that to `userdata` (phone in fastboot, about 7
minutes). This replaces the whole iOS root on the phone, so anything an
earlier boot wrote there is gone. Other programs:
`tools/build-ios-root.sh PROGRAM LABEL [PROGRAM LABEL]...`.

Needs `curl apfs-fuse hfsprogs rsync android-sdk-libsparse-utils fastboot adb`
(Kali: `sudo apt install` those), sudo, the `hfsplus` kernel module and about
40 GB free under `research/`. Earlier images and a stale mount are removed
first, and the PC is kept from sleeping while it runs. If api.ipsw.me does not
answer, give the IPSW link yourself: `IPSW_URL=https://... tools/build-ios-root.sh`.

### Adding programs to the root already on the phone (recommended)

With the phone in recovery (`fastboot boot recovery/recovery.img`):

```sh
tools/sweet-root-add.sh                 # or: tools/sweet-root-add.sh PROGRAM LABEL [PROGRAM LABEL]...
```

It deletes what earlier tries left in `research/`, copies the phone's iOS root
(the first 16 GiB of `userdata`, about 20 minutes, about 33 GB free needed
under `research/`), shows a progress bar for the whole job and one for the
current step, adds the program to
`/usr/local/bin` and a launchd job that runs it at every boot (output in the
console log that `tools/sweet-log-pull.sh` reads), and builds an image of only
the changed blocks. It then asks before it writes anything: only `yes` makes it
reboot the phone to fastboot and flash those blocks to `userdata`.

After the flash, the edited copy (which is now what the phone has) becomes
`research/ios-root/ios16-root.img`, so a later `build-ios-root.sh --reuse`
starts from a root that has done its first boot.

Needs `hfsprogs` (`fsck.hfsplus`), the `hfsplus` kernel module and sudo. The
root is pulled fresh every time, because every boot with `rootrw=1` changes it.

Root images, the downloaded IPSW parts and the built programs stay out of git
(`research/` and `sweet-userland/` are ignored).
