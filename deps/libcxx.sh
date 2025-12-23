#!/usr/bin/env bash
# Build LLVM C++ runtime libraries (Tier 0 - no dependencies)
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Builds libunwind, libc++abi, and libc++ from LLVM source.
# These replace the pre-built LLVM runtime libraries which require glibc 2.34+.
# Building from source ensures compatibility with older glibc versions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

NAME="libcxx"
VERSION="21.1.8"
URL="https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-${VERSION}.tar.gz"

# Custom fetch that extracts only needed directories (~50MB vs ~2GB full tarball)
fetch_llvm_runtimes() {
    local archive="$SOURCE_DIR/llvmorg-${VERSION}.tar.gz"
    local src_dir="$BUILD_DIR/llvm-project-llvmorg-${VERSION}"

    # Download if needed
    download "$URL" "$archive"

    # Extract only runtime directories
    if [[ ! -d "$src_dir/libcxx" ]]; then
        log_info "Extracting LLVM runtime sources (selective extraction)..."
        mkdir -p "$src_dir"
        tar -xzf "$archive" -C "$BUILD_DIR" \
            "llvm-project-llvmorg-${VERSION}/libunwind" \
            "llvm-project-llvmorg-${VERSION}/libcxxabi" \
            "llvm-project-llvmorg-${VERSION}/libcxx" \
            "llvm-project-llvmorg-${VERSION}/cmake" \
            "llvm-project-llvmorg-${VERSION}/runtimes"
        log_success "Extracted LLVM runtime sources"
    fi

    echo "$src_dir"
}

build_libcxx() {
    local src_dir
    src_dir=$(fetch_llvm_runtimes)

    # IMPORTANT: Remove -stdlib=libc++ from flags when building libc++ itself
    # This is a bootstrap situation - we can't use libc++ to build libc++!
    # The LLVM runtime build system handles stdlib internally.
    local saved_cxxflags="$CXXFLAGS"
    local saved_ldflags="$LDFLAGS"
    export CXXFLAGS="${CXXFLAGS//-stdlib=libc++/}"
    export LDFLAGS="${LDFLAGS//-stdlib=libc++/}"
    # Also remove the LLVM lib path since we don't want to link against pre-built libc++
    export LDFLAGS="${LDFLAGS//-L$LLVM_ROOT\/lib\/x86_64-unknown-linux-gnu/}"

    # Skip CMake's C++ compiler check - it will fail because there's no C++ stdlib yet
    # This is safe because we know clang works, we just don't have runtime libs
    local skip_cxx_check="-DCMAKE_CXX_COMPILER_WORKS=ON"

    # 1. Build libunwind (no dependencies)
    log_info "Building libunwind..."
    build_cmake "$src_dir/libunwind" \
        $skip_cxx_check \
        -DLIBUNWIND_ENABLE_SHARED=OFF \
        -DLIBUNWIND_ENABLE_STATIC=ON \
        -DLIBUNWIND_USE_COMPILER_RT=ON \
        -DLIBUNWIND_INSTALL_HEADERS=ON

    # 2. Build libc++abi (depends on libunwind)
    log_info "Building libc++abi..."
    build_cmake "$src_dir/libcxxabi" \
        $skip_cxx_check \
        -DLIBCXXABI_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_STATIC=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXXABI_USE_COMPILER_RT=ON \
        -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON \
        -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=ON \
        -DLIBCXXABI_LIBUNWIND_INCLUDES="$PREFIX/include" \
        -DLIBCXXABI_INSTALL_HEADERS=ON

    # 3. Build libc++ (depends on libc++abi)
    log_info "Building libc++..."
    build_cmake "$src_dir/libcxx" \
        $skip_cxx_check \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXX_ENABLE_STATIC=ON \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXX_USE_COMPILER_RT=ON \
        -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
        -DLIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY=ON \
        -DLIBCXX_CXX_ABI_INCLUDE_PATHS="$PREFIX/include" \
        -DLIBCXX_CXX_ABI_LIBRARY_PATH="$PREFIX/lib" \
        -DLIBCXX_INCLUDE_TESTS=OFF \
        -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
        -DLIBCXX_INSTALL_HEADERS=ON

    # Restore original flags
    export CXXFLAGS="$saved_cxxflags"
    export LDFLAGS="$saved_ldflags"
}

setup_paths
setup_clang
build_if_needed "$NAME" "$VERSION" build_libcxx
