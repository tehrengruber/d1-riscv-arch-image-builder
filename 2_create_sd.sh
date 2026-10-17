#!/usr/bin/env sh

set -e
# set -x

. ./consts.sh

# Dependency list
DEP_LIST_arch="arch-install-scripts qemu-user-static qemu-user-static-binfmt"
DEP_LIST_debian="arch-install-scripts qemu-user-static"

check_root_fs() {
    if [ -f "${ROOT_FS}" ]; then
        return 0
    fi

    # This script runs as root, so a download here lands root-owned. Prefer
    # fetching it unprivileged with build_in_container.sh; this is the fallback.
    echo "downloading ${ROOT_FS}"
    if command -v curl >/dev/null 2>&1; then
        curl -f -L -o "${ROOT_FS}.part" "${ROOT_FS_DL}"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${ROOT_FS}.part" "${ROOT_FS_DL}"
    else
        echo "Error: need curl or wget to fetch ${ROOT_FS_DL}"
        exit 1
    fi
    # only adopt the name once the download finished, so an interrupted
    # transfer is not mistaken for a complete rootfs next time
    mv "${ROOT_FS}.part" "${ROOT_FS}"
}

DEVICE=${1}

if [ "${USE_CHROOT}" != 0 ]; then
    # check_deps for arch-chroot on non RISC-V host
    DEP_LIST="DEP_LIST_$ID"
    eval DEP_LIST=\$$DEP_LIST
    for DEP in $DEP_LIST; do
        check_deps ${DEP}
    done
fi
check_sd_card_is_block_device "${DEVICE}"
check_sd_card_is_safe_target "${DEVICE}"
check_root_fs
for FILE in u-boot-sunxi-with-spl.bin Image.gz Image "firmware/${FIRMWARE_RTW8723D}"; do
    check_required_file "${OUT_DIR}/${FILE}"
done
for DIR in modules; do
    check_required_folder "${OUT_DIR}/${DIR}"
done

# format disk
if [ -z "${CI_BUILD}" ]; then
    echo "Formatting ${DEVICE}, this will REMOVE EVERYTHING on it!"
    printf "Continue? (y/N): "
    read -r confirm && [ "${confirm}" = "y" ] || [ "${confirm}" = "Y" ] || exit 1
fi

${SUDO} wipefs -a "${DEVICE}" >/dev/null
${SUDO} dd if=/dev/zero of="${DEVICE}" bs=1M count=40
${SUDO} parted -s -a optimal -- "${DEVICE}" mklabel gpt
${SUDO} parted -s -a optimal -- "${DEVICE}" mkpart primary fat32 40MiB 1024MiB
${SUDO} parted -s -a optimal -- "${DEVICE}" mkpart primary ext4 1064MiB 100%
${SUDO} partprobe "${DEVICE}"
command -v udevadm >/dev/null 2>&1 && ${SUDO} udevadm settle || true
PART_IDENTITYFIER=$(probe_partition_separator "${DEVICE}")
${SUDO} mkfs.ext2 -F -L boot "${DEVICE}${PART_IDENTITYFIER}1"
${SUDO} mkfs.ext4 -F -L root "${DEVICE}${PART_IDENTITYFIER}2"

# flash boot things
${SUDO} dd if="${OUT_DIR}/u-boot-sunxi-with-spl.bin" of="${DEVICE}" bs=1024 seek=128

# mount it
mkdir -p "${MNT}"
${SUDO} mount "${DEVICE}${PART_IDENTITYFIER}2" "${MNT}"
${SUDO} mkdir -p "${MNT}/boot"
${SUDO} mount "${DEVICE}${PART_IDENTITYFIER}1" "${MNT}/boot"

# extract rootfs
${SUDO} tar -xv --zstd -f "${ROOT_FS}" -C "${MNT}"

# install kernel and modules
# KERNEL_RELEASE=$(make ARCH="${ARCH}" -s kernelversion -C build/linux-build)
KERNEL_RELEASE=$(ls output/modules)
${SUDO} cp "${OUT_DIR}/Image.gz" "${OUT_DIR}/Image" "${MNT}/boot/"

${SUDO} mkdir -p "${MNT}/lib/modules"
${SUDO} cp -a "${OUT_DIR}/modules/${KERNEL_RELEASE}" "${MNT}/lib/modules"
${SUDO} depmod -a -b "${MNT}" "${KERNEL_RELEASE}"

# WiFi firmware for the in-tree rtw88 driver. The driver autoloads off the SDIO
# device described in the device tree, so no modules-load.d entry is needed.
${SUDO} install -D -p -m 644 "${OUT_DIR}/firmware/${FIRMWARE_RTW8723D}" \
    "${MNT}/lib/firmware/${FIRMWARE_RTW8723D}"

# install U-Boot
if [ "${BOOT_METHOD}" = 'script' ]; then
    ${SUDO} cp "${OUT_DIR}/boot.scr" "${MNT}/boot/"
elif [ "${BOOT_METHOD}" = 'extlinux' ]; then
    # cpuidle.off=1: OpenSBI advertises a 'cpu-nonretentive' idle state for the
    # D1, which powers the CPU domain down via the PPU. The D1 is single-core,
    # so a failed resume is an unrecoverable lockup - observed as the board
    # freezing once idle, surviving two SD cards and two OpenSBI versions, and
    # fixed by this flag.
    ${SUDO} mkdir -p "${MNT}/boot/extlinux"
    (
        echo "label default
        linux   /Image
        append  earlycon=sbi console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootwait cma=96M cpuidle.off=1"
    ) >extlinux.conf
    ${SUDO} mv extlinux.conf "${MNT}/boot/extlinux/extlinux.conf"
fi

# fstab
(
    echo '# <device>    <dir>        <type>        <options>            <dump> <pass>
LABEL=boot    /boot        ext2          rw,defaults,noatime  0      1
LABEL=root    /            ext4          rw,defaults,noatime  0      2'
) >fstab
${SUDO} mv fstab "${MNT}/etc/fstab"

# pacman's downloader sandbox needs Landlock. This kernel does not build it
# (CONFIG_SECURITY_LANDLOCK is not in the riscv defconfig), and qemu-user does
# not translate the syscalls either, so pacman fails with "Landlock is not
# supported by the kernel" both on the board and inside an arch-chroot.
# Uncomment whichever spelling this pacman ships: 7.0 has the blanket
# DisableSandbox, 7.1 split it into Filesystem/Syscalls.
${SUDO} sed -i -E 's/^#(DisableSandbox(Filesystem|Syscalls)?)$/\1/' "${MNT}/etc/pacman.conf"
if ! ${SUDO} grep -qE '^DisableSandbox' "${MNT}/etc/pacman.conf"; then
    echo "Warning: no DisableSandbox* option found in /etc/pacman.conf - pacman may"
    echo "         fail with 'Landlock is not supported by the kernel'"
fi

# set hostname
echo "${IMG_HOSTNAME}" >hostname
${SUDO} mv hostname "${MNT}/etc/"

# # updating ...
# ${SUDO} arch-chroot ${MNT} pacman -Syu
# ${SUDO} arch-chroot ${MNT} pacman -S wpa_supplicant
# ${SUDO} arch-chroot ${MNT} pacman -S netctl
# ${SUDO} arch-chroot ${MNT} pacman -S --asdeps dialog

# done
if [ "${USE_CHROOT}" != 0 ]; then
    echo ''
    echo 'Now configure your new Archlinux!'
    echo ''
    echo 'You might want to update and install an editor as well as configure any network'
    echo ' -> https://wiki.archlinux.org/title/installation_guide#Configure_the_system'
    echo ''
    ${SUDO} arch-chroot "${MNT}"
fi

# Everything written above is still in page cache. On a slow card that is
# several minutes of writeback, and the umount below is where it gets paid -
# which looks exactly like a hang. Flush it explicitly, and say so.
echo ''
echo "Flushing ~$(( $(awk '/^Dirty:/{print $2}' /proc/meminfo) / 1024 )) MiB of pending writes to ${DEVICE}."
echo 'On a slow card this takes a few minutes; it is not stuck.'
${SUDO} sync -f "${MNT}/boot" "${MNT}" 2>/dev/null || ${SUDO} sync
${SUDO} umount -R "${MNT}"

echo ''
echo 'Done!'
if [ "${USE_CHROOT}" = 0 ]; then
    echo ''
    echo 'To configure the system before first boot, chroot into it. On Arch:'
    echo '    pacman -S arch-install-scripts qemu-user-static qemu-user-static-binfmt'
    echo '    systemctl restart systemd-binfmt'
    echo "    mount ${DEVICE}${PART_IDENTITYFIER}2 ${MNT}"
    echo "    mount ${DEVICE}${PART_IDENTITYFIER}1 ${MNT}/boot"
    echo "    arch-chroot ${MNT}"
    echo ''
    echo 'qemu-user-static-binfmt is what lets the riscv64 binaries run at all;'
    echo 'without it everything in the chroot fails with "exec format error".'
fi
exit 0
