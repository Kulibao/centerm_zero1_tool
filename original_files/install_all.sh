#!/usr/bin/env bash
set -euo pipefail

# Unified installer for RK3568 NAS-like setup:
# - Device tree
# - Boot beep + power-key beep
# - Power LED solid green
# - SATA LED policy (idle green, io blink, error red)
# - Fan control service
# - Author: chenfm
# - Date: 2026-06-18

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d_%H%M%S)"

SRC_DTB="${DIR}/rk3568-nanopi-r5s-new.dtb"
DST_DTB="/boot/dtb/rockchip/rk3568-nanopi-r5s.dtb"

mkdir -p /etc/triggerhappy/triggers.d

install -m 755 "${DIR}/beep-short.sh" /usr/local/sbin/beep-short.sh
install -m 644 "${DIR}/beep-boot.service" /etc/systemd/system/beep-boot.service

install -m 755 "${DIR}/power-led-solid.sh" /usr/local/sbin/power-led-solid.sh
install -m 644 "${DIR}/power-led-solid.service" /etc/systemd/system/power-led-solid.service

install -m 755 "${DIR}/power-key.sh" /usr/bin/power-key.sh
install -m 644 "${DIR}/triggerhappy-power-key.conf" /etc/triggerhappy/triggers.d/power-key.conf
install -m 755 "${DIR}/buzzer-test.sh" /usr/bin/buzzer-test.sh

install -m 755 "${DIR}/sata-led-enable.sh" /usr/local/sbin/sata-led-enable.sh
install -m 644 "${DIR}/sata-led-enable.service" /etc/systemd/system/sata-led-enable.service
install -m 755 "${DIR}/sata-led-manager.sh" /usr/local/sbin/sata-led-manager.sh
install -m 644 "${DIR}/sata-led-manager.service" /etc/systemd/system/sata-led-manager.service

install -m 755 "${DIR}/fan_temp_control.sh" /usr/local/bin/fan_temp_control.sh
install -m 644 "${DIR}/fan-control.service" /etc/systemd/system/fan-control.service

if [[ -f "${SRC_DTB}" ]]; then
  if [[ -f "${DST_DTB}" ]]; then
    cp -a "${DST_DTB}" "${DST_DTB}.bak_${TS}"
  fi
  install -m 644 "${SRC_DTB}" "${DST_DTB}"
  echo "DTB installed: ${DST_DTB} (backup created if old file existed)"
else
  echo "WARNING: ${SRC_DTB} not found, skip DTB install"
fi

systemctl daemon-reload

# Keep old LED service disabled (replaced by sata-led-manager)
systemctl disable --now HDled_monit_v0.service 2>/dev/null || true

systemctl enable --now beep-boot.service
systemctl enable --now power-led-solid.service
systemctl enable --now sata-led-enable.service
systemctl enable --now sata-led-manager.service
systemctl enable --now fan-control.service

if systemctl list-unit-files triggerhappy.service &>/dev/null; then
  systemctl restart triggerhappy.service || true
fi

echo
echo "Install completed."
echo "- Reboot is recommended for DTB changes to take effect."
read -r -p "Reboot now? [Y/N]: " reboot_answer
if [[ "${reboot_answer}" =~ ^[Yy]$ ]]; then
  reboot
else
  echo "Skip reboot."
fi
