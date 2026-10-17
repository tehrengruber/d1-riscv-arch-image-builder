#!/usr/bin/env sh

set -e
# set -x

. ./consts.sh

clean_dir() {
    _DIR=${1}

    # kind of dangerous ...
    [ "${_DIR}" = '/' ] && exit 1
    rm -rf "${_DIR}" || true
}

pin_commit() {
    _COMMIT=${1}
    _COMMIT_IS=$(git rev-parse HEAD)
    [ "${IGNORE_COMMITS}" != '0' ] || [ "${_COMMIT}" = "${_COMMIT_IS}" ] || (
        echo "Commit mismatch"
        exit 1
    )
}

apply_patches() {
    # Apply our local fixes to a freshly cloned tree. The upstream D1 forks are
    # from 2022/2023 and do not build with current toolchains unmodified.
    _PATCH_DIR="${PROJECT_DIR}/patches/${1}"

    if [ ! -d "${_PATCH_DIR}" ]; then
        echo "no patches for '${1}'"
        return 0
    fi
    for _PATCH in "${_PATCH_DIR}"/*.patch; do
        [ -f "${_PATCH}" ] || continue
        echo "applying $(basename "${_PATCH}")"
        git apply "${_PATCH}"
    done
}

patch_config() {
    # must be called when inside the `linux` dir
    key="$1"
    val="$2"

    if [ -z "$key" ] || [ -z "$val" ]; then
        exit 1
    fi

    case "$val" in
    'y')
        _OP='--enable'
        ;;
    'n')
        _OP='--disable'
        ;;
    'm')
        _OP='--module'
        ;;
    *)
        echo "Unknown kernel option value '$KERNEL'"
        exit 1
        ;;
    esac

    if [ -z "$_OP" ]; then
        exit 1
    fi

    ./scripts/config --file "../${DIR}-build/.config" "$_OP" "$key"
}

DEP_LIST="DEP_LIST_$ID"
eval DEP_LIST=\$$DEP_LIST
for DEP in $DEP_LIST; do
    check_deps ${DEP}
done

mkdir -p build
mkdir -p "${OUT_DIR}"
cd build

if [ ! -f "${OUT_DIR}/fw_dynamic.bin" ]; then
    # build OpenSBI
    clean_dir "opensbi-${VERSION_OPENSBI}-rv-bin"

    curl -O -L ${SOURCE_OPENSBI}
    tar -xf "opensbi-${VERSION_OPENSBI}-rv-bin.tar.xz"
    rm "opensbi-${VERSION_OPENSBI}-rv-bin.tar.xz"
    cp "opensbi-${VERSION_OPENSBI}-rv-bin/share/opensbi/lp64/generic/firmware/fw_dynamic.bin" "${OUT_DIR}"
fi

if [ ! -f "${OUT_DIR}/u-boot-sunxi-with-spl.bin" ]; then
    # build U-Boot
    DIR='u-boot'
    clean_dir ${DIR}

    git clone --depth 1 "${SOURCE_UBOOT}" -b "${TAG_UBOOT}"
    cd ${DIR}
    pin_commit "${COMMIT_UBOOT}"
    apply_patches 'u-boot'

    make CROSS_COMPILE="${CROSS_COMPILE}" ARCH="${ARCH}" "${UBOOT_DEFCONFIG}"
    make CROSS_COMPILE="${CROSS_COMPILE}" ARCH="${ARCH}" OPENSBI="${OUT_DIR}/fw_dynamic.bin" -j "${NPROC}"
    cd ..
    cp ${DIR}/u-boot-sunxi-with-spl.bin "${OUT_DIR}"
fi

if [ ! -f "${OUT_DIR}/Image" ] || [ ! -f "${OUT_DIR}/Image.gz" ]; then
    # build kernel
    DIR='linux'

    if [ "${KERNEL_CLEAN}" != '1' ] && [ -d "${DIR}" ] && [ -d "${DIR}-build" ]; then
        # Reuse the existing tree. The config is regenerated from defconfig
        # below either way, so this stays reproducible - but make only rebuilds
        # what the config change actually touched. A config-only change costs a
        # couple of minutes instead of a full rebuild plus a 230MB download.
        echo "reusing existing ${DIR} tree (KERNEL_CLEAN=1 forces a fresh one)"
    else
        clean_dir ${DIR}
        clean_dir ${DIR}-build

        # Keep the tarball; re-extracting is far cheaper than re-downloading.
        if [ ! -f "v${VERSION_KERNEL}.tar.gz" ]; then
            curl -O -L ${SOURCE_KERNEL}
        fi
        tar -xf "v${VERSION_KERNEL}.tar.gz"
        mv linux-${VERSION_KERNEL} ${DIR}
    fi

    # staging dir only, nothing is compiled into it
    clean_dir ${DIR}-modules
    cd ${DIR}

    # fix kernel version
    touch .scmversion

    case "$KERNEL" in
    'defconfig')
        # generate default config
        make ARCH="${ARCH}" O=../linux-build defconfig

        # patch necessary options
        # patch_config LOCALVERSION_AUTO n #### not necessary with a release kernel

        # enable WiFi. The onboard RTL8723DS is an SDIO part, supported in
        # mainline by rtw88. RTW88 *depends on* MAC80211 rather than selecting
        # it, so MAC80211 has to be set here or olddefconfig drops the lot.
        patch_config CFG80211 m
        patch_config MAC80211 m
        # iwd opens /dev/rfkill at startup and exits with ENOENT without it.
        # Built in, so it exists before iwd starts rather than depending on
        # cfg80211 having pulled it in first.
        patch_config RFKILL y
        patch_config RTW88 m
        patch_config RTW88_8723DS m

        # There is no LAN, so let there be USB-LAN
        patch_config USB_NET_DRIVERS m
        patch_config USB_CATC m
        patch_config USB_KAWETH m
        patch_config USB_PEGASUS m
        patch_config USB_RTL8150 m
        patch_config USB_RTL8152 m
        patch_config USB_LAN78XX m
        patch_config USB_USBNET m
        patch_config USB_NET_AX8817X m
        patch_config USB_NET_AX88179_178A m
        patch_config USB_NET_CDCETHER m
        patch_config USB_NET_CDC_EEM m
        patch_config USB_NET_CDC_NCM m
        patch_config USB_NET_HUAWEI_CDC_NCM m
        patch_config USB_NET_CDC_MBIM m
        patch_config USB_NET_DM9601 m
        patch_config USB_NET_SR9700 m
        patch_config USB_NET_SR9800 m
        patch_config USB_NET_SMSC75XX m
        patch_config USB_NET_SMSC95XX m
        patch_config USB_NET_GL620A m
        patch_config USB_NET_NET1080 m
        patch_config USB_NET_PLUSB m
        patch_config USB_NET_MCS7830 m
        patch_config USB_NET_RNDIS_HOST m
        patch_config USB_NET_CDC_SUBSET_ENABLE m
        patch_config USB_NET_CDC_SUBSET m
        patch_config USB_ALI_M5632 y
        patch_config USB_AN2720 y
        patch_config USB_BELKIN y
        patch_config USB_ARMLINUX y
        patch_config USB_EPSON2888 y
        patch_config USB_KC2190 y
        patch_config USB_NET_ZAURUS m
        patch_config USB_NET_CX82310_ETH m
        patch_config USB_NET_KALMIA m
        patch_config USB_NET_QMI_WWAN m
        patch_config USB_NET_INT51X1 m
        patch_config USB_IPHETH m
        patch_config USB_SIERRA_NET m
        patch_config USB_VL600 m
        patch_config USB_NET_CH9200 m
        patch_config USB_NET_AQC111 m
        patch_config USB_RTL8153_ECM m

        # enable systemV IPC (needed by fakeroot during makepkg)
        patch_config SYSVIPC y
        patch_config SYSVIPC_SYSCTL y

        # enable swap
        patch_config SWAP y
        patch_config ZSWAP y

        # enable audio. The MQ Pro has no analog jack and mainline has no driver
        # for the D1's internal codec, so a USB DAC is the practical output.
        # Built in rather than modular so it works without module loading.
        patch_config SOUND y
        patch_config SND y
        patch_config SND_USB y
        patch_config SND_USB_AUDIO y

        # enable Cedrus VPU Drivers. Cedrus sits in drivers/staging behind two
        # gates, so without STAGING/STAGING_MEDIA/VIDEO_SUNXI the request for
        # VIDEO_SUNXI_CEDRUS is silently dropped again by olddefconfig.
        # (MEDIA_CONTROLLER_REQUEST_API used to be set here; the symbol is gone
        # from the kernel now that the request API is unconditional.)
        patch_config MEDIA_SUPPORT y
        patch_config MEDIA_CONTROLLER y
        patch_config V4L_MEM2MEM_DRIVERS y
        patch_config STAGING y
        patch_config STAGING_MEDIA y
        patch_config VIDEO_SUNXI y
        patch_config VIDEO_SUNXI_CEDRUS y

        # The riscv defconfig carries PCIe GPU drivers for server and dev boards.
        # The D1 has no PCIe at all, so they can never bind. nouveau and radeon
        # alone are ~450 of the ~3700 objects in the build. The D1's own display
        # engine is DRM_SUN4I + the SUN8I mixer/HDMI bits, which stay enabled.
        patch_config DRM_NOUVEAU n
        patch_config DRM_RADEON n

        # Same story for ACPI: the D1 is described entirely by device tree, so
        # ACPI can never be used, and it drags in PNP, PATA and PCC glue behind
        # it. ~215 objects. Nothing sunxi-related depends on it.
        patch_config ACPI n

        # iwd talks to the kernel crypto API over AF_ALG and refuses to start
        # without these. The riscv defconfig leaves SHA1/MD5/DES and the
        # SKCIPHER userspace API off entirely, and has the rest as modules.
        # Built in rather than modular so nothing depends on autoload order.
        patch_config CRYPTO_USER_API y
        patch_config CRYPTO_USER_API_HASH y
        patch_config CRYPTO_USER_API_SKCIPHER y
        patch_config CRYPTO_HMAC y
        patch_config CRYPTO_SHA1 y
        patch_config CRYPTO_MD5 y
        patch_config CRYPTO_AES y
        patch_config CRYPTO_DES y
        patch_config CRYPTO_CBC y
        patch_config CRYPTO_ECB y
        patch_config KEY_DH_OPERATIONS y

        # enable binfmt_misc
        patch_config BINFMT_MISC y

        # debug options
        if [ $DEBUG = 'y' ]; then
            patch_config DEBUG_INFO y
        fi

        # default anything new
        make ARCH="${ARCH}" O=../linux-build olddefconfig

        ;;

    'arch')
        # generate default config (and directory)
        make ARCH="${ARCH}" O=../linux-build defconfig

        # deploy Arch's confi
        # TODO keep this up to date automatically somehow
        cp ../../6.3.5-arch1.config ../linux-build/.config

        # THIS DOESN'T WORK RIGHT NOW
        # TODO

        # default anything new
        make ARCH="${ARCH}" O=../linux-build olddefconfig

        ;;

    *)
        echo "Unknown kernel option '$KERNEL'"
        exit 1
        ;;
    esac

    # compile it!
    cd ..
    make CROSS_COMPILE="${CROSS_COMPILE}" ARCH="${ARCH}" -j "${NPROC}" -C ${DIR}-build

    KERNEL_RELEASE=$(make ARCH="${ARCH}" -C ${DIR}-build -s kernelversion)
    echo "compiled kernel version '$KERNEL_RELEASE'"

    cp ${DIR}-build/arch/riscv/boot/Image.gz "${OUT_DIR}"
    cp ${DIR}-build/arch/riscv/boot/Image "${OUT_DIR}"

    # prepare modules
    mkdir -p ${DIR}-modules
    make ARCH="${ARCH}" INSTALL_MOD_PATH="../${DIR}-modules" KERNELRELEASE="${KERNEL_RELEASE}" -C ${DIR}-build modules_install
    mv ${DIR}-modules/lib/modules "${OUT_DIR}"
fi

if [ ! -f "${OUT_DIR}/firmware/${FIRMWARE_RTW8723D}" ]; then
    # fetch WiFi firmware for the in-tree rtw88 driver
    mkdir -p "${OUT_DIR}/firmware/$(dirname "${FIRMWARE_RTW8723D}")"
    curl -f -L -o "${OUT_DIR}/firmware/${FIRMWARE_RTW8723D}" "${SOURCE_FIRMWARE}"
fi
