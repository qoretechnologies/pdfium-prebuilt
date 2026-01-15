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

# Use system gn on Alpine (it's new enough and depot_tools gn doesn't work on musl)
# On Ubuntu, use depot_tools gn (system gn is too old, missing path_exists function)
if [[ -f /etc/alpine-release && -x /usr/bin/gn ]]; then
    GN_CMD="/usr/bin/gn"
    echo "-- using system gn: ${GN_CMD}"
else
    # Bootstrap depot_tools to ensure gn is available
    echo "-- bootstrapping depot_tools gn"
    "${DEPOT_TOOLS_DIR}/ensure_bootstrap"
    GN_CMD="gn"
fi

# Create CUSTOM_CIPD_CLIENT wrapper to skip unavailable packages (e.g., reclient for linux-arm64)
# This is needed because custom_deps doesn't work for cipd dependencies
# The CUSTOM_CIPD_CLIENT env var is checked at the start of the cipd launcher and is more reliable
# than trying to wrap the launcher script itself
echo "-- creating cipd wrapper to skip unavailable packages"
CIPD_WRAPPER="${BUILD_DIR}/cipd_wrapper.sh"
cat > "${CIPD_WRAPPER}" << 'WRAPPER'
#!/bin/bash
# Wrapper to filter out unavailable cipd packages from ensure files
# This wrapper is invoked via CUSTOM_CIPD_CLIENT env var

# Find the real cipd client
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_CIPD="${SCRIPT_DIR}/depot_tools/.cipd_client"

# If .cipd_client doesn't exist yet, we need to bootstrap first
if [[ ! -x "${REAL_CIPD}" ]]; then
    # Temporarily unset CUSTOM_CIPD_CLIENT to let the normal bootstrap happen
    unset CUSTOM_CIPD_CLIENT
    # Run the cipd launcher to trigger bootstrap
    "${SCRIPT_DIR}/depot_tools/cipd" version >/dev/null 2>&1 || true
    # Restore
    export CUSTOM_CIPD_CLIENT="${BASH_SOURCE[0]}"
fi

ARGS=("$@")
for i in "${!ARGS[@]}"; do
    if [[ "${ARGS[$i]}" == "-ensure-file" && -n "${ARGS[$((i+1))]}" ]]; then
        ENSURE_FILE="${ARGS[$((i+1))]}"
        # Filter out linux-arm64 rbe/client package which doesn't exist
        if grep -q "infra/rbe/client/linux-arm64" "$ENSURE_FILE" 2>/dev/null; then
            FILTERED_FILE="${ENSURE_FILE}.filtered"
            grep -v "infra/rbe/client/linux-arm64" "$ENSURE_FILE" > "$FILTERED_FILE"
            ARGS[$((i+1))]="$FILTERED_FILE"
            echo "CIPD wrapper: Filtered unavailable package infra/rbe/client/linux-arm64"
        fi
    fi
done
exec "${REAL_CIPD}" "${ARGS[@]}"
WRAPPER
chmod +x "${CIPD_WRAPPER}"
export CUSTOM_CIPD_CLIENT="${CIPD_WRAPPER}"

if [[ ! -d "${PDFIUM_SRC_DIR}" ]]; then
    echo "-- fetching pdfium source"
    mkdir -p "${BUILD_DIR}"
    pushd "${BUILD_DIR}" >/dev/null
    # Create .gclient with custom_vars and custom_deps to disable RBE (Remote Build Execution)
    # which isn't available for all platforms (e.g., ARM64)
    cat > .gclient << 'GCLIENT'
solutions = [
  {
    "name": "pdfium",
    "url": "https://pdfium.googlesource.com/pdfium.git",
    "managed": False,
    "custom_vars": {
      "download_remoteexec_cfg": False,
    },
    "custom_deps": {
      "buildtools/reclient": None,
    },
  },
]
GCLIENT
    # Use --nohooks to skip cipd during initial fetch, patch DEPS, then run hooks
    gclient sync --nohooks
    popd >/dev/null
fi

echo "-- syncing pdfium"
cd "${PDFIUM_SRC_DIR}"
git fetch origin
git checkout "${PDFIUM_REF}"

# Remove reclient dependency from DEPS (not available for linux-arm64)
# This must be done before gclient sync to prevent cipd from failing
echo "-- patching DEPS to remove reclient dependency"
sed -i "/'buildtools\/reclient':/,/},$/d" "${PDFIUM_SRC_DIR}/DEPS"

# Sync dependencies for the checked out ref
echo "-- syncing dependencies"
cd "${BUILD_DIR}"
gclient sync
cd "${PDFIUM_SRC_DIR}"

# Patch bundled libc++ for musl support on Alpine
if [[ -f /etc/alpine-release ]]; then
    echo "-- patching libc++ for musl support"
    # Find and patch __locale file to add rune table support before the check
    LIBCXX_LOCALE="${PDFIUM_SRC_DIR}/third_party/libc++/src/include/__locale"
    if [[ -f "${LIBCXX_LOCALE}" ]]; then
        # Add define and comment out the #error check in __locale
        # The define must be added AND the #error removed since the error is inside a preprocessor conditional
        sed -i 's/#  *error unknown rune table for this platform.*/#define _LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE/' "${LIBCXX_LOCALE}"
        echo "   patched ${LIBCXX_LOCALE}"
    else
        echo "   warning: ${LIBCXX_LOCALE} not found"
        # Try alternative location
        LIBCXX_LOCALE="${PDFIUM_SRC_DIR}/buildtools/third_party/libc++/trunk/include/__locale"
        if [[ -f "${LIBCXX_LOCALE}" ]]; then
            sed -i 's/#  *error unknown rune table for this platform.*/#define _LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE/' "${LIBCXX_LOCALE}"
            echo "   patched ${LIBCXX_LOCALE} (alternative location)"
        else
            echo "   warning: libc++ locale file not found, listing available:"
            find "${PDFIUM_SRC_DIR}" -name "__locale" 2>/dev/null | head -5
        fi
    fi
fi

GN_ARGS=(
    "is_debug=false"
    "is_component_build=true"
    "pdf_is_standalone=true"
    "use_sysroot=false"
    "clang_use_chrome_plugins=false"
    "treat_warnings_as_errors=false"
    "target_os=\"linux\""
    "target_cpu=\"${TARGET_CPU}\""
)

# On Alpine/musl, use system clang and patch bundled libc++ headers for musl
if [[ -f /etc/alpine-release ]]; then
    echo "-- configuring for Alpine (musl): using system clang with patched libc++"
    GN_ARGS+=(
        "is_clang=true"
        "clang_base_path=\"/usr\""
        "clang_use_chrome_plugins=false"
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
