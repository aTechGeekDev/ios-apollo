# userland: programs for the phone

iOS arm64 programs, built by `.github/workflows/userland.yml` (Xcode's
iPhoneOS SDK, ad-hoc signed) into the `sweet-userland` artifact.

| Program | What it does |
|---|---|
| `gpu-test/sweet-gpu-test` | Opens the `SweetGPU` service (kernel 0112+, boot-args `sweetgpu=22 sweetgpukeep=1`), makes and maps two buffers, submits 64 `CP_MEM_WRITE` command buffers and waits for each fence. Success line: `A PROGRAM DRIVES THE GPU` |

## Putting a program on the phone

The iOS root lives in the first 16 GiB of `userdata` (`/dev/block/sda34`) as
HFS+, which the recovery kernel cannot mount. Programs go in through a local
copy of the root and a flash of only the blocks that changed
(`tools/sparsediff.py`). The local copy must be exactly what the phone holds,
so pull a fresh one after any boot with `rootrw=1`, and do not boot iOS between
the pull and the flash.

Needs about 33 GB free on the PC, plus `hfsprogs` (`fsck.hfsplus`) and the
`hfsplus` kernel module.

```sh
# 1. a copy of the phone's root (phone in fastboot; ~12 minutes)
fastboot boot recovery/recovery.img
adb exec-out "dd if=/dev/block/sda34 bs=1048576 count=16384" > research/apollo-root-base.img
cp research/apollo-root-base.img research/apollo-root-new.img

# 2. edit the copy
sudo fsck.hfsplus -fy research/apollo-root-new.img
sudo mkdir -p /mnt/iosroot
sudo mount -t hfsplus -o loop,force research/apollo-root-new.img /mnt/iosroot
sudo mkdir -p /mnt/iosroot/usr/local/bin
sudo install -m 0755 sweet-userland/sweet-gpu-test /mnt/iosroot/usr/local/bin/sweet-gpu-test
python3 tools/add-launchd-job.py /mnt/iosroot/System/Library/xpc/launchd.plist /tmp/launchd.plist \
    com.sweet.gputest /usr/local/bin/sweet-gpu-test
sudo cp /tmp/launchd.plist /mnt/iosroot/System/Library/xpc/launchd.plist
sudo umount /mnt/iosroot

# 3. only the changed blocks, flashed (WRITES userdata)
python3 tools/sparsediff.py research/apollo-root-base.img research/apollo-root-new.img research/apollo-root-new.simg
adb reboot bootloader
fastboot flash userdata research/apollo-root-new.simg
```

After that, `research/apollo-root-new.img` is what the phone holds: use it as
the base for the next edit until the phone boots with `rootrw=1` again.
Root images, pulls and the built programs stay out of git (`research/` is
ignored).
