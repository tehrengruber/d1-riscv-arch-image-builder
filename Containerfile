# Unprivileged build environment for the compile stage (1_compile.sh).
#
# Run it via ./build_in_container.sh -- rootless podman maps the container's
# root to your own UID, so everything written to build/ and output/ stays
# owned by you and no privileges are needed until the flashing stage.
FROM docker.io/library/archlinux:base-devel

# Toolchain and build-time dependencies for OpenSBI, U-Boot, the kernel and
# the rtl8723ds driver. Deliberately no qemu-user-static / arch-install-scripts:
# nothing in this image needs to be privileged.
RUN pacman-key --init \
    && pacman-key --populate archlinux \
    && pacman -Syu --noconfirm --needed \
        riscv64-linux-gnu-gcc \
        bc \
        cpio \
        curl \
        elfutils \
        git \
        openssl \
        perl \
        python3 \
        python-setuptools \
        python-pyelftools \
        rsync \
        swig \
        wget \
        xz \
        zstd \
    && pacman -Scc --noconfirm

# The project directory is bind-mounted here by build_in_container.sh.
WORKDIR /src

ENTRYPOINT ["sh"]
CMD ["1_compile.sh"]
