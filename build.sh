#!/bin/bash
#
# build.sh - Kernel build script for Sony Pioneer (SDM660)
#
# Uses the Android clang toolchain to produce a build
# of the kernel, with optimizations from nitro-lineage.
#
# Usage:
#   ./build.sh              # Build Kernel
#

set -e

# ============================================================
# ENVIRONMENT VARIABLES
# ============================================================
OLD_KERNEL_FILE="kernel-old"
CLANG_VERSION="r563880c"
CLANG_URL=""

if [ -f "$OLD_KERNEL_FILE" ]; then
    KERNEL_STR=$(strings $OLD_KERNEL_FILE | grep "Android (" | head -n 1)
    CLANG_VERSION=$(echo "$KERNEL_STR" | grep -oP 'based on \K(r[a-z0-9]+)')
    
    MATCH=$(curl -s "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+log?format=JSON" | sed '1d' | jq -r --arg ver "$CLANG_VERSION" '.log[] | select(.message | contains($ver)) | "\(.commit)|\(.message)"' | head -n 1)
    
    LAST_COMMIT=$(echo "$MATCH" | cut -d'|' -f1)
    COMMIT_MSG=$(echo "$MATCH" | cut -d'|' -f2-)

    if [ -z "$LAST_COMMIT" ]; then
        echo "WARNING: Could not fetch last commit for clang version $CLANG_VERSION, using version without commit hash."
        exit 1
    fi

    if [[ "$COMMIT_MSG" =~ "Remove" || "$COMMIT_MSG" =~ "Delete" ]]; then
        TARGET_REF="$LAST_COMMIT^"
    else
        TARGET_REF="$LAST_COMMIT"
    fi

    CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/$TARGET_REF/clang-$CLANG_VERSION.tar.gz"
else
    echo "WARNING: Old kernel file not found, defaulting to $CLANG_VERSION"
fi

JOBS="$(nproc)"

# ============================================================
# PATHS
# ============================================================
# Scripts live on the compiler branch, the source does not. Set KERNEL_DIR
# to point at the kernel tree when the script is not inside it.
KERNEL_DIR="${KERNEL_DIR:-$(cd "$(dirname "$0")" && pwd)}"
CLANG_DIR="${KERNEL_DIR}/toolchain/clang-${CLANG_VERSION}"
TOOLCHAIN_DIR="$(dirname "${CLANG_DIR}")"
PATCHES_DIR="${KERNEL_DIR}/patches"
OUT_DIR="${KERNEL_DIR}/out"
CCACHE_DIR="${KERNEL_DIR}/.ccache"
KERNEL_IMAGE="${OUT_DIR}/arch/arm64/boot/Image"

# ============================================================
# FLAGS
# ============================================================

if [ -z "$USE_CCACHE" ]; then
    USE_CCACHE=1
fi

INCREMENTAL="${INCREMENTAL:-0}"

# ============================================================
# TOOLCHAIN — Android clang
#
#   Android (+pgo, +bolt, +lto, +mlgo)
# ============================================================
export PATH="${CLANG_DIR}/bin:${PATH}"

echo "$PATH"

MAKE_ARGS=(
    O=out
    ARCH=arm64
    SUBARCH=arm64
    LLVM=1
    CROSS_COMPILE="aarch64-linux-gnu-"
    CROSS_COMPILE_ARM32="arm-none-eabi-"
    KCFLAGS="-Wno-error -Wno-unused-variable"
)

# ============================================================
# PARSE ARGUMENTS
# ============================================================
for arg in "$@"; do
    case "$arg" in
        clean)
            echo "Cleaning build output..."
            rm -rf "${OUT_DIR}" build.log
            echo "Clean complete."
            exit 0
            ;;
        --no-cache)
            USE_CCACHE=0
            ;;
        --incremental)
            INCREMENTAL=1
            ;;
        --help|-h)
            echo "Usage: $0 [clean] [--no-cache] [--incremental]"
            echo "  clean          Remove build output (out/ and build.log) and exit"
            echo "  --no-cache     Disable ccache for this build"
            echo "  --incremental  Keep out/ and let make rebuild only what changed"
            exit 0
            ;;
    esac
done

cd "${KERNEL_DIR}"

echo "============================================"
echo "  Kernel Build — Sony Pioneer (SDM660)"
echo "  Toolchain: ${CLANG_VERSION}"
echo "  Jobs: ${JOBS}"
echo "============================================"
echo ""

echo "--- [0/4] Environment setup ---"
if [ ! -d "${TOOLCHAIN_DIR}" ]; then
    mkdir -p "${TOOLCHAIN_DIR}"
fi

# Setup ccache
if [ "${USE_CCACHE}" -eq 1 ] && command -v ccache &>/dev/null; then
    export CCACHE_DIR="${CCACHE_DIR}"
    export CCACHE_MAXSIZE="5G"
    MAKE_ARGS+=(CC="ccache clang" CXX="ccache clang++")
    echo "ccache enabled (dir: ${CCACHE_DIR}, max: ${CCACHE_MAXSIZE})"
elif [ "${USE_CCACHE}" -eq 1 ]; then
    echo "ccache not found in PATH — building without cache."
else
    echo "ccache disabled via --no-cache."
fi

if [ ! -d "${CLANG_DIR}" ]; then
    echo "Downloading Android clang ${CLANG_VERSION}..."
    if [ -n "$CLANG_URL" ]; then
        echo "Using detected clang URL: $CLANG_URL"
    else
        echo "No specific clang URL detected, using default for version ${CLANG_VERSION}"
        CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/mirror-goog-main-llvm-toolchain-source/clang-${CLANG_VERSION}.tar.gz"
    fi
    mkdir -p "${CLANG_DIR}"
    curl -L "${CLANG_URL}" | tar xz -C "${CLANG_DIR}"
    echo "Android clang downloaded and extracted to ${CLANG_DIR}"
else
    echo "Android clang already exists at ${CLANG_DIR}, skipping download." 
fi

if [ "${INCREMENTAL}" -eq 1 ]; then
    echo "--- [1/4] Keeping previous build output (--incremental) ---"
else
    echo "--- [1/4] Cleaning previous build ---"
    rm -rf "${OUT_DIR}" build.log
fi

echo "--- [2/4] Generate defconfig + merge Sony fragments ---"

make "${MAKE_ARGS[@]}" vendor/sdm660-perf_defconfig

# Merge Sony common + pioneer config fragments
ARCH=arm64 scripts/kconfig/merge_config.sh \
    -m -O out \
    out/.config \
    arch/arm64/configs/vendor/sony/common.config \
    arch/arm64/configs/vendor/sony/pioneer.config

# Resolve Kconfig dependencies
make "${MAKE_ARGS[@]}" olddefconfig

# ============================================================
# COMPILE KERNEL
# ============================================================

echo "--- [3/4] Compiling kernel (${JOBS} threads, log → build.log) ---"
make "${MAKE_ARGS[@]}" -j"${JOBS}" Image dtbs 2>&1 | tee build.log

echo "--- [4/4] Verifying build output ---"

if [ ! -f "${KERNEL_IMAGE}" ]; then
    echo ""
    echo "ERROR: Kernel Image was not generated!"
    echo "Check build.log for details."
    exit 1
fi

echo ""
echo "--- [4/4] Build complete ---"
echo ""
echo "============================================"
echo "  Build finished successfully!"
echo "============================================"
echo ""
echo "  Kernel Image : ${KERNEL_IMAGE}"
echo "  Size         : $(du -h "${KERNEL_IMAGE}" | cut -f1)"
echo "  Version      : $(strings "${KERNEL_IMAGE}" | grep "Linux version" | head -1)"
echo ""
echo "  DTBs:"
find "${OUT_DIR}/arch/arm64/boot/dts" -name '*.dtb' 2>/dev/null | head -10 | sed 's/^/    /'
echo ""
