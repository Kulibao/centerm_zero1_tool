#!/bin/sh
# 短促干净蜂鸣：优先厂商 gpio_ctrl，否则 GPIO0 line18（与 power-key 一致）
LOGTAG=beep-short
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# 网页可关闭开机蜂鸣；缺少配置时保持原版行为（默认开启）。
if [ "$FORCE" -ne 1 ] && [ -r /etc/zero1-tool/buzzer.conf ]; then
	boot_beep=$(sed -n 's/^BOOT_BEEP=//p' /etc/zero1-tool/buzzer.conf | tail -n 1)
	if [ "$boot_beep" = "0" ]; then
		logger -t "$LOGTAG" "boot beep disabled"
		exit 0
	fi
fi

if [ -w /sys/devices/platform/gpio_ctrl/buzzer_gpio ]; then
	echo 'buzzer_en:2' > /sys/devices/platform/gpio_ctrl/buzzer_gpio
	sleep 0.28
	echo 'buzzer_en:0' > /sys/devices/platform/gpio_ctrl/buzzer_gpio
	logger -t "$LOGTAG" "gpio_ctrl sysfs"
	exit 0
fi

G=/sys/class/gpio/gpio18
if [ -e "$G" ]; then
	logger -t "$LOGTAG" "gpio18 busy, skip"
	exit 0
fi

echo 18 > /sys/class/gpio/export 2>/dev/null || exit 0
echo out > "$G/direction" 2>/dev/null || {
	echo 18 > /sys/class/gpio/unexport 2>/dev/null
	exit 0
}
echo 1 > "$G/value"
sleep 0.28
echo 0 > "$G/value"
echo 18 > /sys/class/gpio/unexport 2>/dev/null
logger -t "$LOGTAG" "GPIO0 line18 pulse"
exit 0
