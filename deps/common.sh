#!/usr/bin/env bash
# Common build functions for nix.deb dependencies
# SPDX-License-Identifier: LGPL-2.1-or-later

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions - all go to stderr to avoid polluting stdout (used for return values)
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
    log_error "$@"
    exit 1
}

# Ensure required environment variables are set
require_env() {
    local var_name="$1"
    if [[ -z "${!var_name:-}" ]]; then
        die "Required environment variable $var_name is not set"
    fi
}

# Build environment variables that should be set before sourcing this file:
#   TARGET_DISTRO   - e.g., "debian-bookworm", "ubuntu-noble"
#   TARGET_ARCH     - e.g., "x86_64", "aarch64"
#   SYSROOT         - path to target sysroot
#   PREFIX          - installation prefix for built libraries
#   BUILD_DIR       - directory for build artifacts
#   SOURCE_DIR      - directory for downloaded sources

# Derived paths
setup_paths() {
    require_env TARGET_DISTRO
    require_env TARGET_ARCH

    : "${REPO_ROOT:=$(pwd)}"
    : "${SYSROOT:=$REPO_ROOT/sysroots/$TARGET_DISTRO}"
    : "${PREFIX:=$REPO_ROOT/out/$TARGET_DISTRO/prefix}"
    : "${BUILD_DIR:=$REPO_ROOT/out/$TARGET_DISTRO/build}"
    : "${SOURCE_DIR:=$REPO_ROOT/out/sources}"
    : "${JOBS:=$(nproc)}"

    export REPO_ROOT SYSROOT PREFIX BUILD_DIR SOURCE_DIR JOBS

    mkdir -p "$PREFIX"/{lib,include,bin,share}
    mkdir -p "$BUILD_DIR"
    mkdir -p "$SOURCE_DIR"
}

# Clang configuration for cross-compilation
setup_clang() {
    require_env SYSROOT
    require_env TARGET_ARCH

    local target_triple="${TARGET_ARCH}-linux-gnu"

    if command -v clang &>/dev/null; then
        CC=clang
        CXX=clang++
    else
        die "clang not found"
    fi

    # Find LLVM root (for libc++ and other LLVM libraries)
    # Try LLVM_ROOT env var, then /opt/llvm, then detect from clang path
    if [[ -z "${LLVM_ROOT:-}" ]]; then
        if [[ -d /opt/llvm ]]; then
            LLVM_ROOT=/opt/llvm
        else
            # Detect from clang binary location
            local clang_path
            clang_path=$(command -v clang)
            LLVM_ROOT=$(dirname "$(dirname "$clang_path")")
        fi
    fi
    export LLVM_ROOT

    # LLVM libc++ library path (used instead of libstdc++)
    # Prefer PREFIX's libc++ (built from source) over LLVM_ROOT's pre-built
    local cxx_libdir
    if [[ -f "$PREFIX/lib/libc++.a" ]]; then
        cxx_libdir="$PREFIX/lib"
    else
        cxx_libdir="$LLVM_ROOT/lib/x86_64-unknown-linux-gnu"
    fi

    # Common flags
    # -O2 provides good optimization without the risks of -O3
    # -fPIC is required for position-independent code (needed for static libs linked into shared)
    local common_flags=(
        "--target=$target_triple"
        "--sysroot=$SYSROOT"
        "-O2"
        "-fPIC"
    )

    # Add prefix to search paths
    common_flags+=(
        "-I$PREFIX/include"
    )

    export CC CXX
    export CFLAGS="${common_flags[*]} ${CFLAGS:-}"
    # Use libc++ (LLVM's C++ standard library) instead of libstdc++
    export CXXFLAGS="${common_flags[*]} -stdlib=libc++ ${CXXFLAGS:-}"
    # Use lld linker and rtlib=compiler-rt to avoid depending on GCC runtime
    # Use libc++ and provide path to libc++ libraries (PREFIX or LLVM_ROOT)
    export LDFLAGS="--target=$target_triple --sysroot=$SYSROOT -fuse-ld=lld -rtlib=compiler-rt -stdlib=libc++ -L$cxx_libdir -L$PREFIX/lib ${LDFLAGS:-}"

    # For CMake
    export CMAKE_TOOLCHAIN_ARGS=(
        "-DCMAKE_C_COMPILER=$CC"
        "-DCMAKE_CXX_COMPILER=$CXX"
        "-DCMAKE_C_FLAGS=$CFLAGS"
        "-DCMAKE_CXX_FLAGS=$CXXFLAGS"
        "-DCMAKE_EXE_LINKER_FLAGS=$LDFLAGS"
        "-DCMAKE_SHARED_LINKER_FLAGS=$LDFLAGS"
        "-DCMAKE_SYSROOT=$SYSROOT"
        "-DCMAKE_FIND_ROOT_PATH=$PREFIX;$SYSROOT"
        "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER"
        "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY"
        "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY"
        "-DCMAKE_INSTALL_PREFIX=$PREFIX"
    )

    # For pkg-config
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"

    log_info "Configured clang for $target_triple with sysroot $SYSROOT"
}

# Download a file if not already present
download() {
    local url="$1"
    local output="$2"

    if [[ -f "$output" ]]; then
        log_info "Already downloaded: $output"
        return 0
    fi

    log_info "Downloading: $url"
    mkdir -p "$(dirname "$output")"
    curl -fSL "$url" -o "$output.tmp"
    mv "$output.tmp" "$output"
    log_success "Downloaded: $output"
}

# Extract an archive
extract() {
    local archive="$1"
    local dest="${2:-$BUILD_DIR}"

    log_info "Extracting: $archive"

    mkdir -p "$dest"

    case "$archive" in
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$dest"
            ;;
        *.tar.bz2|*.tbz2)
            tar -xjf "$archive" -C "$dest"
            ;;
        *.tar.xz|*.txz)
            tar -xJf "$archive" -C "$dest"
            ;;
        *.tar.zst|*.tzst)
            tar --zstd -xf "$archive" -C "$dest"
            ;;
        *.zip)
            unzip -q "$archive" -d "$dest"
            ;;
        *)
            die "Unknown archive format: $archive"
            ;;
    esac

    log_success "Extracted: $archive"
}

# Download and extract a source tarball
fetch_source() {
    local name="$1"
    local version="$2"
    local url="$3"
    local archive_name="${4:-$name-$version.tar.gz}"

    local archive="$SOURCE_DIR/$archive_name"
    local src_dir="$BUILD_DIR/$name-$version"

    download "$url" "$archive"

    if [[ ! -d "$src_dir" ]]; then
        extract "$archive" "$BUILD_DIR"
    fi

    echo "$src_dir"
}

# Run make with parallel jobs
pmake() {
    make -j"$JOBS" "$@"
}

# Standard autoconf build
build_autoconf() {
    local src_dir="$1"
    shift
    local configure_args=("$@")

    cd "$src_dir"

    if [[ ! -f configure ]]; then
        if [[ -f autogen.sh ]]; then
            ./autogen.sh
        elif [[ -f configure.ac ]]; then
            autoreconf -fi
        fi
    fi

    ./configure \
        --prefix="$PREFIX" \
        --host="${TARGET_ARCH}-linux-gnu" \
        --disable-shared \
        --enable-static \
        "${configure_args[@]}"

    pmake
    make install
}

# Standard CMake build
build_cmake() {
    local src_dir="$1"
    shift
    local cmake_args=("$@")

    local build_dir="$src_dir/build"
    mkdir -p "$build_dir"
    cd "$build_dir"

    cmake "$src_dir" \
        "${CMAKE_TOOLCHAIN_ARGS[@]}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        "${cmake_args[@]}"

    cmake --build . -j"$JOBS"
    cmake --install .
}

# Standard Meson build
build_meson() {
    local src_dir="$1"
    shift
    local meson_args=("$@")

    local build_dir="$src_dir/build"

    meson setup "$build_dir" "$src_dir" \
        --prefix="$PREFIX" \
        --default-library=static \
        --cross-file="$REPO_ROOT/sysroots/meson-cross-$TARGET_DISTRO.ini" \
        "${meson_args[@]}"

    meson compile -C "$build_dir"
    meson install -C "$build_dir"
}

# Check if a library is already built
is_built() {
    local name="$1"
    local marker="$PREFIX/.built-$name"
    [[ -f "$marker" ]]
}

# Mark a library as built
mark_built() {
    local name="$1"
    local version="${2:-unknown}"
    local marker="$PREFIX/.built-$name"
    echo "$version" > "$marker"
    log_success "Marked $name as built (version: $version)"
}

# Wrapper to build a dependency only if not already built
build_if_needed() {
    local name="$1"
    local version="$2"
    local build_func="$3"

    if is_built "$name"; then
        log_info "Skipping $name (already built)"
        return 0
    fi

    log_info "Building $name $version..."

    if "$build_func"; then
        mark_built "$name" "$version"
        log_success "Built $name $version"
    else
        die "Failed to build $name"
    fi
}

# Check glibc symbol versions in a binary
check_glibc_symbols() {
    local binary="$1"
    local max_version="${2:-2.17}"

    log_info "Checking glibc symbols in $binary"

    local symbols
    symbols=$(objdump -T "$binary" 2>/dev/null | grep GLIBC_ | sed 's/.*GLIBC_//' | cut -d' ' -f1 | sort -V | uniq)

    local highest
    highest=$(echo "$symbols" | tail -1)

    if [[ -n "$highest" ]]; then
        log_info "Highest glibc version required: $highest"

        # Compare versions
        if [[ "$(printf '%s\n' "$max_version" "$highest" | sort -V | tail -1)" != "$max_version" ]]; then
            log_warn "Binary requires glibc $highest, which is newer than target $max_version"
            return 1
        fi
    fi

    log_success "glibc version check passed"
    return 0
}
