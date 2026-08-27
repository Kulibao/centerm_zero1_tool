#!/bin/sh
# 短促干净蜂鸣：优先厂商 gpio_ctrl，否则 GPIO0 line18（与 power-key 一致）
LOGTAG=beep-short

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
