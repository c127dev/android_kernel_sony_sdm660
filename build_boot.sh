#!/bin/bash
#
# build_boot.sh - Build kernel and repack a flashable boot.img for Sony Pioneer
#
# Local mirror of the GitHub Actions pipeline (.github/workflows/build-and-release.yml):
#   1. Fetch Magisk and extract the host magiskboot binary
#   2. Download the latest LineageOS boot.img for the device
#   3. Unpack it to obtain the stock kernel (used by build.sh for clang autodetect)
#   4. Compile the kernel via build.sh
#   5. Inject the freshly built Image and repack into a new boot.img
#
# Usage:
#   ./build_boot.sh                 # full pipeline -> out/boot-nitro-<device>.img
#   ./build_boot.sh --boot <img>    # reuse a local boot.img (skip download)
#   ./build_boot.sh clean           # remove work dir + output boot image
#   ./build_boot.sh --help
#
# Env overrides:
#   DEVICE          LineageOS device codename            (default: pioneer)
#   MAGISK_VERSION  Magisk release tag                   (default: v26.4)
#   BOOT_IMG        Path to an existing boot.img         (skip download)
#   USE_CCACHE      Passed through to build.sh           (default: 1)

set -e

# ============================================================
# CONFIG
# ============================================================
KERNEL_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE="${DEVICE:-pioneer}"
MAGISK_VERSION="${MAGISK_VERSION:-v26.4}"
WORK_DIR="${KERNEL_DIR}/boot_work"
OUT_DIR="${KERNEL_DIR}/out"
KERNEL_IMAGE="${OUT_DIR}/arch/arm64/boot/Image"
FINAL_BOOT="${KERNEL_DIR}/boot-nitro-${DEVICE}.img"

MAGISK_URL="https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_VERSION}/Magisk-${MAGISK_VERSION}.apk"
LINEAGE_API="https://download.lineageos.org/api/v2/devices/${DEVICE}/builds"

# ============================================================
# PARSE ARGUMENTS
# ============================================================
for arg in "$@"; do
    case "$arg" in
        clean)
            echo "Cleaning boot work dir and output image..."
            rm -rf "${WORK_DIR}" "${FINAL_BOOT}"
            echo "Clean complete."
            exit 0
            ;;
        --boot)
            shift
            BOOT_IMG="$1"
            ;;
        --help|-h)
            echo "Usage: $0 [--boot <img>] [clean]"
            echo "  --boot <img>   Reuse a local boot.img instead of downloading"
            echo "  clean          Remove work dir and output boot image"
            echo "Env: DEVICE, MAGISK_VERSION, BOOT_IMG, USE_CCACHE"
            exit 0
            ;;
    esac
done

cd "${KERNEL_DIR}"
mkdir -p "${WORK_DIR}"

echo "============================================"
echo "  Boot Build — ${DEVICE} (SDM660)"
echo "  Magisk: ${MAGISK_VERSION}"
echo "============================================"
echo ""

# ============================================================
# [1/5] Fetch Magisk & extract magiskboot (host x86_64)
# ============================================================
echo "--- [1/5] Fetching magiskboot ---"
if [ ! -x "${WORK_DIR}/magiskboot" ]; then
    curl -L -o "${WORK_DIR}/magisk.apk" "${MAGISK_URL}"
    unzip -o -j "${WORK_DIR}/magisk.apk" "lib/x86_64/libmagiskboot.so" -d "${WORK_DIR}"
    mv "${WORK_DIR}/libmagiskboot.so" "${WORK_DIR}/magiskboot"
    chmod 755 "${WORK_DIR}/magiskboot"
    rm -f "${WORK_DIR}/magisk.apk"
    echo "magiskboot ready."
else
    echo "magiskboot already present, skipping."
fi

# ============================================================
# [2/5] Obtain stock boot.img
# ============================================================
echo "--- [2/5] Obtaining boot.img ---"
if [ -n "${BOOT_IMG}" ]; then
    echo "Using supplied boot.img: ${BOOT_IMG}"
    cp "${BOOT_IMG}" "${WORK_DIR}/boot.img"
else
    echo "Querying latest LineageOS build for ${DEVICE}..."
    BOOT_URL=$(curl -s "${LINEAGE_API}" | jq -r '.[0].files[] | select(.filename == "boot.img") | .url')
    if [ -z "${BOOT_URL}" ] || [ "${BOOT_URL}" = "null" ]; then
        echo "ERROR: could not resolve boot.img URL from ${LINEAGE_API}"
        exit 1
    fi
    echo "Downloading: ${BOOT_URL}"
    curl -L -o "${WORK_DIR}/boot.img" "${BOOT_URL}"
fi

# ============================================================
# [3/5] Unpack boot.img -> stock kernel
# ============================================================
echo "--- [3/5] Unpacking boot.img ---"
( cd "${WORK_DIR}" && ./magiskboot unpack boot.img )

# Hand the stock kernel to build.sh so it can autodetect the clang version
cp "${WORK_DIR}/kernel" "${KERNEL_DIR}/kernel-old"

# ============================================================
# [4/5] Compile kernel
# ============================================================
echo "--- [4/5] Building kernel (build.sh) ---"
chmod +x "${KERNEL_DIR}/build.sh"
"${KERNEL_DIR}/build.sh"

if [ ! -f "${KERNEL_IMAGE}" ]; then
    echo "ERROR: kernel Image not found at ${KERNEL_IMAGE}"
    exit 1
fi

# ============================================================
# [5/5] Inject kernel & repack
# ============================================================
echo "--- [5/5] Repacking boot.img with custom kernel ---"
cp "${KERNEL_IMAGE}" "${WORK_DIR}/kernel"
( cd "${WORK_DIR}" && ./magiskboot repack boot.img new-boot.img )
mv "${WORK_DIR}/new-boot.img" "${FINAL_BOOT}"

echo ""
echo "============================================"
echo "  Boot build finished!"
echo "============================================"
echo "  Boot image : ${FINAL_BOOT}"
echo "  Size       : $(du -h "${FINAL_BOOT}" | cut -f1)"
echo ""
echo "  Flash with: fastboot flash boot ${FINAL_BOOT}"
echo ""
