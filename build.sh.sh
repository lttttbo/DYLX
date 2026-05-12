#!/usr/bin/env bash
set -euo pipefail

# Standalone OP-TEE build driver.
# Put this script either under op-tee/ or op-tee/scripts/.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/optee_os" && -f "${SCRIPT_DIR}/optee.mk" ]]; then
  OPTEE_ROOT="${OPTEE_ROOT:-${SCRIPT_DIR}}"
else
  OPTEE_ROOT="${OPTEE_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
fi

ACTION="${1:-build}"
case "${ACTION}" in
  build|optee) MAKE_TARGET="optee" ;;
  clean)       MAKE_TARGET="clean-optee" ;;
  vars|print)  MAKE_TARGET="print-optee-vars" ;;
  *)
    echo "Usage: $0 [build|clean|vars]" >&2
    exit 2
    ;;
esac

# Board/platform configuration.
export OPTEE_PLATFORM="${OPTEE_PLATFORM:-zx-evb}"
export ENABLE_OPTEE_OOT_BUILD="${ENABLE_OPTEE_OOT_BUILD:-true}"
export DEBUG="${DEBUG:-0}"

# Output layout for standalone builds.
TOPDIR_DEFAULT="$(cd "${OPTEE_ROOT}/.." && pwd)"
export TOPDIR="${TOPDIR:-${TOPDIR_DEFAULT}}"
OUT_DIR="${OUT_DIR:-${TOPDIR}/out-optee}"
export TARGET_OUT="${TARGET_OUT:-${OUT_DIR}/target}"
export TARGET_OUT_INTERMEDIATES="${TARGET_OUT_INTERMEDIATES:-${OUT_DIR}/intermediates}"
export DEBUG_IMAGE_OUT="${DEBUG_IMAGE_OUT:-${OUT_DIR}/images}"
export DEVICE_PREBUILT_BOOT_IMAGES_DIR="${DEVICE_PREBUILT_BOOT_IMAGES_DIR:-${TOPDIR}/prebuilts}"

# Toolchain integration.
# Supported layout example:
#   TOOLCHAIN_DIR=$HOME/toolchains
#   $TOOLCHAIN_DIR/aarch64/bin/aarch64-linux-gnu-gcc
#   $TOOLCHAIN_DIR/aarch32/bin/arm-linux-gnueabihf-gcc
if [[ -n "${TOOLCHAIN_DIR:-}" ]]; then
  [[ -d "${TOOLCHAIN_DIR}/aarch64/bin" ]] && export PATH="${TOOLCHAIN_DIR}/aarch64/bin:${PATH}"
  [[ -d "${TOOLCHAIN_DIR}/aarch32/bin" ]] && export PATH="${TOOLCHAIN_DIR}/aarch32/bin:${PATH}"
fi

# You can set these to absolute prefixes, for example:
#   AARCH64_CROSS_COMPILE=/opt/gcc-arm/bin/aarch64-linux-gnu-
#   AARCH32_CROSS_COMPILE=/opt/gcc-arm/bin/arm-linux-gnueabihf-
export AARCH64_CROSS_COMPILE="${AARCH64_CROSS_COMPILE:-${CROSS_COMPILE64:-aarch64-linux-gnu-}}"
export AARCH32_CROSS_COMPILE="${AARCH32_CROSS_COMPILE:-${CROSS_COMPILE32:-arm-linux-gnueabihf-}}"

require_prefix() {
  local prefix="$1"
  local gcc="${prefix}gcc"
  if ! command -v "${gcc}" >/dev/null 2>&1; then
    echo "ERROR: cannot find compiler: ${gcc}" >&2
    echo "       Add the toolchain bin directory to PATH, or export AARCH64_CROSS_COMPILE/AARCH32_CROSS_COMPILE." >&2
    exit 1
  fi
}

require_prefix "${AARCH64_CROSS_COMPILE}"
if [[ "${COMPILE_NS_USER:-64}${COMPILE_NS_KERNEL:-64}${COMPILE_S_USER:-64}${COMPILE_S_KERNEL:-64}" == *32* ]]; then
  require_prefix "${AARCH32_CROSS_COMPILE}"
elif ! command -v "${AARCH32_CROSS_COMPILE}gcc" >/dev/null 2>&1; then
  echo "WARN: ${AARCH32_CROSS_COMPILE}gcc not found. This is OK for a pure 64-bit build, but mixed 32/64 OP-TEE configs need it." >&2
fi

mkdir -p "${TARGET_OUT}" "${TARGET_OUT_INTERMEDIATES}" "${DEBUG_IMAGE_OUT}"

printf 'OPTEE_ROOT=%s\n' "${OPTEE_ROOT}"
printf 'OPTEE_PLATFORM=%s\n' "${OPTEE_PLATFORM}"
printf 'TARGET_OUT=%s\n' "${TARGET_OUT}"
printf 'TARGET_OUT_INTERMEDIATES=%s\n' "${TARGET_OUT_INTERMEDIATES}"
printf 'DEBUG_IMAGE_OUT=%s\n' "${DEBUG_IMAGE_OUT}"
printf 'AARCH64_CROSS_COMPILE=%s\n' "${AARCH64_CROSS_COMPILE}"
printf 'AARCH32_CROSS_COMPILE=%s\n' "${AARCH32_CROSS_COMPILE}"

JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 8)}"

exec make -f "${OPTEE_ROOT}/optee.mk" -j"${JOBS}" "${MAKE_TARGET}" \
  TEE_SRC="${OPTEE_ROOT}" \
  TOPDIR="${TOPDIR}" \
  OPTEE_PLATFORM="${OPTEE_PLATFORM}" \
  ENABLE_OPTEE_OOT_BUILD="${ENABLE_OPTEE_OOT_BUILD}" \
  TARGET_OUT="${TARGET_OUT}" \
  TARGET_OUT_INTERMEDIATES="${TARGET_OUT_INTERMEDIATES}" \
  DEBUG_IMAGE_OUT="${DEBUG_IMAGE_OUT}" \
  DEVICE_PREBUILT_BOOT_IMAGES_DIR="${DEVICE_PREBUILT_BOOT_IMAGES_DIR}" \
  AARCH64_CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" \
  AARCH32_CROSS_COMPILE="${AARCH32_CROSS_COMPILE}" \
  DEBUG="${DEBUG}"
