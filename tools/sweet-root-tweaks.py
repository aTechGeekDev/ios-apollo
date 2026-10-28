#!/usr/bin/env python3
"""Apply the SWEET bring-up changes to an iOS root made by tools/mkiosroot.sh.

  sudo sweet-root-tweaks.py [--oslog] MOUNTED_ROOT

MOUNTED_ROOT is the HFS+ image mounted read-write (Linux: run
`fsck.hfsplus -fy` on the image, then `mount -t hfsplus -o loop,force`).
Run as root (it writes root/mobile owned files). Idempotent. This is what
turned the plain mkiosroot.sh output into the images that reach the home
screen (image versions v8-v14 in NOTES.md):

  launchd.plist   _PanicOnCrash -> _PanicOnCrasX (a crashing daemon must not
                  panic the system); CommCenter jobs removed (no baseband: it
                  crash-loops and Setup blocks on its CoreTelephony XPC)
  containers      /private/var/containers/{Bundle,Data/System,Shared/SystemGroup,Temp}
                  (on iOS they live on the data volume)
  stock apps      the removable ones (Weather, Notes, Calendar, ...) moved from
                  /private/var/staged_system_apps to /Applications: on an
                  iPhone the first boot's data migration (SystemAppMigrator)
                  installs them, and this root skips the migration (below);
                  LaunchServices registers /Applications when it builds its
                  database at the first boot. Takes effect on a fresh root only
  migration       LastSystemVersion, in the plain file and in the ByHost
                  (kCFPreferencesCurrentHost) file datamigrator reads, named
                  by the IOPlatformUUID the kernel derives from mkadt.py's
                  /chosen unique-chip-id + chip-id; without it DataMigration
                  runs on every boot and holds SpringBoard at the Apple logo
                  (images v11/v12; apollo boot 29)
  audio           VirtualAudio HAL plug-in disabled (mediaserverd crash);
                  tools/root-files/audio-on.txt moves it back together with
                  our output device (apollo_audio=5)
  MediaToolbox    StartRecorderServer=false (camera filter prewarm calls a
                  NULL OpenGL function without a GPU -> mediaserverd crash loop)
  extensions      ExtensionKit feature flag enforce_xpc_cache_code_signing off
                  (/private/var/preferences/FeatureFlags/Domain/ExtensionKit.plist:
                  the extension point catalog is trusted only through a detached
                  signature checked against trust caches we lack, so every app
                  extension (wallpapers, widgets) was turned down) and launchd's
                  override list (/private/var/db/com.apple.xpc.launchd/disabled.plist)
                  switching off fairplayd.H2 and bluetoothd: both restart every few
                  seconds here (no FairPlay hardware, no Bluetooth driver) and a
                  request queued on them is never answered, which deadlocked
                  LaunchServices' app scan (apollo boots 47-48; boot 50 with both:
                  wallpapers and widgets work; ios-sailfish removes fairplayd too)
  CoreAnimation   CAEnableDeepFramebuffer, CAEnableFramebufferCompression and
                  CAEnableIOSurfaceCompression off in the global preferences
                  (mobile's and root's): with a GPU renderer CoreAnimation
                  otherwise draws the screen in 'b3a8' (10-bit + opacity
                  planes), which the panel copy and the CoreAnimation bridge
                  do not take (apollo boots 35/36; ios-flame found the switch)
  SpringBoard     BKNoWatchdogs (one slow CPU path, no scene-create watchdog
                  kills), no cloud-configuration UI
  Setup           skipped: SetupDone, SetupFinishedAllSteps, SetupVersion 11,
                  mini-buddy flags off
  activation      mobileactivationd data ark seeded; the actual Activated state
                  comes from its Hactivation branch, selected by the /chosen
                  security-status properties in tools/mkadt.py

--oslog (diagnosis; without it the setting is taken out again): backboardd,
SpringBoard and the datamigrator XPC service run with OS_ACTIVITY_DT_MODE=YES,
so their os_log messages also go to stderr (/dev/null), which kernel patch
0048 copies into the console log for the names in boot-arg sweetnull:
sweetnull=backboardd,SpringBoard,com.apple.datamigrator (p_name, full length).
"""
import glob, hashlib, os, plistlib, shutil, struct, sys, uuid

BUILD, VERSION = '20H392', '16.7.16'
MOBILE = 501
SWEET_ECID, CHIP_ID = 0x5357454554000001, 0x8015      # tools/mkadt.py /chosen


def load(path):
    with open(path, 'rb') as f:
        return plistlib.load(f)


def save(path, data, uid, gid, mode, fmt=plistlib.FMT_BINARY):
    with open(path, 'wb') as f:
        plistlib.dump(data, f, fmt=fmt)
    os.chown(path, uid, gid)
    os.chmod(path, mode)


def merge_pref(root, name, values, home='mobile', uid=MOBILE):
    """Merge keys into /var/HOME/Library/Preferences/NAME.plist (that user's, 0600)."""
    d = os.path.join(root, 'private/var', home, 'Library/Preferences')
    if not os.path.isdir(d):
        os.makedirs(d)
        os.chown(d, uid, uid)
        os.chmod(d, 0o755)
    path = os.path.join(d, name + '.plist')
    data = load(path) if os.path.exists(path) else {}
    data.update(values)
    save(path, data, uid, uid, 0o600)
    print('pref', home, name, sorted(values))


def platform_uuid():
    """IOPlatformUUID as XNU makes it on arm (IOPlatformExpertDevice::generatePlatformUUID):
    a name-based SHA-1 UUID of /chosen unique-chip-id (8 bytes) + chip-id (4 bytes)."""
    space = bytes.fromhex('a6dd4ccbb5e84af5acddb6dc6a0542b8')
    d = bytearray(hashlib.sha1(space + struct.pack('<QI', SWEET_ECID, CHIP_ID)).digest()[:16])
    d[6] = (d[6] & 0x0f) | 0x50
    d[8] = (d[8] & 0x3f) | 0x80
    return str(uuid.UUID(bytes=bytes(d))).upper()


def merge_host_pref(root, name, values):
    """Merge keys into the ByHost NAME.<platform UUID>.plist files (upper and lower case UUID)."""
    d = os.path.join(root, 'private/var/mobile/Library/Preferences/ByHost')
    if not os.path.isdir(d):
        os.makedirs(d)
        os.chown(d, MOBILE, MOBILE)
        os.chmod(d, 0o755)
    host = platform_uuid()
    for u in (host, host.lower()):
        path = os.path.join(d, f'{name}.{u}.plist')
        data = load(path) if os.path.exists(path) else {}
        data.update(values)
        save(path, data, MOBILE, MOBILE, 0o600)
    print('host pref', name, host, sorted(values))


def launchd(root):
    path = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(path)
    plist = load(path)
    jobs = plist['LaunchDaemons']
    renamed = 0
    for job in jobs.values():
        if '_PanicOnCrash' in job:
            job['_PanicOnCrasX'] = job.pop('_PanicOnCrash')
            renamed += 1
    removed = [k for k, j in jobs.items() if j.get('Label') == 'com.apple.CommCenter']
    for k in removed:
        del jobs[k]
    save(path, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    print(f'launchd.plist: {renamed} _PanicOnCrash renamed, {len(removed)} CommCenter jobs removed')


OSLOG_PROGRAMS = ('/backboardd', '/SpringBoard')


def oslog(root, on):
    """OS_ACTIVITY_DT_MODE=YES (os_log mirrored to stderr) for backboardd, SpringBoard, datamigrator."""
    def set_env(env_holder):
        env = env_holder.setdefault('EnvironmentVariables', {})
        if on:
            env['OS_ACTIVITY_DT_MODE'] = 'YES'
        else:
            env.pop('OS_ACTIVITY_DT_MODE', None)
            if not env:
                del env_holder['EnvironmentVariables']

    path = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(path)
    plist = load(path)
    jobs = [j for j in plist['LaunchDaemons'].values()
            if (j.get('Program') or (j.get('ProgramArguments') or [''])[0]).endswith(OSLOG_PROGRAMS)]
    for job in jobs:
        set_env(job)
    save(path, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    infos = glob.glob(os.path.join(root, 'System/Library/PrivateFrameworks/DataMigration.framework',
                                   '**/com.apple.datamigrator.xpc/Info.plist'), recursive=True)
    for info in infos:
        st = os.stat(info)
        data = load(info)
        set_env(data.setdefault('XPCService', {}))
        save(info, data, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    print(f'os_log to stderr {"on" if on else "off"}: {[j.get("Label") for j in jobs]}, '
          f'{len(infos)} datamigrator Info.plist')


def containers(root):
    base = os.path.join(root, 'private/var/containers')
    for sub, uid in (('Bundle', 33), ('Data/System', 0), ('Shared/SystemGroup', 0), ('Temp', 0)):
        d = os.path.join(base, sub)
        if not os.path.isdir(d):
            os.makedirs(d)
            os.chown(d, uid, uid)
            os.chmod(d, 0o755)
            print('mkdir', d)


def stock_apps(root):
    staged = os.path.join(root, 'private/var/staged_system_apps')
    apps = os.path.join(root, 'Applications')
    if not os.path.isdir(staged):
        print('warning: no /private/var/staged_system_apps in the image; removable stock apps not added')
        return
    moved, there = [], []
    for name in sorted(os.listdir(staged)):
        if not name.endswith('.app'):
            continue
        if os.path.exists(os.path.join(apps, name)):
            there.append(name)
            continue
        os.rename(os.path.join(staged, name), os.path.join(apps, name))
        moved.append(name)
    print(f'stock apps: {len(moved)} moved to /Applications {[n[:-4] for n in moved]}, '
          f'{len(there)} already there, {len([n for n in os.listdir(apps) if n.endswith(".app")])} in /Applications')


def find_container(root, kind, identifier):
    for meta in glob.glob(os.path.join(root, 'private/var/containers', kind, '*',
                                       '.com.apple.mobile_container_manager.metadata.plist')):
        if load(meta).get('MCMMetadataIdentifier') == identifier:
            return os.path.dirname(meta)
    return None


def activation(root):
    c = find_container(root, 'Data/System', 'com.apple.mobileactivationd')
    if c is None:
        print('warning: no mobileactivationd system container in the image; skipped data ark')
        return
    d = os.path.join(c, 'Library/internal')
    os.makedirs(d, exist_ok=True)
    os.chown(d, MOBILE, MOBILE)
    os.chmod(d, 0o755)
    save(os.path.join(d, 'data_ark.plist'), {
        '-ActivationState': 'Activated', '-BrickState': False,
        '-BuildVersion': BUILD, '-ProductVersion': VERSION,
        '-DataMigrationCompleted': True, '-PreSydroDataMigrationCompleted': True,
    }, MOBILE, MOBILE, 0o600)
    print('data ark', d)


def audio(root):
    src = os.path.join(root, 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin')
    dst_dir = os.path.join(root, 'Library/Audio/Plug-Ins/HAL.disabled')
    if os.path.exists(src):
        os.makedirs(dst_dir, exist_ok=True)
        shutil.move(src, dst_dir)
        print('VirtualAudio.plugin disabled')
    for conf in glob.glob(os.path.join(root, 'System/Library/Frameworks/MediaToolbox.framework/*/SubServerConfiguration.plist')):
        st = os.stat(conf)
        data = load(conf)
        data['StartRecorderServer'] = False
        save(conf, data, st.st_uid, st.st_gid, st.st_mode & 0o7777, plistlib.FMT_XML)
        print('StartRecorderServer off', os.path.relpath(conf, root))


def extensions(root):
    d = os.path.join(root, 'private/var/preferences/FeatureFlags/Domain')
    os.makedirs(d, exist_ok=True)
    save(os.path.join(d, 'ExtensionKit.plist'), {'enforce_xpc_cache_code_signing': {'Enabled': False}}, 0, 0, 0o644,
         plistlib.FMT_XML)
    d = os.path.join(root, 'private/var/db/com.apple.xpc.launchd')
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, 'disabled.plist')
    data = load(path) if os.path.exists(path) else {}
    data.update({'com.apple.fairplayd.H2': True, 'com.apple.bluetoothd': True})
    save(path, data, 0, 0, 0o644, plistlib.FMT_XML)
    print('ExtensionKit flag off; launchd disabled.plist: fairplayd.H2, bluetoothd')


def main():
    args = [a for a in sys.argv[1:] if a != '--oslog']
    if len(args) != 1 or not os.path.isdir(os.path.join(args[0], 'System/Library/xpc')):
        sys.exit(__doc__)
    root = args[0]
    launchd(root)
    oslog(root, '--oslog' in sys.argv[1:])
    containers(root)
    stock_apps(root)
    activation(root)
    audio(root)
    extensions(root)
    merge_pref(root, 'com.apple.migration', {
        'LastSystemVersion': BUILD,
        'DMUserDataDisposition': {'SyntheticDidUpgrade': False, 'buildVersion': BUILD}})
    merge_host_pref(root, 'com.apple.migration', {'LastSystemVersion': BUILD})
    for home, uid in (('mobile', MOBILE), ('root', 0)):
        merge_pref(root, '.GlobalPreferences', {
            'CAEnableDeepFramebuffer': False, 'CAEnableFramebufferCompression': False,
            'CAEnableIOSurfaceCompression': False}, home, uid)
    merge_pref(root, 'com.apple.springboard', {
        'BKNoWatchdogs': True,
        'FBLaunchWatchdogExceptions': {'com.apple.purplebuddy': 100.0},
        'MCForceShowCloudConfigurationUI': False})
    merge_pref(root, 'com.apple.purplebuddy', {
        'SetupDone': True, 'SetupFinishedAllSteps': True, 'SetupVersion': 11,
        'daemonizeNeedsToRun': False})
    merge_pref(root, 'com.apple.purplebuddy.notbackedup', {
        k: False for k in ('ShouldRunDiagnosticsMiniBuddy', 'ShouldRunHSA2MiniBuddy',
                           'ShouldRunKeychainSyncMiniBuddy', 'ShouldRunMesaMiniBuddy',
                           'ShouldRunPaymentMiniBuddy', 'ShouldRunStandardMiniBuddy',
                           'SilentICDPUpgrade')})
    merge_pref(root, 'com.apple.managedconfiguration.notbackedup', {
        'LockdownActivationIndicatesCloudConfigurationAvailable': False})


if __name__ == '__main__':
    main()
