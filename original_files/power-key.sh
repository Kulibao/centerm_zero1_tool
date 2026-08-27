#!/bin/sh

EVENT="${1:-short-press}"
TIMEOUT=3
PIDFILE="/tmp/$(basename "$0").pid"

# NAS ref DT (fdt_live): pwms to pwm@fe6e0030, period 0x61a8 (25000 ns) ≈ 40 kHz
beep_one_pwm() {
	CHIP=$1
	PER=$2
	DUT=$3
	[ -d "$CHIP" ] || return 1
	[ -d "$CHIP/pwm0" ] || echo 0 > "$CHIP/export" 2>/dev/null || true
	[ -d "$CHIP/pwm0" ] || return 1
	echo "$PER" > "$CHIP/pwm0/period" 2>/dev/null || return 1
	echo "$DUT" > "$CHIP/pwm0/duty_cycle" 2>/dev/null || return 1
	echo 0 > "$CHIP/pwm0/enable" 2>/dev/null || true
	echo 1 > "$CHIP/pwm0/enable" 2>/dev/null || return 1
	sleep .3
	echo 0 > "$CHIP/pwm0/enable" 2>/dev/null || true
	return 0
}

# 实测 R5S 类板：蜂鸣器在 GPIO0 line18，有源型用“拉高再拉低”即可，音较干净；Shell 快翻会嘈杂。
beep_gpio0_line18_active() {
	G=/sys/class/gpio/gpio18
	[ -e "$G" ] && return 1
	echo 18 > /sys/class/gpio/export 2>/dev/null || return 1
	echo out > "$G/direction" 2>/dev/null || { echo 18 > /sys/class/gpio/unexport 2>/dev/null; return 1; }
	echo 1 > "$G/value"
	sleep 0.28
	echo 0 > "$G/value"
	echo 18 > /sys/class/gpio/unexport 2>/dev/null || true
	return 0
}

beep_buzzer() {
	if [ -w /sys/devices/platform/gpio_ctrl/buzzer_gpio ]; then
		echo 'buzzer_en:2' > /sys/devices/platform/gpio_ctrl/buzzer_gpio
		sleep 0.28
		echo 'buzzer_en:0' > /sys/devices/platform/gpio_ctrl/buzzer_gpio
		return 0
	fi

	if beep_gpio0_line18_active; then
		logger -t power-key.sh "buzzer: GPIO0 line18 short pulse (active)"
		return 0
	fi

	for CHIP in /sys/class/pwm/pwmchip0 /sys/class/pwm/pwmchip1 /sys/class/pwm/pwmchip2; do
		beep_one_pwm "$CHIP" 25000 12500 && {
			logger -t power-key.sh "buzzer: PWM $(basename "$CHIP") 40kHz"
			return 0
		}
		beep_one_pwm "$CHIP" 1000000 500000 && {
			logger -t power-key.sh "buzzer: PWM $(basename "$CHIP") 1kHz"
			return 0
		}
	done

	logger -t power-key.sh "buzzer: gpio_ctrl, GPIO18, and PWM all failed or unavailable"
	return 1
}

short_press() {
	logger -t power-key.sh "short press"
}

long_press() {
	logger -t power-key.sh "long press (${TIMEOUT}s)"
	beep_buzzer
	logger -t power-key.sh "poweroff"
	poweroff
}

case "$EVENT" in
	press)
		start-stop-daemon -K -q -p "$PIDFILE" || true
		start-stop-daemon -S -q -b -m -p "$PIDFILE" -x /bin/sh -- -c "sleep $TIMEOUT; $0 long-press"
		;;
	release)
		sleep .2
		start-stop-daemon -K -q -p "$PIDFILE" && short_press
		;;
	short-press)
		short_press
		;;
	long-press)
		long_press
		;;
esac
