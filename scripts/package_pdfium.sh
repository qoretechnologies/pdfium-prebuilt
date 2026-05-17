#!/usr/bin/env bash

set -euo pipefail

print_usage() {
    cat <<'USAGE'
Usage: package_pdfium.sh --pdfium-src <path> --pdfium-out <path> --target-os <ubuntu|alpine> --arch <amd64|arm64> --pdfium-ref <commit> --chromium-milestone <M*> [options]

Options:
  --dist-dir <path>       Output directory for release artifacts (default: ./dist)
  --target-image <image>  Build container target recorded in VERSION metadata
USAGE
}

PDFIUM_SRC=""
PDFIUM_OUT=""
TARGET_OS=""
ARCH=""
PDFIUM_REF=""
CHROMIUM_MILESTONE=""
TARGET_IMAGE=""
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
        --target-image)
            TARGET_IMAGE="$2"
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

# PDFium outputs libraries with various names depending on build configuration
# For component builds (is_component_build=true), there are multiple .so files
# For non-component builds, there's a single libpdfium.a or libpdfium.so

# Count shared libraries
SHARED_COUNT=$(find "${PDFIUM_OUT}" -maxdepth 1 -name "*.so" 2>/dev/null | wc -l)
echo "Found ${SHARED_COUNT} shared libraries in ${PDFIUM_OUT}"

STAGE_DIR="${DIST_DIR}/stage"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}/include" "${STAGE_DIR}/lib" "${STAGE_DIR}/LICENSES"

cp -R "${PDFIUM_SRC}/public/." "${STAGE_DIR}/include/"

if [[ ${SHARED_COUNT} -gt 0 ]]; then
    echo "Packaging component build (multiple .so files)..."
    # Copy all shared libraries for component builds
    for so_file in "${PDFIUM_OUT}"/*.so; do
        if [[ -f "${so_file}" ]]; then
            cp "${so_file}" "${STAGE_DIR}/lib/"
            echo "  copied $(basename "${so_file}")"
        fi
    done
elif [[ -f "${PDFIUM_OUT}/obj/libpdfium.a" ]]; then
    echo "Packaging static build..."
    cp "${PDFIUM_OUT}/obj/libpdfium.a" "${STAGE_DIR}/lib/libpdfium.a"
elif [[ -f "${PDFIUM_OUT}/libpdfium.a" ]]; then
    echo "Packaging static build..."
    cp "${PDFIUM_OUT}/libpdfium.a" "${STAGE_DIR}/lib/libpdfium.a"
else
    echo "Missing PDFium libraries in ${PDFIUM_OUT}" >&2
    echo "Available files:" >&2
    ls -la "${PDFIUM_OUT}/" >&2
    ls -la "${PDFIUM_OUT}/obj/" 2>/dev/null >&2 || true
    exit 1
fi

echo "Libraries packaged:"
ls -la "${STAGE_DIR}/lib/"

cp "${PDFIUM_LICENSE}" "${STAGE_DIR}/LICENSES/PDFIUM.LICENSE"

BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat <<EOF_META > "${STAGE_DIR}/VERSION"
PDFIUM_REF=${PDFIUM_REF}
CHROMIUM_MILESTONE=${CHROMIUM_MILESTONE}
TARGET_OS=${TARGET_OS}
ARCH=${ARCH}
BUILD_DATE_UTC=${BUILD_DATE}
EOF_META
if [[ -n "${TARGET_IMAGE}" ]]; then
    echo "TARGET_IMAGE=${TARGET_IMAGE}" >> "${STAGE_DIR}/VERSION"
fi

# Sanitize ref name for filename (replace / with -)
SAFE_REF="${PDFIUM_REF//\//-}"
TARBALL_NAME="pdfium-${SAFE_REF}-${TARGET_OS}-${ARCH}.tar.xz"
mkdir -p "${DIST_DIR}"

tar -C "${STAGE_DIR}" -cJf "${DIST_DIR}/${TARBALL_NAME}" .

echo "-- wrote ${DIST_DIR}/${TARBALL_NAME}"
