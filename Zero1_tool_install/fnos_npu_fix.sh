#!/usr/bin/env bash
# ============================================================
# FnOS RK3568 NPU Repair Script (v2)
#
# Enables the NPU nodes disabled in the NanoPi R5S DTB, registers the
# rknpu driver stack for boot, and re-applies the fix after
# future kernel updates. The device is rebooted automatically at the end.
# ============================================================
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: sudo bash $0"
    exit 1
fi

BOOT_DTB="/boot/dtb/rockchip/rk3568-nanopi-r5s.dtb"
MODULES_LOAD_CONF="/etc/modules-load.d/zero1-npu.conf"
NPU_NODE="/npu@fde40000"
NPU_BUS_NODE="/bus-npu"
NPU_MODULES=(
    "rockchip_pvtm"
    "rockchip_sip"
    "rockchip_opp_select"
    "rockchip_system_monitor"
    "rknpu"
)

echo "=============================================="
echo " FnOS RK3568 NPU Repair Script v2"
echo "=============================================="
echo ""

if [[ ! -f "${BOOT_DTB}" ]]; then
    echo "Error: boot DTB not found: ${BOOT_DTB}"
    exit 1
fi
if ! command -v fdtput >/dev/null 2>&1; then
    echo "Error: fdtput not found; cannot enable NPU nodes safely"
    exit 1
fi
if [[ ! -f /usr/lib/librknnrt.so ]] && ! ldconfig -p 2>/dev/null | grep -q 'librknnrt\.so'; then
    echo "Error: RKNN runtime was not found."
    echo "Please install AI 引擎 (RK356X) from the FnOS App Store first."
    exit 1
fi

KERNEL="$(uname -r)"
if [[ -z "${KERNEL}" || ! -d "/lib/modules/${KERNEL}" ]]; then
    echo "Error: current kernel module directory not found"
    exit 1
fi

echo "[1/5] Enabling NPU nodes in the boot DTB..."
cp -a "${BOOT_DTB}" "${BOOT_DTB}.bak_npu_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
fdtput -t s "${BOOT_DTB}" "${NPU_NODE}" status okay
fdtput -t s "${BOOT_DTB}" "${NPU_BUS_NODE}" status okay
echo "  NPU and bus are enabled in the active boot DTB"

echo "[2/5] Refreshing kernel module index..."
if command -v depmod >/dev/null 2>&1; then
    depmod -a "${KERNEL}" >/tmp/zero1-npu-depmod.log 2>&1 || true
    if grep -q '/rknpu\.ko:' "/lib/modules/${KERNEL}/modules.dep" 2>/dev/null; then
        echo "  rknpu module index is ready"
    else
        cat /tmp/zero1-npu-depmod.log 2>/dev/null || true
        echo "  Warning: rknpu module index entry was not generated"
    fi
else
    echo "  Warning: depmod not found; boot autoload will still be configured"
fi

echo "[3/5] Registering NPU driver stack for boot..."
mkdir -p "$(dirname "${MODULES_LOAD_CONF}")"
# Clean entries left by the earlier combined GPU/NPU implementation.
sed -i '/^rknpu$/d' /etc/modules-load.d/zero1-gpu.conf 2>/dev/null || true
sed -i '/^rknpu$/d' /etc/initramfs-tools/modules 2>/dev/null || true
{
    echo "# RK3568 NPU driver stack for T-NAS Zero1"
    printf '%s\n' "${NPU_MODULES[@]}"
} > "${MODULES_LOAD_CONF}"
echo "  Modules: ${NPU_MODULES[*]}"

echo "[4/5] Installing kernel-update NPU hook..."
HOOK="/etc/kernel/postinst.d/13-zero1-npu"
mkdir -p /etc/kernel/postinst.d
cat > "${HOOK}" << 'EOF'
#!/bin/sh
set +e
version="$1"
[ -n "$version" ] || exit 0
if [ -x /sbin/depmod ]; then /sbin/depmod -a "$version" >/dev/null 2>&1; fi
if [ -x /usr/bin/fdtput ] && [ -f /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb ]; then
    fdtput -t s /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb /npu@fde40000 status okay >/dev/null 2>&1
    fdtput -t s /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb /bus-npu status okay >/dev/null 2>&1
fi
exit 0
EOF
chmod +x "${HOOK}"
echo "  Hook installed: ${HOOK}"

echo "[5/5] Verification"
if command -v fdtget >/dev/null 2>&1; then
    echo "  npu@fde40000: $(fdtget "${BOOT_DTB}" "${NPU_NODE}" status)"
    echo "  bus-npu:      $(fdtget "${BOOT_DTB}" "${NPU_BUS_NODE}" status)"
fi
if grep -q '/rknpu\.ko:' "/lib/modules/${KERNEL}/modules.dep" 2>/dev/null; then
    echo "  rknpu module index: present"
else
    echo "  Warning: rknpu module index entry not found"
fi
echo ""
echo "NPU 修复已完成，设备将在 5 秒后自动重启。请先保存正在编辑的文件。"
sync
sleep 5
if command -v reboot >/dev/null 2>&1; then
    reboot
else
    /sbin/shutdown -r now
fi
