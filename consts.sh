#!/usr/bin/sh

if [ -f /etc/os-release ]; then
    . /etc/os-release
fi

# Dependency list
DEP_LIST_arch="riscv64-linux-gnu-gcc swig cpio"
DEP_LIST_debian="gcc-riscv64-linux-gnu bison flex python3-dev libssl-dev"

export CROSS_COMPILE='riscv64-linux-gnu-'
export ARCH='riscv'
PWD="$(pwd)"
NPROC="$(nproc)"
export PWD
export NPROC

# ${PWD} is maintained by the shell itself and gets rewritten by every `cd`, so
# keep a stable handle on the project root for use after we descend into build/.
PROJECT_DIR="$(pwd)"
export PROJECT_DIR

export ROOT_FS='archriscv-2025-06-12.tar.zst'
export ROOT_FS_DL="https://archriscv.felixc.at/images/${ROOT_FS}"

# select 'arch', 'defconfig'
export KERNEL='defconfig'
# export KERNEL='arch'

# Device Tree:
# In the current pinned U-Boot Commit the following device trees are available
# for the D1:
# sun20i-d1-clockworkpi-v3.14
# sun20i-d1-devterm-v3.14
# sun20i-d1-dongshan-nezha-stu
# sun20i-d1-lichee-rv-86-panel-480p
# sun20i-d1-lichee-rv-86-panel-720p
# sun20i-d1-lichee-rv-dock
# sun20i-d1-lichee-rv
# sun20i-d1-mangopi-mq-pro
# sun20i-d1-nezha
export DEVICE_TREE=sun20i-d1-mangopi-mq-pro

# U-Boot defconfig. It picks the board's built-in drivers and its default device
# tree; DEVICE_TREE above still overrides the latter (see U-Boot's dts/Makefile).
# Across the D1 boards the SPL DRAM timings are identical, so this mainly decides
# which peripherals get compiled in - nezha_defconfig for instance pulls in EMAC
# and video, which the MangoPi MQ Pro has no use for. The pinned U-Boot ships:
# dongshan_nezha_stu_defconfig
# lichee_rv_86_panel_defconfig
# lichee_rv_dock_defconfig
# mangopi_mq_pro_defconfig
# nezha_defconfig
export UBOOT_DEFCONFIG=mangopi_mq_pro_defconfig

# hostname written into the image
export IMG_HOSTNAME='mangopi'

# folder to mount rootfs
export MNT="${PWD}/mnt"
# folder to store compiled artifacts
export OUT_DIR="${PWD}/output"

# run as root
export SUDO='sudo'

# use arch-chroot?
export USE_CHROOT=0

# use extlinux ('extlinux') or boot.scr ('script') for loading the kernel?
export BOOT_METHOD='extlinux'

export VERSION_OPENSBI='1.7'
export VERSION_KERNEL='6.18'

export SOURCE_OPENSBI="https://github.com/riscv-software-src/opensbi/releases/download/v${VERSION_OPENSBI}/opensbi-${VERSION_OPENSBI}-rv-bin.tar.xz"
export SOURCE_UBOOT='https://github.com/MartinHerren/u-boot'
export SOURCE_KERNEL="https://github.com/torvalds/linux/archive/refs/tags/v${VERSION_KERNEL}.tar.gz"
# https://github.com/karabek/xradio

# The RTL8723DS is supported in mainline since the rtw88 driver gained SDIO
# support, so the out-of-tree driver is no longer built. rtw88 does need
# firmware from linux-firmware, which the vendor driver carried internally.
export VERSION_FIRMWARE='20260916'
export FIRMWARE_RTW8723D='rtw88/rtw8723d_fw.bin'
export SOURCE_FIRMWARE="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/${FIRMWARE_RTW8723D}?h=${VERSION_FIRMWARE}"

# pinned commits (no notice when things change)
export COMMIT_UBOOT='d35a660d5c26559a4e10e30e2780a566629c13e9' # v2024.01-rc1 + smaeul's d1-wip + a SWIG fix
export TAG_UBOOT='d1-wip-python-fix'
# use this (set to something != 0) to override the check
export IGNORE_COMMITS=0
export DEBUG='n'

# Shared by 2_create_sd.sh and 3_update_kernel.sh.
#
# The flashing path destroys its target, so check_sd_card_is_safe_target below
# refuses the obvious mistakes before the first write rather than part-way
# through. It deliberately uses /sys and /proc/mounts rather than lsblk: if
# lsblk cannot open the device those checks would silently pass, which is worse
# than not having them at all.
check_sd_card_is_block_device() {
    _DEVICE=${1}

    if [ -z "${_DEVICE}" ] || [ ! -b "${_DEVICE}" ]; then
        echo "Error: '${_DEVICE}' is empty or not a block device"
        exit 1
    fi
}

check_sd_card_is_safe_target() {
    _DEVICE=${1}
    _NAME=$(basename "$(readlink -f "${_DEVICE}")")
    _SYS="/sys/class/block/${_NAME}"

    if [ ! -d "${_SYS}" ]; then
        echo "Error: no sysfs entry for '${_DEVICE}' (${_SYS})"
        exit 1
    fi

    # A whole disk, not a partition - writing U-Boot to /dev/sda1 would be wrong
    # in a way that is hard to notice. Partitions have a 'partition' attribute.
    if [ -f "${_SYS}/partition" ]; then
        echo "Error: '${_DEVICE}' is a partition. Pass the whole disk, e.g. /dev/sda"
        exit 1
    fi

    # Removable only, so a typo cannot wipe a system disk. Loop devices report
    # non-removable, hence the override that flash_image_file.sh sets.
    if [ "${ALLOW_NON_REMOVABLE}" != '1' ] &&
        [ "$(cat "${_SYS}/removable" 2>/dev/null)" != '1' ]; then
        echo "Error: '${_DEVICE}' is not a removable device - refusing to format it."
        echo "       size: $(( $(cat "${_SYS}/size" 2>/dev/null || echo 0) / 2048 )) MiB"
        echo "       If you are sure, re-run with ALLOW_NON_REMOVABLE=1"
        exit 1
    fi

    # A mounted partition leaves parted unable to re-read the table, and by then
    # the start of the disk has already been overwritten.
    _MOUNTED=$(awk -v d="${_DEVICE}" '$1 == d || index($1, d) == 1 { print $1" on "$2 }' \
        /proc/mounts)
    if [ -n "${_MOUNTED}" ]; then
        echo "Error: '${_DEVICE}' has mounted partitions:"
        echo "${_MOUNTED}" | sed 's/^/         /'
        echo "       Unmount them first, e.g.: ${SUDO} umount ${_DEVICE}?*"
        exit 1
    fi
}

check_required_file() {
    if [ ! -f "${1}" ]; then
        echo "Missing file: ${1}, did you compile everything first?"
        exit 1
    fi
}

check_required_folder() {
    if [ ! -d "${1}" ]; then
        echo "Missing directory: ${1}, did you compile everything first?"
        exit 1
    fi
}

probe_partition_separator() {
    _DEVICE=${1}

    [ -b "${_DEVICE}p1" ] && echo 'p' || echo ''
}

check_deps() {
    case $ID in
    arch)
        if ! pacman -Qi "${1}" >/dev/null; then
            echo "Please install '${1}'"
            exit 1
        fi
    ;;
    debian)
        if ! dpkg -l "${1}" >/dev/null; then
            echo "Please install '${1}'"
            exit 1
        fi
    ;;
    *)
        echo "This script is running on not supported distro!"
        exit 1
    ;;
    esac
}

if [ -n "${CI_BUILD}" ]; then
    export USE_CHROOT=0
fi
