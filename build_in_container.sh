#!/usr/bin/env sh
#
# Runs the compile stage (1_compile.sh) inside a rootless podman container.
#
# Nothing here needs privileges: rootless podman maps the container's root to
# your own user, so build/, output/ and the downloaded rootfs end up owned by
# you. Only the flashing stage (2_create_sd.sh) needs root.
#
# Usage:
#   ./build_in_container.sh              # build the toolchain image, compile, fetch rootfs
#   ./build_in_container.sh -c 'command' # run something else in the build environment
#
# Environment:
#   CONTAINER_ENGINE  container cli to use (default: podman)
#   IMAGE_NAME        tag of the builder image (default: d1-riscv-builder)
#   SKIP_IMAGE_BUILD  set to 1 to reuse the existing builder image as-is

set -e

CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE_NAME="${IMAGE_NAME:-d1-riscv-builder}"
PROJECT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

if ! command -v "${CONTAINER_ENGINE}" >/dev/null 2>&1; then
    echo "Error: '${CONTAINER_ENGINE}' not found. Install it, or set CONTAINER_ENGINE."
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "Error: run this as your normal user - the build stage must not need root."
    echo "       Only 2_create_sd.sh is supposed to run privileged."
    exit 1
fi

# Keep stdin a tty only when we actually have one, so the script stays usable
# from CI or a background shell.
if [ -t 0 ]; then
    TTY_ARGS='--interactive --tty'
else
    TTY_ARGS=''
fi

run_in_container() {
    # shellcheck disable=SC2086 # TTY_ARGS is intentionally word-split
    "${CONTAINER_ENGINE}" run --rm ${TTY_ARGS} \
        --volume "${PROJECT_DIR}:/src" \
        --workdir /src \
        "${IMAGE_NAME}" "$@"
}

if [ "${SKIP_IMAGE_BUILD}" != '1' ]; then
    "${CONTAINER_ENGINE}" build \
        --tag "${IMAGE_NAME}" \
        --file "${PROJECT_DIR}/Containerfile" \
        "${PROJECT_DIR}"
fi

mkdir -p "${PROJECT_DIR}/build" "${PROJECT_DIR}/output"

if [ "$#" -gt 0 ]; then
    run_in_container "$@"
    exit 0
fi

run_in_container 1_compile.sh

# Fetch the rootfs here as well. 2_create_sd.sh would download it too, but it
# runs under sudo, which would leave a root-owned tarball in the project (and
# require wget on the host).
run_in_container -c '. ./consts.sh
if [ -f "${ROOT_FS}" ]; then
    echo "rootfs ${ROOT_FS} already present"
else
    echo "downloading ${ROOT_FS}"
    curl -fL -o "${ROOT_FS}.part" "${ROOT_FS_DL}"
    mv "${ROOT_FS}.part" "${ROOT_FS}"
fi'

echo ''
echo 'Compile stage done. Artifacts are in output/ and owned by you.'
echo 'Now flash (this is the only step that needs root):'
echo "    sudo ./2_create_sd.sh /dev/<device>"
