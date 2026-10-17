#!/usr/bin/env sh
#
# Install a freshly compiled kernel onto an already-flashed SD card, leaving
# everything else on it alone.
#
#   sudo ./3_update_kernel.sh /dev/<device>
#
# Use this after re-running the compile stage when only the kernel changed.
# 2_create_sd.sh would repartition the card and throw away anything you have
# configured on it (installed packages, network credentials, ...).

set -e

. ./consts.sh

DEVICE=${1}

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: needs root (mount/depmod). Try: sudo $0 ${DEVICE}"
    exit 1
fi

check_sd_card_is_block_device "${DEVICE}"
check_sd_card_is_safe_target "${DEVICE}"
for FILE in Image Image.gz "firmware/${FIRMWARE_RTW8723D}"; do
    check_required_file "${OUT_DIR}/${FILE}"
done
check_required_folder "${OUT_DIR}/modules"

KERNEL_RELEASE=$(ls "${OUT_DIR}/modules")
PART_IDENTITYFIER=$(probe_partition_separator "${DEVICE}")

mkdir -p "${MNT}"
${SUDO} mount "${DEVICE}${PART_IDENTITYFIER}2" "${MNT}"
${SUDO} mount "${DEVICE}${PART_IDENTITYFIER}1" "${MNT}/boot"

# never leave the card mounted if something below fails
cleanup() {
    ${SUDO} umount -R "${MNT}" 2>/dev/null || true
}
trap cleanup EXIT

echo "installing kernel ${KERNEL_RELEASE} onto ${DEVICE}"

# keep the previous image around; see the closing note about its limits
if [ -f "${MNT}/boot/Image" ]; then
    ${SUDO} cp -a "${MNT}/boot/Image" "${MNT}/boot/Image.old"
fi
${SUDO} cp "${OUT_DIR}/Image" "${OUT_DIR}/Image.gz" "${MNT}/boot/"

# The release string does not change when only the config changes, so the old
# directory has to be removed rather than copied over - otherwise .ko files
# from the previous config stay behind and depmod keeps indexing them.
${SUDO} rm -rf "${MNT}/lib/modules/${KERNEL_RELEASE}"
${SUDO} mkdir -p "${MNT}/lib/modules"
${SUDO} cp -a "${OUT_DIR}/modules/${KERNEL_RELEASE}" "${MNT}/lib/modules/"
${SUDO} depmod -a -b "${MNT}" "${KERNEL_RELEASE}"

# firmware for the in-tree rtw88 driver
${SUDO} install -D -p -m 644 "${OUT_DIR}/firmware/${FIRMWARE_RTW8723D}" \
    "${MNT}/lib/firmware/${FIRMWARE_RTW8723D}"

# Page cache still holds all of the above; umount is where it gets paid, and on
# a slow card that looks exactly like a hang.
echo ''
echo "Flushing ~$(( $(awk '/^Dirty:/{print $2}' /proc/meminfo) / 1024 )) MiB of pending writes to ${DEVICE}."
echo 'On a slow card this takes a while; it is not stuck.'
${SUDO} sync -f "${MNT}/boot" "${MNT}" 2>/dev/null || ${SUDO} sync

trap - EXIT
${SUDO} umount -R "${MNT}"

echo ''
echo "Done. Kernel ${KERNEL_RELEASE} and its modules are installed."
echo ''
echo 'The previous kernel is kept as /boot/Image.old, but its modules were'
echo "replaced (same release string '${KERNEL_RELEASE}'), so treat it as a last"
echo 'resort rather than a clean rollback.'
exit 0
