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
mkdir -p "${PDFIUM_SRC}/public" "${PDFIUM_OUT}"

cat <<'EOF_HDR' > "${PDFIUM_SRC}/public/fpdf_doc.h"
#ifndef FPDF_DOC_H
#define FPDF_DOC_H
#endif
EOF_HDR

echo "PDFium License" > "${PDFIUM_SRC}/LICENSE"

echo "stub" > "${PDFIUM_OUT}/libpdfium.a"

DIST_DIR="${WORK_DIR}/dist"
"${ROOT_DIR}/scripts/package_pdfium.sh" \
    --pdfium-src "${PDFIUM_SRC}" \
    --pdfium-out "${PDFIUM_OUT}" \
    --target-os alpine \
    --arch amd64 \
    --pdfium-ref cafebabe \
    --chromium-milestone M126 \
    --dist-dir "${DIST_DIR}"

TARBALL="${DIST_DIR}/pdfium-cafebabe-alpine-amd64.tar.xz"
if [[ ! -f "${TARBALL}" ]]; then
    echo "Missing tarball: ${TARBALL}" >&2
    exit 1
fi

CONTENTS=$(tar -tf "${TARBALL}")

echo "${CONTENTS}" | grep -q "lib/libpdfium.a"
