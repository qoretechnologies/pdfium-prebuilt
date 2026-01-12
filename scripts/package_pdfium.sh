#!/usr/bin/env bash

set -euo pipefail

print_usage() {
    cat <<'USAGE'
Usage: package_pdfium.sh --pdfium-src <path> --pdfium-out <path> --target-os <ubuntu|alpine> --arch <amd64|arm64> --pdfium-ref <commit> --chromium-milestone <M*> [options]

Options:
  --dist-dir <path>   Output directory for release artifacts (default: ./dist)
USAGE
}

PDFIUM_SRC=""
PDFIUM_OUT=""
TARGET_OS=""
ARCH=""
PDFIUM_REF=""
CHROMIUM_MILESTONE=""
DIST_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pdfium-src)
            PDFIUM_SRC="$2"
            shift 2
            ;;
        --pdfium-out)
            PDFIUM_OUT="$2"
            shift 2
            ;;
        --target-os)
            TARGET_OS="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        --pdfium-ref)
            PDFIUM_REF="$2"
            shift 2
            ;;
        --chromium-milestone)
            CHROMIUM_MILESTONE="$2"
            shift 2
            ;;
        --dist-dir)
            DIST_DIR="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            print_usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "${PDFIUM_SRC}" || -z "${PDFIUM_OUT}" || -z "${TARGET_OS}" || -z "${ARCH}" || -z "${PDFIUM_REF}" || -z "${CHROMIUM_MILESTONE}" ]]; then
    print_usage >&2
    exit 1
fi

if [[ -z "${DIST_DIR}" ]]; then
    DIST_DIR="$(pwd)/dist"
fi

if [[ ! -d "${PDFIUM_SRC}/public" ]]; then
    echo "Missing PDFium public headers at ${PDFIUM_SRC}/public" >&2
    exit 1
fi

PDFIUM_LICENSE="${PDFIUM_SRC}/LICENSE"
if [[ ! -f "${PDFIUM_LICENSE}" ]]; then
    echo "Missing PDFium LICENSE at ${PDFIUM_LICENSE}" >&2
    exit 1
fi

LIB_SHARED="${PDFIUM_OUT}/libpdfium.so"
LIB_STATIC="${PDFIUM_OUT}/libpdfium.a"
if [[ ! -f "${LIB_SHARED}" && ! -f "${LIB_STATIC}" ]]; then
    echo "Missing PDFium libraries in ${PDFIUM_OUT}" >&2
    exit 1
fi

STAGE_DIR="${DIST_DIR}/stage"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}/include" "${STAGE_DIR}/lib" "${STAGE_DIR}/LICENSES"

cp -R "${PDFIUM_SRC}/public/." "${STAGE_DIR}/include/"

if [[ -f "${LIB_SHARED}" ]]; then
    cp "${LIB_SHARED}" "${STAGE_DIR}/lib/"
fi
if [[ -f "${LIB_STATIC}" ]]; then
    cp "${LIB_STATIC}" "${STAGE_DIR}/lib/"
fi

cp "${PDFIUM_LICENSE}" "${STAGE_DIR}/LICENSES/PDFIUM.LICENSE"

BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat <<EOF_META > "${STAGE_DIR}/VERSION"
PDFIUM_REF=${PDFIUM_REF}
CHROMIUM_MILESTONE=${CHROMIUM_MILESTONE}
TARGET_OS=${TARGET_OS}
ARCH=${ARCH}
BUILD_DATE_UTC=${BUILD_DATE}
EOF_META

TARBALL_NAME="pdfium-${PDFIUM_REF}-${TARGET_OS}-${ARCH}.tar.xz"
mkdir -p "${DIST_DIR}"

tar -C "${STAGE_DIR}" -cJf "${DIST_DIR}/${TARBALL_NAME}" .

echo "-- wrote ${DIST_DIR}/${TARBALL_NAME}"
