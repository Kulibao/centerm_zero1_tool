#!/usr/bin/env bash
set -euo pipefail

# Restore the complete original install package and remove only Zero1tool additions.
if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="/home/anna/Zero1_tool_install"
ORIGINAL_ROOT="${DIR}/original_files"
if [[ "$DIR" != "$INSTALL_ROOT" ]]; then
  echo "Please run this script from ${INSTALL_ROOT}."
  exit 1
fi
if [[ ! -d "$ORIGINAL_ROOT" ]]; then
  echo "Original snapshot not found: ${ORIGINAL_ROOT}"
  exit 1
fi

systemctl disable --now zero1-tool-httpd.service 2>/dev/null || true
systemctl disable --now fan-control.service 2>/dev/null || true

# Remove only the post-install hooks created by fnos_kernel_fix.sh. Kernel
# files, initramfs images, and module configuration are intentionally kept.
echo "Cleaning kernel-fix hooks..."
for hook in \
  /etc/kernel/postinst.d/10-zero1-gpu \
  /etc/kernel/postinst.d/11-restore-dtb \
  /etc/kernel/postinst.d/12-update-symlinks; do
  if [[ -f "$hook" ]]; then
    rm -f "$hook"
    echo "Removed: $hook"
  fi
done

restore() {
  local src="$1" dst="$2" mode="$3"
  if [[ -f "${ORIGINAL_ROOT}/${src}" ]]; then
    install -m "$mode" "${ORIGINAL_ROOT}/${src}" "$dst"
    echo "Restored: ${dst}"
  else
    echo "WARNING: original file missing, skipped: ${src}"
  fi
}

restore beep-short.sh /usr/local/sbin/beep-short.sh 755
restore beep-boot.service /etc/systemd/system/beep-boot.service 644
rm -f /usr/local/sbin/zero1-buzzer-test.sh
restore power-led-solid.sh /usr/local/sbin/power-led-solid.sh 755
restore power-led-solid.service /etc/systemd/system/power-led-solid.service 644
restore power-key.sh /usr/bin/power-key.sh 755
restore triggerhappy-power-key.conf /etc/triggerhappy/triggers.d/power-key.conf 644
restore buzzer-test.sh /usr/bin/buzzer-test.sh 755
restore sata-led-enable.sh /usr/local/sbin/sata-led-enable.sh 755
restore sata-led-enable.service /etc/systemd/system/sata-led-enable.service 644
restore sata-led-manager.sh /usr/local/sbin/sata-led-manager.sh 755
restore sata-led-manager.service /etc/systemd/system/sata-led-manager.service 644
restore fan_temp_control.sh /usr/local/bin/fan_temp_control.sh 755
restore fan-control.service /etc/systemd/system/fan-control.service 644

if [[ -f "${ORIGINAL_ROOT}/rk3568-nanopi-r5s-new.dtb" && -d /boot/dtb/rockchip ]]; then
  install -m 644 "${ORIGINAL_ROOT}/rk3568-nanopi-r5s-new.dtb" /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb
  echo "Restored: /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb"
fi

rm -f /etc/systemd/system/zero1-tool.service /etc/systemd/system/zero1-tool-httpd.service
rm -rf /usr/local/lib/zero1-tool /etc/zero1-tool /run/zero1-tool
systemctl daemon-reload
systemctl enable --now beep-boot.service 2>/dev/null || true
systemctl enable --now power-led-solid.service 2>/dev/null || true
systemctl enable --now sata-led-enable.service 2>/dev/null || true
systemctl enable --now sata-led-manager.service 2>/dev/null || true
# Restore the original serial login service when Zero1tool is removed.
systemctl enable --now serial-getty@ttyAMA0.service 2>/dev/null || true
systemctl disable --now fan-control.service 2>/dev/null || true
systemctl enable --now fan-control.service 2>/dev/null || true
if systemctl list-unit-files triggerhappy.service &>/dev/null; then systemctl restart triggerhappy.service || true; fi

echo
echo "Zero1tool removed; all files from original_files were restored."
read -r -p "Reboot now? [Y/N]: " reboot_answer
if [[ "${reboot_answer}" =~ ^[Yy]$ ]]; then
  reboot
else
  echo "Skip reboot."
fi
