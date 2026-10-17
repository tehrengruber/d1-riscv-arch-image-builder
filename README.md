UNMAINTAINED
============
I don't own any D1 hardware anymore, so this is untested and your mileage may vary.


# Image Builder for Archlinux on an Allwinner D1 / Sipeed Lichee RV
These scripts compile, copy, bake, unpack and flash a [ready](https://wiki.archlinux.org/title/installation_guide#Configure_the_system) to use RISC-V Archlinux.  
*With "ready to use" i mean that it boots, you still need to configure everything!*

Special thanks to **smaeul** for all their work!

Find a **precompiled image** under the [Actions](https://github.com/sehraf/riscv-arch-image-builder/actions) artifacts. The image has _no_ configuration or whatsoever!

Also have a look at the forks that have emerged over time or similar projects like a [make file based approch](https://github.com/hyx0329/riscv-archlinux-d1).

## Starfive Vision 2
There are multiple sources for an Archlinux image:
- https://forum.rvspace.org/t/arch-linux-image-for-visionfive-2/1459
- https://github.com/thefossguy/archlinux-visionfive2

## Components
- mainline OpenSBI
- U-Boot based on https://github.com/smaeul/u-boot.git
- mainline kernel
- WiFi via the mainline `rtw88` driver (`rtw88_8723ds`, SDIO), with firmware from linux-firmware
- RootFS based on https://archriscv.felixc.at (root password is ~~`sifive`~~ `archriscv`)

## How to build on ArchLinux
1. Install requirements: `pacman -Sy riscv64-linux-gnu-gcc swig cpio python3 python-setuptools base-devel bc`
   1. If you want to `chroot` into the RISC-V image, you also need `arch-install-scripts qemu-user-static qemu-user-static-binfmt`
1. Edit `consts.sh` to your needs. For example, you may want to select a [different DTB](https://github.com/sehraf/riscv-arch-image-builder/blob/5c450da98d578617781ae13f9d2b0850a61b21c4/consts.sh#L22) for a different board variant.
1. Run `1_compile.sh` which compiles everything into the `output` folder.
1. Run `2_create_sd.sh /dev/<device>` to flash everything on the SD card.
1. Configure your Archlinux :rocket:

## How to build on Debian
1. Install requirements: `apt install -y gcc-riscv64-linux-gnu bison flex python3-dev libssl-dev swig cpio python3-setuptools build-essential bc`
   1. If you want to `chroot` into the RISC-V image, you also need `arch-install-scripts qemu-user-static`
1. Edit `consts.sh` to your needs. For example, you may want to select a [different DTB](https://github.com/sehraf/riscv-arch-image-builder/blob/5c450da98d578617781ae13f9d2b0850a61b21c4/consts.sh#L22) for a different board variant.
1. Run `1_compile.sh` which compiles everything into the `output` folder.
1. Run `2_create_sd.sh /dev/<device>` to flash everything on the SD card.
1. Configure your Archlinux :rocket:

## How to build in a container (podman, unprivileged)
The compile stage needs no privileges at all, so it can run in a rootless podman
container. Only the flashing stage touches block devices and needs root.

1. One-time host setup (this part does need root):
   `pacman -S podman parted` and make sure you have subuid/subgid ranges, e.g.
   `usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER`
1. Edit `consts.sh` to your needs (board `DEVICE_TREE`, kernel version, ...).
1. Run `./build_in_container.sh` **as your normal user**. It builds the toolchain
   image from `Containerfile`, runs `1_compile.sh` inside it and downloads the
   rootfs tarball.
   - Rootless podman maps the container's root to your own user, so `build/`,
     `output/` and the rootfs tarball end up owned by you, not by root.
   - Set `CONTAINER_ENGINE=docker` to use docker instead, but note that docker's
     daemon runs as root, so artifacts will be root-owned.
   - Pass a command to get a shell in the build environment:
     `./build_in_container.sh -c 'bash'`
1. Flash, which is the only step that needs root:
   - to an SD card: `sudo ./2_create_sd.sh /dev/<device>`
   - to an image file: `sudo ./flash_image_file.sh archlinux_riscv_mangopi.img 3072`

`USE_CHROOT=0` is the default here, so a plain flash needs only `parted` and
`e2fsprogs` as root. See *Entering the RISC-V rootfs* below for configuring the
image afterwards.

## Entering the RISC-V rootfs
To configure the image before first boot, chroot into it with `arch-chroot` and
qemu-user-static:

```sh
pacman -S arch-install-scripts qemu-user-static qemu-user-static-binfmt
systemctl restart systemd-binfmt
sudo mount /dev/<device>2 ./mnt && sudo mount /dev/<device>1 ./mnt/boot
sudo arch-chroot ./mnt
```

`qemu-user-static-binfmt` registers the riscv64 `binfmt_misc` handler, which is
what makes the foreign binaries runnable; without it everything in the chroot
fails with "exec format error". `2_create_sd.sh` prints these commands with your
actual device paths filled in when it finishes.

Setting `USE_CHROOT=1` in `consts.sh` makes `2_create_sd.sh` do the chroot for you
right after flashing instead.

*Note: `Dockerfile` and `build_img.sh` are the older, CI-specific variant used by
the GitHub Actions workflow; they are kept as-is.*

## Updating only the kernel
After changing the kernel config and re-running the compile stage, install the
new kernel onto an already-flashed card without touching anything else on it:

```sh
sudo ./3_update_kernel.sh /dev/<device>
```

It replaces `/boot/Image`, `/boot/Image.gz` and `/lib/modules/<release>`, re-runs
`depmod`, and reinstalls the WiFi firmware. Do *not* use `2_create_sd.sh` for
this - it repartitions the card and discards everything you configured.

## Local patches
`1_compile.sh` applies every `patches/<component>/*.patch` to the matching tree
right after cloning it, because the D1 U-Boot fork dates from 2023 and does not
build against a current toolchain unmodified:

- `0001-pylibfdt-python3-c-api.patch` - pylibfdt's SWIG typemaps still call the
  Python 2 C API (`PyInt_AsLong`, `PyString_FromString`). Harmless warnings until
  GCC 14 made them errors.
- `0002-binman-importlib-resources.patch` - binman imports `pkg_resources`, which
  setuptools 81 removed.

## Using loop image file instead of a SD card
Simply loop it using `sudo losetup -f -P <file>` and then use `/dev/loopX` as the target device.

## Notes
The second script requires `arch-install-scripts`, `qemu-user-static-bin` (AUR) and `binfmt-qemu-static` (AUR) for an architectural chroot.
If you don't want to use/do this, change `USE_CHROOT` to `0` in `consts.sh`.  
*Keep in mind, that this is just a extracted rootfs with **no** configuration. You probably want to update the system, install an editor and take care of network access/ssh*

Some commits are pinned, this means that in the future this script might stop working since often a git HEAD is checked out. This is intentional.

The second script uses `sudo` for root access. Like any random script from a random stranger from the internet, have a look at the code first and use at own risk!

Things are rebuild whenever the corresponding `output/<file>` is missing. For example, the kernel is rebuilt when there is no `Image` file.

# Status

## 25.07.2023
- forgot to keep this up to date...
- mainline kernel fully supports the D1
- kernel updated to 6.4 (mainline)
- OpenSBI updated to 1.3

## 4.11.2022
- WiFi is working again

## 3.11.2022
- updated U-Boot and remove boot0 (handled by [U-Boot](https://github.com/smaeul/u-boot/releases/tag/d1-2022-10-31))
- updated kernel to 6.1.0-rc3
    - **THIS BRAKES BUILT-IN WIFI**

## 13.09.2022
- kernel is back at 5.18-rc1 due to being more reliable

## 14.06.2022
- kernel updated to 5.19-rc1
- added initramfs support (untested)
- added extlinux support

## 22.04.2022
- kernel includes modules for USB LAN adapter
- swap is enabled
## 09.04.2022
- HDMI, tested with LXDE/LXDM
## 07.04.2022
- WiFi \o/
## 06.04.2022
- Kernel is based on 5.18-rc1
- WiFi driver fails to build (linking error :feelsbadman:)
- Both kernel and U-Boot are using `nezha_defconfig` since i found them more reliable
    - With the [licheerv_linux_defconfig](https://andreas.welcomes-you.com/media/files/licheerv_linux_defconfig) from [here](https://andreas.welcomes-you.com/boot-sw-debian-risc-v-lichee-rv/) the kernel fails to find the sd card (or its partitions? not sure what exactly goes wrong)
- HDMI is not working (at least on the one screen i've tested it)


# Problems
## 06.04.2022
- ~no WiFi!~
- ~No HDMI (though, i'm unsure about the state of HDMI support in general)~
