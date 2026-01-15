#!/usr/bin/env bash

set -euo pipefail

print_usage() {
    cat <<'USAGE'
Usage: build_pdfium.sh --pdfium-ref <commit> --target-os <ubuntu|alpine> --arch <amd64|arm64> [options]

Options:
  --build-dir <path>       Build workspace directory (default: ./build)
  --out-dir <path>         Output directory (default: <build-dir>/pdfium/out/Release)
  --depot-tools-dir <path> Depot tools directory (default: <build-dir>/depot_tools)
  --gn-args <args>         Extra GN args (quoted)
  --jobs <n>               Ninja parallelism (default: 4)
USAGE
}

BUILD_DIR=""
OUT_DIR=""
DEPOT_TOOLS_DIR=""
GN_EXTRA_ARGS=""
JOBS=4
PDFIUM_REF=""
TARGET_OS=""
ARCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pdfium-ref)
            PDFIUM_REF="$2"
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
        --build-dir)
            BUILD_DIR="$2"
            shift 2
            ;;
        --out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        --depot-tools-dir)
            DEPOT_TOOLS_DIR="$2"
            shift 2
            ;;
        --gn-args)
            GN_EXTRA_ARGS="$2"
            shift 2
            ;;
        --jobs)
            JOBS="$2"
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

if [[ -z "${PDFIUM_REF}" || -z "${TARGET_OS}" || -z "${ARCH}" ]]; then
    print_usage >&2
    exit 1
fi

case "${TARGET_OS}" in
    ubuntu|alpine)
        ;;
    *)
        echo "Unsupported target OS: ${TARGET_OS}" >&2
        exit 1
        ;;
esac

case "${ARCH}" in
    amd64)
        TARGET_CPU="x64"
        ;;
    arm64)
        TARGET_CPU="arm64"
        ;;
    *)
        echo "Unsupported arch: ${ARCH}" >&2
        exit 1
        ;;
esac

if [[ -z "${BUILD_DIR}" ]]; then
    BUILD_DIR="$(pwd)/build"
fi
if [[ -z "${DEPOT_TOOLS_DIR}" ]]; then
    DEPOT_TOOLS_DIR="${BUILD_DIR}/depot_tools"
fi

PDFIUM_SRC_DIR="${BUILD_DIR}/pdfium"
if [[ -z "${OUT_DIR}" ]]; then
    OUT_DIR="${PDFIUM_SRC_DIR}/out/Release"
fi

mkdir -p "${BUILD_DIR}"

if [[ ! -d "${DEPOT_TOOLS_DIR}" ]]; then
    echo "-- fetching depot_tools"
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "${DEPOT_TOOLS_DIR}"
fi

# On Alpine/musl, create vpython3 wrapper to use system Python
# (depot_tools' vpython binaries are glibc-based and don't work on musl)
if [[ -f /etc/alpine-release ]]; then
    echo "-- creating vpython3 wrapper for Alpine"
    cat > "${DEPOT_TOOLS_DIR}/vpython3" << 'WRAPPER'
#!/bin/sh
# Wrapper to use system python3 instead of vpython3 on Alpine
# Strips vpython-specific arguments and passes the rest to python3
args=""
skip_next=false
found_separator=false
for arg in "$@"; do
    if $skip_next; then
        skip_next=false
        continue
    fi
    if [ "$arg" = "--" ]; then
        found_separator=true
        continue
    fi
    case "$arg" in
        -vpython-spec|-vpython-root|-vpython-interpreter)
            skip_next=true
            continue
            ;;
        -vpython-*)
            continue
            ;;
    esac
    if $found_separator || [ -z "$args" ]; then
        args="$arg"
        found_separator=false
    else
        args="$args $arg"
    fi
done
exec python3 $args
WRAPPER
    chmod +x "${DEPOT_TOOLS_DIR}/vpython3"
fi

export PATH="${DEPOT_TOOLS_DIR}:${PATH}"

# Use system gn if available (needed for Alpine/musl where depot_tools gn doesn't work)
if [[ -x /usr/bin/gn ]]; then
    GN_CMD="/usr/bin/gn"
    echo "-- using system gn: ${GN_CMD}"
else
    GN_CMD="gn"
fi

if [[ ! -d "${PDFIUM_SRC_DIR}" ]]; then
    echo "-- fetching pdfium source"
    mkdir -p "${BUILD_DIR}"
    pushd "${BUILD_DIR}" >/dev/null
    # Create .gclient with custom_vars to disable RBE (Remote Build Execution)
    # which isn't available for all platforms (e.g., ARM64)
    cat > .gclient << 'GCLIENT'
solutions = [
  {
    "name": "pdfium",
    "url": "https://pdfium.googlesource.com/pdfium.git",
    "managed": False,
    "custom_vars": {
      "use_remoteexec": False,
    },
  },
]
GCLIENT
    gclient sync
    popd >/dev/null
fi

echo "-- syncing pdfium"
cd "${PDFIUM_SRC_DIR}"
git fetch origin
git checkout "${PDFIUM_REF}"

GN_ARGS=(
    "is_debug=false"
    "is_component_build=false"
    "pdf_is_standalone=true"
    "use_sysroot=false"
    "clang_use_chrome_plugins=false"
    "treat_warnings_as_errors=false"
    "target_os=\"linux\""
    "target_cpu=\"${TARGET_CPU}\""
)

# On Alpine/musl, use system clang and libc++ instead of bundled ones
# (bundled libc++ doesn't support musl out of the box)
if [[ -f /etc/alpine-release ]]; then
    echo "-- configuring for Alpine (musl): using system clang and libc++"
    GN_ARGS+=(
        "is_clang=true"
        "clang_base_path=\"/usr\""
        "clang_use_chrome_plugins=false"
        "use_custom_libcxx=false"
    )
fi

if [[ -n "${GN_EXTRA_ARGS}" ]]; then
    GN_ARGS+=("${GN_EXTRA_ARGS}")
fi

GN_ARGS_JOINED=$(IFS=" " ; echo "${GN_ARGS[*]}")

echo "-- generating build files"
mkdir -p "${OUT_DIR}"
${GN_CMD} gen "${OUT_DIR}" --args="${GN_ARGS_JOINED}"

echo "-- building pdfium"
/usr/bin/env ninja -C "${OUT_DIR}" -j "${JOBS}" pdfium

echo "-- build complete"
