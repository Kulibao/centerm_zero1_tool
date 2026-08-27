#!/usr/bin/env bash
set -euo pipefail

# Unified installer for T-NAS Zero1 RK3568 setup:
# - Device tree
# - Boot beep + power-key beep
# - Power LED solid green
# - SATA LED policy (idle green, io blink, error red)
# - Fan control service + Zero1tool web backend
# - Author: chenfm
# - Date: 2026-06-18

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="/home/anna/Zero1_tool_install"
if [[ "$DIR" != "$INSTALL_ROOT" ]]; then
  echo "Please place this folder at ${INSTALL_ROOT} before running the installer."
  echo "Current folder: ${DIR}"
  exit 1
fi
ORIGINAL_ROOT="${DIR}/original_files"
for original_name in beep-boot.service beep-short.sh buzzer-test.sh fan_temp_control.sh fan-control.service install_all.sh power-key.sh power-led-solid.service power-led-solid.sh README_INSTALL.txt rk3568-nanopi-r5s-new.dtb sata-led-enable.service sata-led-enable.sh sata-led-manager.service sata-led-manager.sh triggerhappy-power-key.conf; do
  if [[ ! -f "${ORIGINAL_ROOT}/${original_name}" ]]; then
    echo "Missing original_files/${original_name}; installation stopped."
    exit 1
  fi
done
TS="$(date +%Y%m%d_%H%M%S)"

SRC_DTB="${DIR}/rk3568-nanopi-r5s-new.dtb"
DST_DTB="/boot/dtb/rockchip/rk3568-nanopi-r5s.dtb"

mkdir -p /etc/triggerhappy/triggers.d

install -m 755 "${DIR}/beep-short.sh" /usr/local/sbin/beep-short.sh
install -m 644 "${DIR}/beep-boot.service" /etc/systemd/system/beep-boot.service
install -m 755 "${DIR}/zero1-buzzer-test.sh" /usr/local/sbin/zero1-buzzer-test.sh

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

install -d -m 755 /etc/zero1-tool
if [[ ! -f /etc/zero1-tool/fan.conf ]]; then
  install -m 644 "${DIR}/fan-control.conf" /etc/zero1-tool/fan.conf
fi
if [[ ! -f /etc/zero1-tool/sata-led.conf ]]; then
  install -m 644 "${DIR}/sata-led.conf" /etc/zero1-tool/sata-led.conf
fi
if [[ ! -f /etc/zero1-tool/buzzer.conf ]]; then
  install -m 644 "${DIR}/buzzer.conf" /etc/zero1-tool/buzzer.conf
fi
install -d -m 755 /usr/local/lib/zero1-tool
install -d -m 755 /usr/local/lib/zero1-tool/www/cgi-bin
install -m 644 "${DIR}/web/index.html" /usr/local/lib/zero1-tool/www/index.html
install -m 755 "${DIR}/web/cgi-bin/zero1.cgi" /usr/local/lib/zero1-tool/www/cgi-bin/zero1.cgi
install -m 755 "${DIR}/zero1-tool-httpd.sh" /usr/local/lib/zero1-tool/zero1-tool-httpd.sh
install -m 644 "${DIR}/zero1-tool-httpd.service" /etc/systemd/system/zero1-tool-httpd.service

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
# This UART is not present on the Zero1 device; leaving its getty enabled adds
# a long timeout while systemd waits for /dev/ttyAMA0 during boot.
systemctl disable --now serial-getty@ttyAMA0.service 2>/dev/null || true
# Remove the previous Python prototype service if it was installed earlier.
systemctl disable --now zero1-tool.service 2>/dev/null || true
rm -f /etc/systemd/system/zero1-tool.service
systemctl daemon-reload

systemctl enable --now beep-boot.service
systemctl enable --now power-led-solid.service
systemctl enable --now sata-led-enable.service
systemctl enable --now sata-led-manager.service
systemctl disable --now fan-control.service 2>/dev/null || true
systemctl enable --now fan-control.service
systemctl enable --now zero1-tool-httpd.service

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
