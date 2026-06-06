#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${ROOT_DIR}/kernel"

if [ ! -d "${KERNEL_DIR}" ]; then
  echo "error: kernel source not found at ${KERNEL_DIR}" >&2
  echo "hint: run git submodule update --init --recursive first" >&2
  exit 1
fi

if [ ! -f "${ROOT_DIR}/.github/scripts/build-kernel.sh" ]; then
  echo "error: missing .github/scripts/build-kernel.sh" >&2
  exit 1
fi

if [ -x "/mnt/Hawai/toolchains/Clang-23.0.0git-20260130/bin/clang" ] && [ -d "/mnt/Hawai/toolchains" ]; then
  DEFAULT_CLANG_BIN="/mnt/Hawai/toolchains/Clang-23.0.0git-20260130/bin"
  DEFAULT_ARM64_TOOLCHAIN="/mnt/Hawai/toolchains/arm-gnu-toolchain-15.2.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
  DEFAULT_ARM32_TOOLCHAIN="/mnt/Hawai/toolchains/arm-gnu-toolchain-15.2.rel1-x86_64-arm-none-eabi/bin/arm-none-eabi-"
else
  CLANG_PATH="$(command -v clang || true)"
  if [ -z "${CLANG_PATH}" ]; then
    echo "error: clang not found in PATH and local toolchain is unavailable" >&2
    exit 1
  fi
  DEFAULT_CLANG_BIN="$(dirname "${CLANG_PATH}")"
  DEFAULT_ARM64_TOOLCHAIN="aarch64-linux-gnu-"
  DEFAULT_ARM32_TOOLCHAIN="arm-linux-gnueabihf-"
fi

# ---- Pre-build verification ----
verify_preconditions() {
  local errors=0

  echo "::group::Pre-build verification"

  # Toolchain
  if [ ! -x "${CLANG_BIN}/clang" ]; then
    echo "::error::clang not found at CLANG_BIN=${CLANG_BIN}"
    errors=$((errors + 1))
  else
    echo "✅ clang: ${CLANG_BIN}/clang"
  fi

  # Dynasched source integrity (must be full implementation, not stub)
  local dynasched_file="${ROOT_DIR}/.github/patches/global/cpufreq_dynasched.c"
  if [ -f "$dynasched_file" ] && [ "$(wc -l < "$dynasched_file")" -gt 100 ]; then
    echo "✅ dynasched: ${dynasched_file} ($(wc -l < "$dynasched_file") lines)"
  else
    echo "::error::dynasched source is missing or truncated at ${dynasched_file}"
    errors=$((errors + 1))
  fi

  # KernelSU integration
  if [ -d "${KERNEL_DIR}/drivers/kernelsu" ]; then
    echo "✅ KernelSU: drivers/kernelsu/ present"
  elif [ -d "${KERNEL_DIR}/KernelSU" ]; then
    echo "✅ KernelSU: KernelSU/ present"
  else
    echo "::warning::KernelSU not detected in kernel tree"
  fi

  # SuSFS
  if [ "${ENABLE_SUSFS}" = "true" ] && [ ! -f "${KERNEL_DIR}/fs/susfs.c" ]; then
    echo "::warning::SuSFS enabled but fs/susfs.c not found — will run setup"
  elif [ "${ENABLE_SUSFS}" = "true" ]; then
    echo "✅ SuSFS: fs/susfs.c present"
  fi

  # Baseband guard patch
  if [ -f "${ROOT_DIR}/.github/patches/common/baseband-guard-pixel8a.patch" ]; then
    echo "✅ baseband-guard: patch file present"
    if grep -q 'baseband_guard' "${KERNEL_DIR}/security/Makefile" 2>/dev/null; then
      echo "✅ baseband-guard: integrated in kernel tree"
    else
      echo "::warning::baseband-guard: patch file exists but may not be applied in tree"
    fi
  fi

  # KernelSU LSM hooks config
  if grep -q 'CONFIG_KSU_LSM_SECURITY_HOOKS=y' "${KERNEL_DIR}/arch/arm64/configs/gki_defconfig" 2>/dev/null; then
    echo "✅ KSU LSM hooks: configured in gki_defconfig"
  else
    echo "::warning::KSU LSM hooks not found in gki_defconfig"
  fi

  if [ "$errors" -gt 0 ]; then
    echo "::error::$errors pre-build check(s) failed. Aborting."
    echo "::endgroup::"
    exit 1
  fi
  echo "::endgroup::"
}

export GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-${ROOT_DIR}}"
export KSU_VARIANT="${KSU_VARIANT:-enhance}"
export ENABLE_SUSFS="${ENABLE_SUSFS:-true}"
export FORCE_CLEAN="false"
export DIRTY_BUILD="true"
export DIRTY_MODULE_ABI_BYPASS="${DIRTY_MODULE_ABI_BYPASS:-true}"
export TUNING_PROFILE="${TUNING_PROFILE:-balanced}"
export LTO_MODE="${LTO_MODE:-thin}"
export MAKE_JOBS_OVERRIDE="${MAKE_JOBS_OVERRIDE:-auto}"
export BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
export BUILD_LOAD="${BUILD_LOAD:-$((BUILD_JOBS + 1))}"
export CLANG_BIN="${CLANG_BIN:-${DEFAULT_CLANG_BIN}}"
export ARM64_TOOLCHAIN="${ARM64_TOOLCHAIN:-${DEFAULT_ARM64_TOOLCHAIN}}"
export ARM32_TOOLCHAIN="${ARM32_TOOLCHAIN:-${DEFAULT_ARM32_TOOLCHAIN}}"
export CCACHE_DIR="${CCACHE_DIR:-${HOME}/.ccache}"
export TMPDIR="${TMPDIR:-/tmp/kernel-build}"

mkdir -p "${ROOT_DIR}/logs" "${CCACHE_DIR}" "${TMPDIR}"

if [ ! -d "${KERNEL_DIR}/drivers/kernelsu" ] && [ ! -d "${KERNEL_DIR}/KernelSU" ]; then
  echo "warning: KernelSU does not appear to be integrated in ${KERNEL_DIR}" >&2
  echo "warning: this wrapper preserves the dirty tree and does not sync/apply workflow patches" >&2
fi

if [ "${ENABLE_SUSFS}" = "true" ] && [ ! -f "${KERNEL_DIR}/fs/susfs.c" ]; then
  echo "SuSFS enabled but not yet applied. Running local-setup-susfs.sh..."
  bash "${ROOT_DIR}/scripts/local-setup-susfs.sh"
elif [ "${ENABLE_SUSFS}" = "true" ]; then
  echo "SuSFS source files already present in kernel tree."
fi

verify_preconditions

echo "Dirty local build: variant=${KSU_VARIANT}, susfs=${ENABLE_SUSFS}, lto=${LTO_MODE}, jobs=${BUILD_JOBS}, clang=${CLANG_BIN}"
cd "${ROOT_DIR}"
bash .github/scripts/build-kernel.sh

# Post-build: create boot image with correct format (LZ4 + V4 header)
IMAGE_FILE="${KERNEL_DIR}/out/arch/arm64/boot/Image"
IMAGE_LZ4="${KERNEL_DIR}/out/arch/arm64/boot/Image.lz4"
BOOT_IMG="${ROOT_DIR}/boot-image-local-build.img"

if [ -f "${IMAGE_FILE}" ] && command -v lz4 >/dev/null 2>&1 && command -v mkbootimg >/dev/null 2>&1; then
  echo "Creating LZ4-compressed kernel..."
  lz4 -f -l -12 --favor-decSpeed "${IMAGE_FILE}" "${IMAGE_LZ4}" 2>&1
  echo "Creating boot image with V4 header..."
  mkbootimg --kernel "${IMAGE_LZ4}" \
    --base 0x00000000 \
    --pagesize 4096 \
    --header_version 4 \
    -o "${BOOT_IMG}" 2>&1
  echo "Boot image created: ${BOOT_IMG}"
  sha256sum "${BOOT_IMG}"
else
  echo "warning: boot image not created (lz4/mkbootimg missing, or kernel Image not found)"
fi
