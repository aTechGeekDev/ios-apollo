#!/bin/sh
# Why did the phone reset? (the "No sudden resets" item; boots 88/89 reset in use, cause unknown)
# Right after an unexpected reset: hold the keys for fastboot WITHOUT any other reboot in between, then
#   tools/reset-reason.sh [LOG]        (boots recovery, prints and saves the PMIC's power-on / power-off reasons)
# The PM8150's PON block keeps why it last powered off and on until the next real power-off; a `fastboot boot` of
# recovery does not clear it, and recovery's kernel prints it at boot (qpnp-power-on / qcom-pon: "Power-on reason",
# "Power-off reason", "PS_HOLD", "S3 reset", "watchdog"...). Also kept: Qualcomm's restart reason (if recovery shows
# it) and the bootloader's last boot reason (androidboot.bootreason on recovery's command line).
set -u
log=${1:-logs/reset-reason-$(date +%Y%m%d-%H%M%S).txt}
mkdir -p "$(dirname "$log")"
if ! adb get-state >/dev/null 2>&1; then
	fastboot boot recovery/recovery.img && adb wait-for-recovery || exit 1
fi
{
	echo "== $(date)"
	echo "== recovery's command line (bootloader's reason)"
	adb shell cat /proc/cmdline | tr ' ' '\n' | grep -i -E 'reason|bootmode|pon|warm|reset' || true
	echo "== PMIC power-on / power-off (dmesg)"
	adb shell dmesg | grep -i -E 'power-on reason|power-off reason|pon[:_ ]|qpnp-power-on|pm8150.*(pon|reason)|ps_hold|s3 reset|watchdog|kpdpwr|warm reset|hard reset|restart reason' || true
	echo "== last kernel log, if any"
	adb shell 'ls /sys/fs/pstore 2>/dev/null; cat /sys/fs/pstore/console-ramoops* 2>/dev/null | tail -40' || true
} | tee "$log"
echo "saved: $log"
