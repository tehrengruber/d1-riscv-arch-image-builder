#!/usr/bin/env sh
#
# Writes the compiled artifacts into a loop-mounted image file instead of a
# real SD card. This is the privileged half of the process - run it with root.
#
# Compile first with ./build_in_container.sh (unprivileged), then:
#   sudo ./flash_image_file.sh [image-file] [size-in-MiB]
#
# Afterwards put it on a card with:
#   sudo dd if=<image-file> of=/dev/<device> bs=4M status=progress conv=fsync

set -e

IMG="${1:-archlinux_riscv_mangopi.img}"
SIZE_MIB="${2:-3072}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: needs root (losetup/mount/mkfs). Try: sudo $0 $*"
    exit 1
fi

for TOOL in losetup parted partprobe mkfs.ext2 mkfs.ext4; do
    command -v "${TOOL}" >/dev/null 2>&1 || {
        echo "Error: missing '${TOOL}'. On Arch: pacman -S parted e2fsprogs util-linux"
        exit 1
    }
done

if [ -e "${IMG}" ]; then
    echo "Error: '${IMG}' already exists - remove it or pass another name."
    exit 1
fi

# Sparse file, so it only occupies what is actually written.
truncate -s "${SIZE_MIB}M" "${IMG}"

LOOP="$(losetup -f -P --show "${IMG}")"
echo "Using ${LOOP} for ${IMG} (${SIZE_MIB} MiB)"

cleanup() {
    # 2_create_sd.sh unmounts ${MNT} itself, but make sure we never leak the
    # loop device if it fails halfway through.
    losetup -d "${LOOP}" 2>/dev/null || true
}
trap cleanup EXIT

# CI_BUILD skips the interactive "this erases everything" prompt - there is
# nothing to lose on a freshly created image file.
ALLOW_NON_REMOVABLE=1 CI_BUILD=1 ./2_create_sd.sh "${LOOP}"

sync
echo ''
echo "Done: ${IMG}"
echo "Write it to a card with:"
echo "    sudo dd if=${IMG} of=/dev/<device> bs=4M status=progress conv=fsync"
