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

# On Alpine, export PYTHONPATH so bundled tools (gsutil) can find system packages like 'six'
if [[ -f /etc/alpine-release ]]; then
    SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])")
    export PYTHONPATH="${SITE_PACKAGES}:${PYTHONPATH:-}"
    echo "-- setting PYTHONPATH for Alpine: ${PYTHONPATH}"
fi

# Use system gn on Alpine (musl compatibility) or ARM64 (depot_tools downloads x86_64 binaries)
# On Ubuntu x86_64, use depot_tools gn (system gn is too old, missing path_exists function)
HOST_ARCH=$(uname -m)
if [[ -f /etc/alpine-release && -x /usr/bin/gn ]]; then
    GN_CMD="/usr/bin/gn"
    echo "-- using system gn (Alpine): ${GN_CMD}"
elif [[ "${HOST_ARCH}" == "aarch64" && -x /usr/bin/gn ]]; then
    GN_CMD="/usr/bin/gn"
    echo "-- using system gn (ARM64): ${GN_CMD}"
else
    # Bootstrap depot_tools to ensure gn is available
    echo "-- bootstrapping depot_tools gn"
    "${DEPOT_TOOLS_DIR}/ensure_bootstrap"
    GN_CMD="gn"
fi

# Create a cipd wrapper directory that comes FIRST in PATH
# This ensures our wrapper is called instead of depot_tools/cipd
CIPD_WRAPPER_DIR="${BUILD_DIR}/cipd_wrapper_bin"
mkdir -p "${CIPD_WRAPPER_DIR}"
echo "-- creating cipd wrapper in ${CIPD_WRAPPER_DIR}"

# The real cipd binary location
CIPD_CLIENT="${DEPOT_TOOLS_DIR}/.cipd_client"

# Create wrapper script that filters ensure files
cat > "${CIPD_WRAPPER_DIR}/cipd" << WRAPPER
#!/usr/bin/env bash
# Wrapper that filters unavailable packages from cipd ensure files
# This wrapper is placed in PATH before depot_tools

echo "CIPD WRAPPER: called with: \$@" >&2

REAL_CIPD="${CIPD_CLIENT}"

# If real cipd doesn't exist, try depot_tools cipd launcher to bootstrap
if [[ ! -x "\${REAL_CIPD}" ]]; then
    echo "CIPD WRAPPER: bootstrapping via depot_tools" >&2
    "${DEPOT_TOOLS_DIR}/cipd_bin_setup.sh" 2>&1 || true
fi

# Filter function - removes reclient package which doesn't exist for arm64
filter_ensure_file() {
    local ensure_file="\$1"
    if [[ -f "\$ensure_file" ]]; then
        # Filter lines containing infra/rbe/client (the reclient package)
        if grep -q "infra/rbe/client" "\$ensure_file"; then
            local filtered="\${ensure_file}.filtered"
            # Remove the @Subdir line for reclient and the package line
            grep -v -E "(buildtools/reclient|infra/rbe/client)" "\$ensure_file" > "\$filtered"
            echo "CIPD WRAPPER: Filtered reclient package from \$ensure_file" >&2
            echo "\$filtered"
            return
        fi
    fi
    echo "\$ensure_file"
}

# Process arguments
ARGS=()
skip_next=false
for arg in "\$@"; do
    if \$skip_next; then
        filtered=\$(filter_ensure_file "\$arg")
        ARGS+=("\$filtered")
        skip_next=false
        continue
    fi
    if [[ "\$arg" == "-ensure-file" ]]; then
        ARGS+=("\$arg")
        skip_next=true
    else
        ARGS+=("\$arg")
    fi
done

echo "CIPD WRAPPER: running \${REAL_CIPD} \${ARGS[*]}" >&2
exec "\${REAL_CIPD}" "\${ARGS[@]}"
WRAPPER
chmod +x "${CIPD_WRAPPER_DIR}/cipd"
echo "   Created wrapper at: ${CIPD_WRAPPER_DIR}/cipd"
cat "${CIPD_WRAPPER_DIR}/cipd"
echo "--- end wrapper ---"

# Prepend our wrapper directory to PATH
export PATH="${CIPD_WRAPPER_DIR}:${PATH}"
echo "   PATH now starts with: $(echo $PATH | cut -d: -f1-3)"
which cipd

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

# Sync dependencies for the checked out ref (without hooks - we'll run them after patching)
echo "-- syncing dependencies"
cd "${BUILD_DIR}"
gclient sync --nohooks
cd "${PDFIUM_SRC_DIR}"

# On Alpine, skip the test_fonts hook (gsutil has six module issues on musl)
# We don't need test fonts for building the library - they're only for running PDFium's tests
if [[ -f /etc/alpine-release ]]; then
    echo "-- patching DEPS to skip test_fonts hook (gsutil incompatible with musl)"
    python3 << PYTHON
import re
with open("${PDFIUM_SRC_DIR}/DEPS", "r") as f:
    content = f.read()
# Remove the test_fonts hook entry from the hooks list
# Pattern matches the entire hook dict that contains 'test_fonts'
content = re.sub(r"\s*\{\s*'name':\s*'test_fonts'[^}]*\},?\s*", "", content, flags=re.DOTALL)
with open("${PDFIUM_SRC_DIR}/DEPS", "w") as f:
    f.write(content)
print("   removed test_fonts hook from DEPS")
PYTHON
fi

# Patch build config to disable CREL when using system clang (ARM64 or Alpine)
# The CREL flags are added by Chromium's build config based on bundled clang version,
# but system clang (18-21) doesn't support the experimental --crel flag
if [[ "${HOST_ARCH}" == "aarch64" || -f /etc/alpine-release ]]; then
    echo "-- patching build config to disable CREL for system clang"
    COMPILER_GN="${PDFIUM_SRC_DIR}/build/config/compiler/BUILD.gn"
    if [[ -f "${COMPILER_GN}" ]]; then
        # Comment out the CREL-related assembler flags
        # The line format is: cflags += [ "-Wa,--crel,--allow-experimental-crel" ]
        sed -i 's/cflags += \[ "-Wa,--crel,--allow-experimental-crel" \]/# Disabled for system clang: cflags += [ "-Wa,--crel,--allow-experimental-crel" ]/' "${COMPILER_GN}"
        echo "   patched ${COMPILER_GN}"
        # Verify the patch was applied
        if grep -q "# Disabled for system clang" "${COMPILER_GN}"; then
            echo "   patch verified"
        else
            echo "   warning: patch may not have been applied correctly"
            grep -n "crel" "${COMPILER_GN}" || echo "   no crel references found"
        fi
    else
        echo "   warning: ${COMPILER_GN} not found"
    fi
fi

# On Alpine ARM64, patch toolchain files to use correct musl target triple
# PDFium's arm64 toolchain uses --target=aarch64-linux-gnu which is wrong for musl
# We need to patch both the toolchain definition AND the template file
if [[ -f /etc/alpine-release && "${HOST_ARCH}" == "aarch64" ]]; then
    echo "-- patching arm64 toolchain for musl target triple"

    # Patch the gcc_toolchain.gni template (where target triple is computed)
    TOOLCHAIN_GNI="${PDFIUM_SRC_DIR}/build/toolchain/gcc_toolchain.gni"
    if [[ -f "${TOOLCHAIN_GNI}" ]]; then
        sed -i 's/aarch64-linux-gnu/aarch64-alpine-linux-musl/g' "${TOOLCHAIN_GNI}"
        echo "   patched ${TOOLCHAIN_GNI}"
        if grep -q "aarch64-alpine-linux-musl" "${TOOLCHAIN_GNI}"; then
            echo "   verified aarch64-alpine-linux-musl in gcc_toolchain.gni"
        fi
    fi

    # Patch the Linux toolchain BUILD.gn
    TOOLCHAIN_GN="${PDFIUM_SRC_DIR}/build/toolchain/linux/BUILD.gn"
    if [[ -f "${TOOLCHAIN_GN}" ]]; then
        sed -i 's/aarch64-linux-gnu/aarch64-alpine-linux-musl/g' "${TOOLCHAIN_GN}"
        echo "   patched ${TOOLCHAIN_GN}"
        if grep -q "aarch64-alpine-linux-musl" "${TOOLCHAIN_GN}"; then
            echo "   verified aarch64-alpine-linux-musl in linux/BUILD.gn"
        fi
    fi

    # Patch build/config/compiler/BUILD.gn - this is the CRITICAL file
    # Lines ~1326-1327 contain: cflags += [ "--target=aarch64-linux-gnu" ]
    COMPILER_GN="${PDFIUM_SRC_DIR}/build/config/compiler/BUILD.gn"
    echo "   checking ${COMPILER_GN} for target triple..."
    if [[ -f "${COMPILER_GN}" ]]; then
        # Show what we're looking for
        echo "   current aarch64 references in compiler/BUILD.gn:"
        grep -n "aarch64" "${COMPILER_GN}" | head -5 || echo "   (none found)"
        # Apply the patch
        sed -i 's/aarch64-linux-gnu/aarch64-alpine-linux-musl/g' "${COMPILER_GN}"
        echo "   applied sed substitution to ${COMPILER_GN}"
        # Verify
        if grep -q "aarch64-alpine-linux-musl" "${COMPILER_GN}"; then
            echo "   verified: aarch64-alpine-linux-musl now in compiler/BUILD.gn"
            grep -n "aarch64-alpine-linux-musl" "${COMPILER_GN}" | head -3
        else
            echo "   WARNING: patch may not have been applied - checking content:"
            grep -n "aarch64" "${COMPILER_GN}" | head -5 || echo "   (no aarch64 references)"
        fi
    else
        echo "   WARNING: ${COMPILER_GN} not found!"
    fi

    # Search for any remaining references to aarch64-linux-gnu in the build directory
    # Use find+xargs instead of grep --include (BusyBox grep doesn't support --include)
    echo "   checking for remaining aarch64-linux-gnu references..."
    REMAINING=$(find "${PDFIUM_SRC_DIR}/build" \( -name "*.gn" -o -name "*.gni" \) -exec grep -l "aarch64-linux-gnu" {} \; 2>/dev/null | head -5) || true
    if [[ -n "${REMAINING}" ]]; then
        echo "   warning: remaining references found in:"
        echo "${REMAINING}"
    else
        echo "   no remaining references found"
    fi
fi

# Patch partition_alloc for musl support on Alpine ARM64
# Memory tagging (MTE) requires sys/ifunc.h which is glibc-specific
# We need to disable memory tagging entirely for musl builds
if [[ -f /etc/alpine-release && "${HOST_ARCH}" == "aarch64" ]]; then
    echo "-- patching partition_alloc to disable memory tagging for musl"

    # Patch partition_alloc.gni to disable memory tagging
    # This is the proper fix - disable the feature at the GN level
    PA_GNI="${PDFIUM_SRC_DIR}/base/allocator/partition_allocator/partition_alloc.gni"
    if [[ -f "${PA_GNI}" ]]; then
        # Replace the has_memory_tagging computation with false
        # Original: has_memory_tagging = current_cpu == "arm64" && is_clang && ...
        # New: has_memory_tagging = false  (for musl compatibility)
        sed -i 's/^has_memory_tagging = current_cpu == "arm64"/# Disabled for musl: has_memory_tagging = current_cpu == "arm64"/' "${PA_GNI}"
        # Add the override right after
        sed -i '/^# Disabled for musl: has_memory_tagging/a has_memory_tagging = false  # musl does not have sys\/ifunc.h' "${PA_GNI}"
        echo "   patched ${PA_GNI} to disable memory tagging"
        grep -n "has_memory_tagging" "${PA_GNI}" | head -5
    else
        echo "   warning: ${PA_GNI} not found"
    fi

    # Also patch aarch64_support.h as a fallback - add __GLIBC__ check to HAS_HW_CAPS
    AARCH64_SUPPORT_H="${PDFIUM_SRC_DIR}/base/allocator/partition_allocator/src/partition_alloc/aarch64_support.h"
    if [[ -f "${AARCH64_SUPPORT_H}" ]]; then
        sed -i 's/#if PA_BUILDFLAG(IS_ANDROID) || PA_BUILDFLAG(IS_LINUX)/#if PA_BUILDFLAG(IS_ANDROID) || (PA_BUILDFLAG(IS_LINUX) \&\& defined(__GLIBC__))/' "${AARCH64_SUPPORT_H}"
        echo "   patched ${AARCH64_SUPPORT_H}"
    fi
fi

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

# Now run hooks (after all patching is done)
echo "-- running gclient hooks"
cd "${BUILD_DIR}"
gclient runhooks
cd "${PDFIUM_SRC_DIR}"

GN_ARGS=(
    "is_debug=false"
    "is_component_build=true"
    "pdf_is_standalone=true"
    "use_sysroot=false"
    "clang_use_chrome_plugins=false"
    "treat_warnings_as_errors=false"
    "target_os=\"linux\""
)

# On Alpine, don't set target_cpu to avoid triggering cross-compilation mode
# which adds --target=aarch64-linux-gnu (wrong for musl)
if [[ ! -f /etc/alpine-release ]]; then
    GN_ARGS+=("target_cpu=\"${TARGET_CPU}\"")
fi

# On Alpine (musl compatibility) or ARM64 (bundled clang is x86_64), use system clang
if [[ -f /etc/alpine-release ]]; then
    echo "-- configuring for Alpine (musl): using system clang and libc++"
    GN_ARGS+=(
        "is_clang=true"
        "clang_base_path=\"/usr\""
        "clang_use_chrome_plugins=false"
        "use_custom_libcxx=false"
        "use_allocator_shim=false"
    )
elif [[ "${HOST_ARCH}" == "aarch64" ]]; then
    echo "-- configuring for ARM64: using system clang"
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
