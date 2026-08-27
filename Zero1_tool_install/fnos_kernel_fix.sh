#!/usr/bin/env bash
# ============================================================
# FnOS Kernel Upgrade Fix Script (v6)
# Device: NanoPi R5S (RK3568) + FnOS
#
# Modes:
#   1) Fix only (default):
#       修复已安装内核的 initramfs/symlinks/boot 配置
#   2) Upgrade + Fix (--upgrade / -u):
#       先 apt 升级内核包，再自动修复
#       免去手动查版本号的麻烦
# ============================================================
set -euo pipefail

UPGRADE_FIRST=false

# ----- Parse arguments -----
for arg in "$@"; do
    case "$arg" in
        --upgrade|-u)
            UPGRADE_FIRST=true
            ;;
        --help|-h)
            echo "Usage: sudo bash $0 [OPTIONS] [kernel_version]"
            echo ""
            echo "Options:"
            echo "  --upgrade, -u    先 apt upgrade 升级内核，再修复"
            echo "  --help, -h       显示此帮助"
            echo ""
            echo "Examples:"
            echo "  sudo bash $0                    修复当前最新已安装的内核"
            echo "  sudo bash $0 -u                 先升级内核，再修复（日常推荐）"
            echo "  sudo bash $0 6.18.18.c790-trim  指定内核版本修复"
            echo "  sudo bash $0 --upgrade 6.18.18.c821-trim  先升级确保包已装，再修复指定版本"
            exit 0
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: sudo bash $0 [--upgrade] [kernel_version]"
    exit 1
fi

CUSTOM_DTB="/home/anna/Zero1_tool_install/rk3568-nanopi-r5s-new.dtb"
BOOT_DTB="/boot/dtb/rockchip/rk3568-nanopi-r5s.dtb"
GRUB_CFG="/boot/grub/grub.cfg"
EXTLINUX_CFG="/boot/extlinux/extlinux.conf"
ROOT_UUID="40978ebd-8a74-4117-ac24-563ec0d7d866"
COMPRESS_CONF="/etc/initramfs-tools/initramfs.conf"
INITRAMFS_MODULES="/etc/initramfs-tools/modules"
MODULES_LOAD_CONF="/etc/modules-load.d/zero1-gpu.conf"
GPU_MODULE="rkgpu_bifrost_jm"
# The vendor GPU driver depends on these RK3568 power/voltage helpers.  Keep
# them explicit so initramfs and systemd can load the stack even when a newly
# installed kernel has an incomplete modules.dep index.
GPU_MODULES=(
    "rockchip_pvtm"
    "rockchip_sip"
    "rockchip_opp_select"
    "rockchip_system_monitor"
    "rkgpu_bifrost_jm"
)

# ==============================================
# 阶段 0：升级内核（可选）
# ==============================================
if [[ "$UPGRADE_FIRST" == "true" ]]; then
    echo "=============================================="
    echo " [Phase 0] Upgrading kernel packages..."
    echo "=============================================="
    echo ""
    echo "  Running: apt update..."
    apt update 2>&1 | sed 's/^/  /'
    echo ""
    echo "  Running: apt install linux-image-arm64..."
    apt install -y linux-image-arm64 2>&1 | sed 's/^/  /'
    echo ""
    echo "  Kernel upgrade done. Proceeding to fix..."
    echo ""
fi

# ==============================================
# 阶段 1：检测内核
# ==============================================
echo "=============================================="
echo " FnOS Kernel Upgrade Fix Script v6"
echo "=============================================="

ALL_KERNELS=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V)
LATEST_KERNEL=$(echo "$ALL_KERNELS" | tail -1)
OLDEST_KERNEL=$(echo "$ALL_KERNELS" | head -1)

# Determine target kernel: first positional arg, otherwise latest
NEW_KERNEL=""
for arg in "$@"; do
    case "$arg" in
        --upgrade|-u|--help|-h)
            continue
            ;;
        *)
            NEW_KERNEL="$arg"
            break
            ;;
    esac
done
if [[ -z "$NEW_KERNEL" ]]; then
    NEW_KERNEL="$LATEST_KERNEL"
fi

OLD_KERNEL=""
for k in $ALL_KERNELS; do
    if [[ "$k" != "$NEW_KERNEL" ]]; then
        OLD_KERNEL="$k"
    fi
done

if [[ -z "$OLD_KERNEL" ]]; then
    OLD_KERNEL="$OLDEST_KERNEL"
fi

echo " Detected kernels:"
for k in $ALL_KERNELS; do
    if [[ "$k" == "$NEW_KERNEL" ]]; then
        echo "   * $k  (TARGET - new)"
    else
        echo "     $k  (fallback)"
    fi
done
echo ""
echo " Default boot: ${NEW_KERNEL}"
echo " Fallback:     ${OLD_KERNEL}"
echo ""

# ----- Step 1: Backup GRUB -----
echo "[1/8] Backing up GRUB config..."
if [[ -f "${GRUB_CFG}" ]]; then
    cp -a "${GRUB_CFG}" "${GRUB_CFG}.bak"
    echo "  Done: ${GRUB_CFG}.bak"
else
    echo "  Warning: GRUB config not found, skip"
fi
echo ""

# ----- Step 2: Install custom DTB -----
echo "[2/8] Installing custom DTB..."
if [[ -f "${CUSTOM_DTB}" ]]; then
    cp "${CUSTOM_DTB}" "${BOOT_DTB}"
    echo "  Done: custom DTB installed"
else
    echo "  Error: custom DTB not found: ${CUSTOM_DTB}"
    echo "  Please place the custom DTB at: ${CUSTOM_DTB}"
    exit 1
fi
echo ""

# ----- Step 3: Set COMPRESSLEVEL=1 for fast initramfs -----
echo "[3/8] Setting initramfs compression to zstd level 1..."
if grep -q "^COMPRESSLEVEL=" "${COMPRESS_CONF}" 2>/dev/null; then
    sed -i 's/^COMPRESSLEVEL=.*/COMPRESSLEVEL=1/' "${COMPRESS_CONF}"
    echo "  Updated existing COMPRESSLEVEL setting to 1"
else
    if grep -q "^COMPRESS=zstd" "${COMPRESS_CONF}" 2>/dev/null; then
        sed -i '/^COMPRESS=zstd/a COMPRESSLEVEL=1' "${COMPRESS_CONF}"
    else
        echo "COMPRESSLEVEL=1" >> "${COMPRESS_CONF}"
    fi
    echo "  Added COMPRESSLEVEL=1"
fi
echo "  Future initramfs generation will be 10-20x faster"
echo ""

# ----- Step 3A: Register RK3568 GPU driver -----
echo "[3A/8] Registering RK3568 GPU driver..."
mkdir -p "$(dirname "${INITRAMFS_MODULES}")" "$(dirname "${MODULES_LOAD_CONF}")"

# New kernel packages may leave vendor modules on disk without refreshing the
# dependency index. Use the absolute path because /sbin is not always in PATH.
DEPMOD_BIN=""
if [[ -x /sbin/depmod ]]; then
    DEPMOD_BIN="/sbin/depmod"
elif command -v depmod &>/dev/null; then
    DEPMOD_BIN="$(command -v depmod)"
fi
refresh_depmod() {
    local kernel="$1" ok=false
    if [[ -n "${DEPMOD_BIN}" ]]; then
        if "${DEPMOD_BIN}" -a "${kernel}" >/tmp/zero1-depmod.log 2>&1; then
            ok=true
        fi
        # Some FnOS builds expose kmod through /sbin/depmod and return success
        # even when they print recoverable warnings. Verify the actual index.
        if ! grep -q "rkgpu_bifrost_jm" "/lib/modules/${kernel}/modules.dep" 2>/dev/null; then
            if [[ -x /bin/kmod ]] && /bin/kmod depmod -a "${kernel}" >/tmp/zero1-depmod-kmod.log 2>&1; then
                ok=true
            fi
        fi
    fi
    if grep -q "rkgpu_bifrost_jm" "/lib/modules/${kernel}/modules.dep" 2>/dev/null; then
        echo "  Module dependency index ready for ${kernel}"
        return 0
    fi
    if [[ "${ok}" == "true" ]]; then
        echo "  Warning: depmod reported success but GPU entry is still missing for ${kernel}"
    else
        echo "  Warning: unable to rebuild modules.dep for ${kernel}"
    fi
    return 1
}

if ! refresh_depmod "${NEW_KERNEL}"; then
    echo "  GPU module files will still be added explicitly to initramfs/autoload"
fi

# Write a deterministic list rather than appending duplicates from repeated
# runs. modprobe resolves any remaining dependencies using the refreshed index.
{
    echo "# RK3568 Mali GPU driver stack for T-NAS Zero1"
    printf '%s\n' "${GPU_MODULES[@]}"
} > "${INITRAMFS_MODULES}.zero1.tmp"
while IFS= read -r line; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    grep -qxF "${line}" "${INITRAMFS_MODULES}" 2>/dev/null || echo "${line}" >> "${INITRAMFS_MODULES}"
done < "${INITRAMFS_MODULES}.zero1.tmp"
rm -f "${INITRAMFS_MODULES}.zero1.tmp"

{
    echo "# RK3568 Mali GPU driver for T-NAS Zero1"
    printf '%s\n' "${GPU_MODULES[@]}"
} > "${MODULES_LOAD_CONF}"
echo "  Initramfs and boot autoload configured: ${GPU_MODULES[*]}"

# Re-run depmod after package hooks and load the current kernel immediately
# when possible. This makes the fix effective without requiring a second run.
HOOK_GPU="/etc/kernel/postinst.d/10-zero1-gpu"
cat > "${HOOK_GPU}" << 'EOF'
#!/bin/sh
set +e
version="$1"
[ -n "$version" ] || exit 0
if [ -x /sbin/depmod ]; then /sbin/depmod -a "$version" >/dev/null 2>&1; fi
if [ -x /bin/kmod ] && ! grep -q rkgpu_bifrost_jm "/lib/modules/$version/modules.dep" 2>/dev/null; then
    /bin/kmod depmod -a "$version" >/dev/null 2>&1
fi
exit 0
EOF
chmod +x "${HOOK_GPU}"
echo "  Kernel post-install GPU hook: ${HOOK_GPU}"

if [[ "${NEW_KERNEL}" == "$(uname -r)" ]]; then
    if command -v modprobe >/dev/null 2>&1; then
        if modprobe "${GPU_MODULE}" >/dev/null 2>&1; then
            echo "  GPU driver loaded in the running kernel"
        else
            echo "  Warning: GPU driver could not be loaded immediately; reboot will retry"
        fi
    fi
fi
echo ""

# ----- Step 4: Create extlinux.conf -----
echo "[4/8] Creating extlinux boot menu..."
ROOTFLAGS="compress=zstd:1"
CMDLINE="root=UUID=${ROOT_UUID} rootflags=${ROOTFLAGS} rw rootwait rootfstype=btrfs console=ttyS2,1500000 console=tty1 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128"

cat > "${EXTLINUX_CFG}" << EOF
LABEL Armbian_${NEW_KERNEL}
  LINUX /vmlinuz-${NEW_KERNEL}
  initrd /uInitrd-${NEW_KERNEL}
  FDT /dtb/rockchip/rk3568-nanopi-r5s.dtb
  APPEND ${CMDLINE}

LABEL Armbian_${OLD_KERNEL}
  LINUX /vmlinuz-${OLD_KERNEL}
  initrd /uInitrd-${OLD_KERNEL}
  FDT /dtb/rockchip/rk3568-nanopi-r5s.dtb
  APPEND ${CMDLINE}
EOF
echo "  Done: ${EXTLINUX_CFG}"
echo "  Default boot: ${NEW_KERNEL}"
echo "  Fallback:     Armbian_${OLD_KERNEL}"
echo ""

# ----- Step 5: Generate initramfs (now fast with COMPRESSLEVEL=1) -----
echo "[5/8] Generating initramfs..."
if [[ -f "/boot/initrd.img-${NEW_KERNEL}" ]]; then
    update-initramfs -u -k "${NEW_KERNEL}" 2>&1 | sed 's/^/  /'
else
    update-initramfs -c -k "${NEW_KERNEL}" 2>&1 | sed 's/^/  /'
fi
if [[ ! -f "/boot/initrd.img-${NEW_KERNEL}" ]]; then
    echo "  Error: initramfs generation failed!"
    exit 1
fi
SIZE=$(stat -c%s "/boot/initrd.img-${NEW_KERNEL}" 2>/dev/null || echo "?")
echo "  Done: /boot/initrd.img-${NEW_KERNEL} (${SIZE} bytes)"
echo ""

# ----- Step 6: Generate uInitrd (only if fnOS hook didn't already do it) -----
echo "[6/8] Checking uInitrd..."
if [[ ! -f "/boot/uInitrd-${NEW_KERNEL}" ]]; then
    echo "  uInitrd not found, generating..."
    if command -v mkimage &>/dev/null; then
        mkimage -A arm64 -O linux -T ramdisk -C none \
            -n "uInitrd-${NEW_KERNEL}" \
            -d "/boot/initrd.img-${NEW_KERNEL}" \
            "/boot/uInitrd-${NEW_KERNEL}" 2>&1 | sed 's/^/  /'
        echo "  Done: /boot/uInitrd-${NEW_KERNEL}"
    else
        echo "  Error: mkimage not found (need u-boot-tools package)"
        exit 1
    fi
else
    echo "  Already exists: /boot/uInitrd-${NEW_KERNEL}"
fi
echo ""

# ----- Step 7: Update symlinks -----
echo "[7/8] Updating symlinks..."
ln -sf "vmlinuz-${NEW_KERNEL}" /boot/Image
ln -sf "uInitrd-${NEW_KERNEL}" /boot/uInitrd
echo "  /boot/Image    -> vmlinuz-${NEW_KERNEL}"
echo "  /boot/uInitrd  -> uInitrd-${NEW_KERNEL}"
echo ""

# ----- Step 8: Update GRUB -----
echo "[8/8] Updating GRUB config..."
if command -v update-grub &>/dev/null; then
    update-grub 2>&1 | sed 's/^/  /'
    echo "  Done: GRUB config updated"
else
    echo "  update-grub not available, skip"
fi
echo ""

# ----- Extra A: Create DTB auto-restore hook (11-restore-dtb) -----
echo "[Extra A] Creating DTB auto-restore hook..."
HOOK_DTB="/etc/kernel/postinst.d/11-restore-dtb"
if [[ ! -f "${HOOK_DTB}" ]] || ! grep -q "/home/anna/Zero1_tool_install/rk3568-nanopi-r5s-new.dtb" "${HOOK_DTB}" 2>/dev/null; then
    cat > "${HOOK_DTB}" << 'EOF'
#!/bin/sh
set -e
version="$1"
if [ -z "$version" ]; then exit 2; fi
if [ -f "/home/anna/Zero1_tool_install/rk3568-nanopi-r5s-new.dtb" ]; then
    echo "restore-dtb: Restoring custom DTB for NanoPi R5S..."
    cp /home/anna/Zero1_tool_install/rk3568-nanopi-r5s-new.dtb /boot/dtb/rockchip/rk3568-nanopi-r5s.dtb
    sync
fi
exit 0
EOF
    chmod +x "${HOOK_DTB}"
    echo "  Done: ${HOOK_DTB}"
    echo "  Custom DTB will auto-restore after kernel updates"
else
    echo "  Hook already exists, skip"
fi
echo ""

# ----- Extra B: Create Symlink auto-update hook (12-update-symlinks) -----
echo "[Extra B] Creating symlink auto-update hook..."
HOOK_SYMLINK="/etc/kernel/postinst.d/12-update-symlinks"
if [[ ! -f "${HOOK_SYMLINK}" ]]; then
    cat > "${HOOK_SYMLINK}" << 'EOF'
#!/bin/sh
set -e
version="$1"
if [ -z "$version" ]; then exit 2; fi
echo "update-symlinks: Updating /boot/Image -> vmlinuz-${version}"
ln -sf "vmlinuz-${version}" /boot/Image
echo "update-symlinks: Updating /boot/uInitrd -> uInitrd-${version}"
ln -sf "uInitrd-${version}" /boot/uInitrd
sync
exit 0
EOF
    chmod +x "${HOOK_SYMLINK}"
    echo "  Done: ${HOOK_SYMLINK}"
    echo "  Symlinks will auto-update on next kernel install"
else
    echo "  Hook already exists, skip"
fi
echo ""

# ----- Verification -----
echo "=============================================="
echo " Verification"
echo "=============================================="
echo ""
echo "Compression config:"
grep -E "^COMPRESS" "${COMPRESS_CONF}" 2>&1 | sed 's/^/  /'
echo ""
echo "Kernel files:"
ls -la /boot/vmlinuz-${NEW_KERNEL} /boot/initrd.img-${NEW_KERNEL} /boot/uInitrd-${NEW_KERNEL} 2>&1 | sed 's/^/  /'
echo ""
echo "Symlinks:"
ls -la /boot/Image /boot/uInitrd 2>&1 | sed 's/^/  /'
echo ""
echo "extlinux menu:"
cat "${EXTLINUX_CFG}" 2>&1 | sed 's/^/  /'
echo ""
echo "DTB file:"
md5sum "${BOOT_DTB}" 2>&1 | sed 's/^/  /'
echo ""
echo "Post-install hooks:"
ls -la /etc/kernel/postinst.d/ 2>&1 | sed 's/^/  /'
echo ""
echo "GPU module configuration:"
echo "  Driver module: ${GPU_MODULE}"
echo "  Driver stack: ${GPU_MODULES[*]}"
echo "  Initramfs list: ${INITRAMFS_MODULES}"
echo "  Autoload list:  ${MODULES_LOAD_CONF}"
grep -Hn "${GPU_MODULE}" "${INITRAMFS_MODULES}" "${MODULES_LOAD_CONF}" 2>&1 | sed 's/^/  /' || true
if grep -q "${GPU_MODULE}" "/lib/modules/${NEW_KERNEL}/modules.dep" 2>/dev/null; then
    echo "  modules.dep: GPU entry present for ${NEW_KERNEL}"
else
    echo "  modules.dep: WARNING GPU entry missing for ${NEW_KERNEL}"
fi
if command -v lsinitramfs >/dev/null 2>&1 && [[ -f "/boot/initrd.img-${NEW_KERNEL}" ]]; then
    if lsinitramfs "/boot/initrd.img-${NEW_KERNEL}" 2>/dev/null | grep -q "${GPU_MODULE}\.ko"; then
        echo "  initramfs: GPU module present"
    else
        echo "  initramfs: WARNING GPU module missing"
    fi
fi

echo ""
echo "=============================================="
echo " All steps completed!"
echo "=============================================="
echo ""
echo "Reboot to apply the new kernel:"
echo "  sudo reboot"
echo ""
echo "After reboot, verify with:"
echo "  uname -a"
echo "  df -h | grep vol"
echo "  cat /proc/mdstat"
echo ""
echo "To rollback to ${OLD_KERNEL}:"
echo "  sudo ln -sf vmlinuz-${OLD_KERNEL} /boot/Image"
echo "  sudo ln -sf uInitrd-${OLD_KERNEL} /boot/uInitrd"
echo "  sudo reboot"
