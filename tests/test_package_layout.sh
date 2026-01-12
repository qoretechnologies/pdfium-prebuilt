#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

PDFIUM_SRC="${WORK_DIR}/pdfium"
PDFIUM_OUT="${WORK_DIR}/pdfium/out/Release"
mkdir -p "${PDFIUM_SRC}/public/cpp" "${PDFIUM_OUT}"

cat <<'EOF_HDR' > "${PDFIUM_SRC}/public/cpp/fpdfview.h"
#ifndef FPDFVIEW_H
#define FPDFVIEW_H
#define FPDF_TEST 1
#endif
EOF_HDR

echo "PDFium License" > "${PDFIUM_SRC}/LICENSE"

echo "stub" > "${PDFIUM_OUT}/libpdfium.so"

DIST_DIR="${WORK_DIR}/dist"
"${ROOT_DIR}/scripts/package_pdfium.sh" \
    --pdfium-src "${PDFIUM_SRC}" \
    --pdfium-out "${PDFIUM_OUT}" \
    --target-os ubuntu \
    --arch amd64 \
    --pdfium-ref deadbeef \
    --chromium-milestone M126 \
    --dist-dir "${DIST_DIR}"

TARBALL="${DIST_DIR}/pdfium-deadbeef-ubuntu-amd64.tar.xz"
if [[ ! -f "${TARBALL}" ]]; then
    echo "Missing tarball: ${TARBALL}" >&2
    exit 1
fi

CONTENTS=$(tar -tf "${TARBALL}")

echo "${CONTENTS}" | grep -q "include/cpp/fpdfview.h"

echo "${CONTENTS}" | grep -q "lib/libpdfium.so"

echo "${CONTENTS}" | grep -q "VERSION"
