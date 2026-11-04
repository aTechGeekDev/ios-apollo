/*
 * Everything still missing before the phone can be used every day, one entry per feature.
 * The single source for the website (site/index.html) and the README's "Missing for daily use" section
 * (tools/gen-roadmap.py writes it). status: todo | partial | wip. effort: S | M | L | XL.
 */
window.ROADMAP = [
  { area: "Boot and system", items: [
    ["Boot without a computer", "Every boot is a temporary fastboot boot from a PC. The shim has to be flashed to the boot partition, with a way back to Android.", "todo", "M"],
    ["Correct date and time", "Written, not yet tested (xnu 0172, option apollo_rtc): the calendar starts from the PM8150's real-time clock, and time set by iOS is written back to it. Today each boot starts in 1970 until the network sets the time.", "wip", "S"],
    ["Power off", "Written, not yet tested (xnu 0172, option apollo_power): iOS's shutdown asks the firmware to power off (PSCI). Today the kernel only halts and the phone stays on until the power button is held.", "wip", "S"],
    ["Restart from iOS", "Written, not yet tested (xnu 0172, option apollo_power): restarts, and with apollo_power=2 kernel panics, reset the phone through the firmware.", "wip", "S"],
    ["No sudden resets", "Boots 88 and 89 reset during normal use; the cause is not found yet. tools/reset-reason.sh reads the PMIC's power-off reason from recovery after the next one.", "wip", "M"],
    ["No crash-looping system parts", "Wallpapers and speech voices that need Metal crash and restart in a loop, costing CPU and battery.", "partial", "S"],
    ["Faster boot", "About a minute from fastboot to the lock screen. The kernel waits 30 s for a clock driver that this port never published; with the PMIC clock (apollo_rtc) that wait goes away.", "wip", "M"]
  ]},
  { area: "Power and battery", items: [
    ["Battery level", "Written, not yet tested (xnu 0173, option sweetbattery): the battery service now reads the Mi 10T's PM8150B (it read the PMIC of the phone this port started from). The percentage is estimated from the voltage, not Qualcomm's fuel-gauge algorithm.", "wip", "M"],
    ["Charging status", "Written, not yet tested (xnu 0173): charger connected, charging and full come from the PM8150B's charger.", "wip", "M"],
    ["Charger control", "Charging current and temperature limits come from the bootloader's defaults, not from iOS.", "todo", "M"],
    ["Sleep and standby", "The CPU never suspends: a locked phone drains the battery almost as fast as one in use.", "todo", "L"],
    ["Screen-off power saving", "Locking turns the backlight off, but the panel, display engine and GPU stay powered.", "partial", "M"],
    ["GPU power management", "The GPU runs at a fixed clock; it should scale with the load and idle when nothing is drawn.", "partial", "M"],
    ["Battery temperature and health", "Battery Health and temperature warnings have no data.", "todo", "S"]
  ]},
  { area: "Calls, messages and location", items: [
    ["Cellular modem", "The Snapdragon X55 modem is not started: no network at all.", "todo", "XL"],
    ["SIM card", "SIM detection, PIN entry and carrier settings.", "todo", "L"],
    ["Phone calls", "Voice calls over the modem, with the earpiece, microphone and audio routing.", "todo", "XL"],
    ["SMS", "Text messages over the modem.", "todo", "L"],
    ["Mobile data", "Internet over 4G/5G.", "todo", "L"],
    ["GPS and location", "Maps, Find My and location services have only Wi-Fi to go on.", "todo", "L"]
  ]},
  { area: "Connectivity", items: [
    ["USB connection to a computer", "File transfer, Finder/iTunes and backups over USB-C.", "todo", "L"],
    ["USB networking and SSH", "A network over the cable for debugging without recovery.", "todo", "M"],
    ["USB-C headphones", "Audio through USB-C adapters and headsets.", "todo", "M"],
    ["Personal Hotspot", "Sharing the phone's connection over Wi-Fi.", "todo", "M"],
    ["AirDrop", "Apple's peer-to-peer Wi-Fi (AWDL) is not supported by the Wi-Fi driver.", "todo", "XL"],
    ["Wi-Fi power saving", "The Wi-Fi chip stays fully awake.", "todo", "M"],
    ["NFC", "The NFC controller is not used.", "todo", "L"]
  ]},
  { area: "Sensors", items: [
    ["Accelerometer and gyroscope", "Behind Qualcomm's sensor hub, which needs its firmware started first.", "todo", "L"],
    ["Screen rotation", "Needs the accelerometer.", "todo", "M"],
    ["Proximity sensor", "Turns the screen off during calls.", "todo", "L"],
    ["Auto-brightness", "Needs the ambient light sensor.", "todo", "L"],
    ["Compass", "Needs the magnetometer.", "todo", "L"],
    ["Fingerprint unlock", "The side fingerprint reader would have to stand in for Touch ID.", "todo", "XL"]
  ]},
  { area: "Camera and media", items: [
    ["Rear cameras", "Image sensors and Qualcomm's camera pipeline (Spectra ISP).", "todo", "XL"],
    ["Front camera", "Same pipeline as the rear cameras.", "todo", "XL"],
    ["Flashlight", "The kernel can light the PM8150L's flash LED in torch mode (xnu 0172, option apollo_torch, sysctl apollo.torch; not yet tested). iOS's own flashlight button goes through the camera stack, which is not there yet.", "partial", "M"],
    ["Hardware video decoding", "Videos are decoded by the CPU: hotter, slower, and some formats stutter.", "todo", "L"],
    ["Earpiece", "The earpiece amplifier is brought up, but call audio is not routed to it.", "partial", "S"]
  ]},
  { area: "Graphics and display", items: [
    ["Steady 60 fps", "25-55 fps today; the CPU and the CoreAnimation bridge are the limits.", "wip", "M"],
    ["Metal", "In progress: Turnip (Mesa's Vulkan driver) runs on the Adreno 650 and passes its tests; Metal is being put on top of it. Until then apps and games that need Metal do not run, and iOS draws through an OpenGL ES bridge.", "wip", "XL"],
    ["90 and 144 Hz", "The panel runs at 60 Hz only.", "todo", "L"]
  ]},
  { area: "Apps and Apple services", items: [
    ["Install your own apps", "Decrypted or self-built apps go into /Applications from the PC (tools/app-pack.sh, jb-post.txt), registered at the next boot. TrollStore needs a CoreTrust bug that iOS 16.7.16 does not have.", "wip", "M"],
    ["Jailbreak and Sileo", "Procursus is in /var/jb and Sileo is on the home screen and works. Left: Sileo updates land in the registered copy (jb-post.txt links it).", "partial", "M"],
    ["Tweaks", "The kernel inserts ElleKit's tweak loader into SpringBoard and apps (xnu 0174, option apollo_tweaks; not yet tested). Install ElleKit from Sileo first.", "wip", "M"],
    ["App Store apps", "App Store apps are encrypted (FairPlay); this port cannot decrypt them.", "todo", "XL"],
    ["Apple ID and iCloud", "Signing in needs a genuine device identity.", "todo", "XL"],
    ["Push notifications", "Apple's push service needs device certificates.", "todo", "XL"],
    ["iMessage and FaceTime", "Need activation with Apple.", "todo", "XL"],
    ["Siri and dictation", "Voice assistant and speech recognition.", "todo", "L"],
    ["Passcode with data protection", "The keybag is a stand-in: a passcode does not encrypt anything.", "todo", "L"]
  ]}
];
