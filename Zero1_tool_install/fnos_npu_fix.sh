#!/usr/bin/env bash
# ============================================================
# FnOS RK3568 NPU Repair Script (v5)
#
# Enables the NPU in the NanoPi R5S DTB, supplies the IRQ name expected by the
# rknpu driver, keeps the overlapping RK3568 NPU IOMMU node disabled for the
# vendor 0.9.8 driver, registers the driver stack for boot, and re-applies the
# fix after future kernel updates. It also reserves enough contiguous memory
# for RKNN models. The device is rebooted automatically.
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
NPU_IOMMU_NODE="/iommu@fde4b000"
EXTLINUX_CFG="/boot/extlinux/extlinux.conf"
CMA_SIZE="256M"
NPU_MODULES=(
    "rockchip_pvtm"
    "rockchip_sip"
    "rockchip_opp_select"
    "rockchip_system_monitor"
    "rknpu"
)

echo "=============================================="
echo " FnOS RK3568 NPU Repair Script v5"
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

echo "[1/5] Enabling NPU and IRQ metadata in the boot DTB..."
cp -a "${BOOT_DTB}" "${BOOT_DTB}.bak_npu_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
fdtput -t s "${BOOT_DTB}" "${NPU_NODE}" status okay
fdtput -t s "${BOOT_DTB}" "${NPU_BUS_NODE}" status okay
# The fde4b000 IOMMU registers overlap the NPU resource window on this DTB.
# Enabling it makes rknpu 0.9.8 fail its resource request with -EBUSY, so use
# the driver's supported non-IOMMU mode.
fdtput -t s "${BOOT_DTB}" "${NPU_IOMMU_NODE}" status disabled
fdtput -t s "${BOOT_DTB}" "${NPU_NODE}" interrupt-names npu_irq
echo "  NPU and bus are enabled; overlapping IOMMU remains disabled; npu_irq is present"

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

echo "[3/6] Reserving contiguous memory for RKNN models..."
if [[ -f "${EXTLINUX_CFG}" ]]; then
    # Non-IOMMU rknpu allocates large physically contiguous buffers. Add CMA
    # to every extlinux entry unless an explicit cma= value already exists.
    sed -i -E '/^[[:space:]]*APPEND[[:space:]]/ { /(^|[[:space:]])cma=/! s/[[:space:]]*$/ cma='"${CMA_SIZE}"'/; }' "${EXTLINUX_CFG}"
    echo "  Added cma=${CMA_SIZE} to ${EXTLINUX_CFG}"
else
    echo "  Warning: ${EXTLINUX_CFG} not found; add cma=${CMA_SIZE} to the active boot arguments"
fi

echo "[4/6] Registering NPU driver stack for boot..."
mkdir -p "$(dirname "${MODULES_LOAD_CONF}")"
# Clean entries left by the earlier combined GPU/NPU implementation.
sed -i '/^rknpu$/d' /etc/modules-load.d/zero1-gpu.conf 2>/dev/null || true
sed -i '/^rknpu$/d' /etc/initramfs-tools/modules 2>/dev/null || true
{
    echo "# RK3568 NPU driver stack for T-NAS Zero1"
    printf '%s\n' "${NPU_MODULES[@]}"
} > "${MODULES_LOAD_CONF}"
echo "  Modules: ${NPU_MODULES[*]}"

echo "[5/6] Installing kernel-update NPU hook..."
HOOK="/etc/kernel/postinst.d/13-zero1-npu"
mkdir -p /etc/kernel/postinst.d
cat > "${HOOK}" << 'EOF'
#!/bin/sh
set +e
version="$1"
[ -n "$version" ] || exit 0
if [ -x /sbin/depmod ]; then /sbin/depmod -a "$version" >/dev/null 2>&1; fi
if [ -f /boot/extlinux/extlinux.conf ]; then
    sed -i -E '/^[[:space:]]*APPEND[[:space:]]/ { /(^|[[:space:]])cma=/! s/[[:space:]]*$/ cma=256M/; }' /boot/extlinux/extlinux.conf
fi
if [ -x /usr/bin/fdtput ] && [ -f /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb ]; then
    fdtput -t s /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb /npu@fde40000 status okay >/dev/null 2>&1
    fdtput -t s /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb /bus-npu status okay >/dev/null 2>&1
    fdtput -t s /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb /iommu@fde4b000 status disabled >/dev/null 2>&1
    fdtput -t s /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb /npu@fde40000 interrupt-names npu_irq >/dev/null 2>&1
fi
exit 0
EOF
chmod +x "${HOOK}"
echo "  Hook installed: ${HOOK}"

echo "[6/6] Verification"
if command -v fdtget >/dev/null 2>&1; then
    echo "  npu@fde40000: $(fdtget "${BOOT_DTB}" "${NPU_NODE}" status)"
    echo "  bus-npu:      $(fdtget "${BOOT_DTB}" "${NPU_BUS_NODE}" status)"
    echo "  iommu@fde4b000: $(fdtget "${BOOT_DTB}" "${NPU_IOMMU_NODE}" status) (kept disabled for rknpu 0.9.8)"
    echo "  interrupt-names: $(fdtget "${BOOT_DTB}" "${NPU_NODE}" interrupt-names)"
fi
if [[ -f "${EXTLINUX_CFG}" ]]; then
    echo "  CMA boot parameter: $(grep -m1 -o 'cma=[^[:space:]]*' "${EXTLINUX_CFG}" || echo missing)"
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
