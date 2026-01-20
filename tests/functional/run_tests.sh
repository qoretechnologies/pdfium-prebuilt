#!/usr/bin/env bash
#
# PDFium Functional Test Runner
# Copyright (c) 2026 Qore Technologies, s.r.o.
#
# Compiles and runs functional tests against a PDFium distribution.
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FIXTURES_DIR="${SCRIPT_DIR}/../fixtures"

usage() {
    echo "Usage: $0 --pdfium-dir <path-to-extracted-pdfium>"
    echo ""
    echo "Options:"
    echo "  --pdfium-dir    Path to extracted PDFium distribution (contains include/ and lib/)"
    echo "  --help          Show this help message"
    exit 1
}

# Parse arguments
PDFIUM_DIR=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --pdfium-dir)
            PDFIUM_DIR="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

if [[ -z "${PDFIUM_DIR}" ]]; then
    echo "Error: --pdfium-dir is required" >&2
    usage
fi

# Verify PDFium distribution structure
if [[ ! -d "${PDFIUM_DIR}/include" ]]; then
    echo "Error: ${PDFIUM_DIR}/include not found" >&2
    exit 1
fi

if [[ ! -d "${PDFIUM_DIR}/lib" ]]; then
    echo "Error: ${PDFIUM_DIR}/lib not found" >&2
    exit 1
fi

# Find the library (prefer static for simpler linking)
PDFIUM_LIB=""
USE_STATIC=false
if [[ -f "${PDFIUM_DIR}/lib/libpdfium.a" ]]; then
    PDFIUM_LIB="${PDFIUM_DIR}/lib/libpdfium.a"
    USE_STATIC=true
elif [[ -f "${PDFIUM_DIR}/lib/libpdfium.so" ]]; then
    PDFIUM_LIB="${PDFIUM_DIR}/lib/libpdfium.so"
else
    echo "Error: No libpdfium.so or libpdfium.a found in ${PDFIUM_DIR}/lib" >&2
    exit 1
fi

echo "PDFium Functional Test Runner"
echo "=============================="
echo "PDFium dir: ${PDFIUM_DIR}"
echo "Library: ${PDFIUM_LIB}"
echo "Static: ${USE_STATIC}"
echo ""

# Create temp directory for build
BUILD_DIR=$(mktemp -d)
cleanup() {
    rm -rf "${BUILD_DIR}"
}
trap cleanup EXIT

# Copy test source
cp "${SCRIPT_DIR}/test_pdfium.c" "${BUILD_DIR}/"

# Detect compiler - prefer clang++ for C++ stdlib compatibility
CXX="${CXX:-c++}"
if command -v clang++ &> /dev/null; then
    CXX="clang++"
elif command -v g++ &> /dev/null; then
    CXX="g++"
fi

echo "Compiler: ${CXX}"
echo ""

# Compile the test
echo "Compiling test program..."

if [[ "${USE_STATIC}" == "true" ]]; then
    # Static library - need to link all dependencies
    # PDFium static library built with use_custom_libcxx=false uses system libc++
    COMPILE_CMD="${CXX} \
        -o ${BUILD_DIR}/test_pdfium \
        ${BUILD_DIR}/test_pdfium.c \
        -I${PDFIUM_DIR}/include \
        ${PDFIUM_LIB} \
        -lm \
        -lpthread \
        -ldl"

    # Add libc++ on systems that have it (Alpine, or when clang is used)
    if [[ -f /etc/alpine-release ]] || [[ "${CXX}" == "clang++" ]]; then
        COMPILE_CMD="${COMPILE_CMD} -stdlib=libc++ -lc++"
    else
        COMPILE_CMD="${COMPILE_CMD} -lstdc++"
    fi
else
    # Shared library
    COMPILE_CMD="${CXX} \
        -o ${BUILD_DIR}/test_pdfium \
        ${BUILD_DIR}/test_pdfium.c \
        -I${PDFIUM_DIR}/include \
        -L${PDFIUM_DIR}/lib \
        -lpdfium \
        -lm \
        -lpthread"

    # On Linux, we need to add rpath for runtime and rpath-link for link-time
    # resolution of indirect dependencies (component builds have multiple .so files)
    if [[ "$(uname)" == "Linux" ]]; then
        COMPILE_CMD="${COMPILE_CMD} -Wl,-rpath,${PDFIUM_DIR}/lib -Wl,-rpath-link,${PDFIUM_DIR}/lib"
    fi
fi

echo "  ${COMPILE_CMD}"
eval "${COMPILE_CMD}"

if [[ ! -f "${BUILD_DIR}/test_pdfium" ]]; then
    echo "Error: Compilation failed" >&2
    exit 1
fi

echo "Compilation successful"
echo ""

# Run the tests
echo "Running tests..."
echo ""

# Set library path for dynamic linking
export LD_LIBRARY_PATH="${PDFIUM_DIR}/lib:${LD_LIBRARY_PATH:-}"

"${BUILD_DIR}/test_pdfium" "${FIXTURES_DIR}/test.pdf"
TEST_EXIT_CODE=$?

echo ""
if [[ ${TEST_EXIT_CODE} -eq 0 ]]; then
    echo "All functional tests passed!"
else
    echo "Some functional tests failed (exit code: ${TEST_EXIT_CODE})"
fi

exit ${TEST_EXIT_CODE}
