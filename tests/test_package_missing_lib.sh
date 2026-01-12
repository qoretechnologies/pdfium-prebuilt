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

echo "PDFium License" > "${PDFIUM_SRC}/LICENSE"

set +e
"${ROOT_DIR}/scripts/package_pdfium.sh" \
    --pdfium-src "${PDFIUM_SRC}" \
    --pdfium-out "${PDFIUM_OUT}" \
    --target-os ubuntu \
    --arch amd64 \
    --pdfium-ref deadbeef \
    --chromium-milestone M126 \
    --dist-dir "${WORK_DIR}/dist" >/dev/null 2>&1
STATUS=$?
set -e

if [[ ${STATUS} -eq 0 ]]; then
    echo "Expected packaging to fail when libraries are missing" >&2
    exit 1
fi
