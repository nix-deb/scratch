#!/usr/bin/env bash
# Setup sysroots for cross-compilation
# Downloads minimal build-essential packages from Debian/Ubuntu archives
# SPDX-License-Identifier: LGPL-2.1-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$@"; exit 1; }

# Distribution configurations
# Format: CODENAME|MIRROR_URL|COMPONENTS|ARCH
declare -A DISTRO_CONFIG=(
    # Debian
    ["debian-stretch"]="stretch|http://archive.debian.org/debian|main|amd64"
    ["debian-buster"]="buster|http://archive.debian.org/debian|main|amd64"
    ["debian-bullseye"]="bullseye|http://deb.debian.org/debian|main|amd64"
    ["debian-bookworm"]="bookworm|http://deb.debian.org/debian|main|amd64"
    ["debian-trixie"]="trixie|http://deb.debian.org/debian|main|amd64"
    # Ubuntu
    ["ubuntu-xenial"]="xenial|http://archive.ubuntu.com/ubuntu|main|amd64"
    ["ubuntu-bionic"]="bionic|http://archive.ubuntu.com/ubuntu|main|amd64"
    ["ubuntu-focal"]="focal|http://archive.ubuntu.com/ubuntu|main|amd64"
    ["ubuntu-jammy"]="jammy|http://archive.ubuntu.com/ubuntu|main|amd64"
    ["ubuntu-noble"]="noble|http://archive.ubuntu.com/ubuntu|main|amd64"
)

# Packages needed for a minimal sysroot
# These provide glibc headers, kernel headers, and basic development files
SYSROOT_PACKAGES=(
    libc6            # Runtime library (needed for libc.so.6, ld-linux-x86-64.so.2)
    libc6-dev        # Development headers and static libs
    linux-libc-dev   # Kernel headers
)

# Additional packages that may be useful
EXTRA_PACKAGES=(
    libstdc++-dev    # May need version suffix on some distros
)

usage() {
    cat <<EOF
Usage: $0 DISTRO [--arch ARCH]

Setup a sysroot for cross-compilation targeting the specified distribution.

Arguments:
    DISTRO      Distribution identifier (e.g., debian-bookworm, ubuntu-noble)

Options:
    --arch      Target architecture (default: amd64)
    --list      List available distributions

Available distributions:
EOF
    for distro in "${!DISTRO_CONFIG[@]}"; do
        echo "    $distro"
    done | sort
}

# Parse configuration for a distro
parse_config() {
    local distro="$1"
    local config="${DISTRO_CONFIG[$distro]:-}"

    if [[ -z "$config" ]]; then
        die "Unknown distribution: $distro"
    fi

    IFS='|' read -r CODENAME MIRROR COMPONENTS ARCH <<< "$config"
}

# Download a .deb package
download_deb() {
    local url="$1"
    local output="$2"

    if [[ -f "$output" ]]; then
        return 0
    fi

    log_info "Downloading: $url"
    curl -fSL "$url" -o "$output.tmp"
    mv "$output.tmp" "$output"
}

# Extract a .deb package
extract_deb() {
    local deb="$1"
    local dest="$2"

    log_info "Extracting: $(basename "$deb")"

    # .deb files are ar archives containing data.tar.*
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN

    cd "$tmpdir"
    ar x "$deb"

    # Find and extract the data archive
    if [[ -f data.tar.xz ]]; then
        tar -xJf data.tar.xz -C "$dest"
    elif [[ -f data.tar.zst ]]; then
        tar --zstd -xf data.tar.zst -C "$dest"
    elif [[ -f data.tar.gz ]]; then
        tar -xzf data.tar.gz -C "$dest"
    elif [[ -f data.tar.bz2 ]]; then
        tar -xjf data.tar.bz2 -C "$dest"
    else
        die "Unknown data archive format in $deb"
    fi
}

# Fetch package list and find package URLs
get_package_url() {
    local mirror="$1"
    local codename="$2"
    local arch="$3"
    local package="$4"
    local packages_cache="$5"

    # Download and cache Packages file if needed
    if [[ ! -f "$packages_cache" ]]; then
        local packages_url="$mirror/dists/$codename/main/binary-$arch/Packages.gz"
        log_info "Fetching package list from $packages_url"
        curl -fSL "$packages_url" 2>/dev/null | gunzip > "$packages_cache" || {
            # Try xz format
            packages_url="$mirror/dists/$codename/main/binary-$arch/Packages.xz"
            curl -fSL "$packages_url" 2>/dev/null | xz -d > "$packages_cache" || {
                die "Failed to fetch package list"
            }
        }
    fi

    # Parse Packages file to find the package
    awk -v pkg="$package" '
        /^Package:/ { current = $2 }
        /^Filename:/ && current == pkg { print $2; exit }
    ' "$packages_cache"
}

# Setup sysroot for a distribution
setup_sysroot() {
    local distro="$1"
    local target_arch="${2:-amd64}"

    parse_config "$distro"

    local sysroot="$SCRIPT_DIR/$distro"
    local cache_dir="$SCRIPT_DIR/.cache/$distro"
    local packages_cache="$cache_dir/Packages"

    log_info "Setting up sysroot for $distro (arch: $target_arch)"

    mkdir -p "$sysroot"
    mkdir -p "$cache_dir"

    # Download and extract each package
    for pkg in "${SYSROOT_PACKAGES[@]}"; do
        local filename
        filename=$(get_package_url "$MIRROR" "$CODENAME" "$target_arch" "$pkg" "$packages_cache")

        if [[ -z "$filename" ]]; then
            log_info "Package $pkg not found, skipping"
            continue
        fi

        local url="$MIRROR/$filename"
        local deb="$cache_dir/$(basename "$filename")"

        download_deb "$url" "$deb"
        extract_deb "$deb" "$sysroot"
    done

    # Fix up symlinks that point to absolute paths
    # These need to be relative or point within the sysroot
    log_info "Fixing symlinks..."
    find "$sysroot" -type l | while read -r link; do
        local target
        target=$(readlink "$link")

        # If it's an absolute path, make it relative to sysroot
        if [[ "$target" == /* ]]; then
            local link_dir
            link_dir=$(dirname "$link")
            local rel_sysroot
            rel_sysroot=$(realpath --relative-to="$link_dir" "$sysroot")

            # Remove leading / from target and prepend relative sysroot path
            local new_target="$rel_sysroot${target}"
            ln -sf "$new_target" "$link"
        fi
done

    # Create standard directory structure if missing
    mkdir -p "$sysroot/usr/lib"
    mkdir -p "$sysroot/usr/include"
    mkdir -p "$sysroot/usr/bin"

    # Normalize sysroot layout (merged-usr style)
    log_info "Normalizing sysroot layout..."

    # Ensure /usr/lib64 exists
    mkdir -p "$sysroot/usr/lib64"

    # Create /lib64 -> usr/lib64 symlink
    if [[ -d "$sysroot/lib64" && ! -L "$sysroot/lib64" ]]; then
        cp -a "$sysroot/lib64/"* "$sysroot/usr/lib64/" 2>/dev/null || true
        rm -rf "$sysroot/lib64"
    fi
    [[ ! -e "$sysroot/lib64" ]] && ln -sf usr/lib64 "$sysroot/lib64"

    # Create /lib -> usr/lib symlink
    if [[ -d "$sysroot/lib" && ! -L "$sysroot/lib" ]]; then
        cp -a "$sysroot/lib/"* "$sysroot/usr/lib/" 2>/dev/null || true
        rm -rf "$sysroot/lib"
    fi
    [[ ! -e "$sysroot/lib" ]] && ln -sf usr/lib "$sysroot/lib"

    # Ensure the dynamic linker is accessible at /lib64/ld-linux-x86-64.so.2
    # The libc.so linker script references this absolute path
    if [[ -f "$sysroot/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" ]]; then
        ln -sf ../lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 "$sysroot/usr/lib64/ld-linux-x86-64.so.2"
    elif [[ -f "$sysroot/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" ]]; then
        ln -sf ../lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 "$sysroot/usr/lib64/ld-linux-x86-64.so.2"
    fi

    log_success "Sysroot created at $sysroot"

    # Generate meson cross file
    generate_meson_cross_file "$distro" "$target_arch"
}

# Generate a Meson cross-compilation file
generate_meson_cross_file() {
    local distro="$1"
    local arch="$2"
    local sysroot="$SCRIPT_DIR/$distro"
    local cross_file="$SCRIPT_DIR/meson-cross-$distro.ini"

    local cpu_family
    local cpu
    case "$arch" in
        amd64|x86_64) cpu_family="x86_64"; cpu="x86_64" ;; 
        arm64|aarch64) cpu_family="aarch64"; cpu="aarch64" ;; 
        *) cpu_family="$arch"; cpu="$arch" ;; 
    esac

    cat > "$cross_file" <<EOF
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['--sysroot=$sysroot', '-I$REPO_ROOT/out/$distro/prefix/include']
cpp_args = ['--sysroot=$sysroot', '-I$REPO_ROOT/out/$distro/prefix/include']
c_link_args = ['--sysroot=$sysroot', '-L$REPO_ROOT/out/$distro/prefix/lib']
cpp_link_args = ['--sysroot=$sysroot', '-L$REPO_ROOT/out/$distro/prefix/lib']

[properties]
sys_root = '$sysroot'
pkg_config_libdir = '$REPO_ROOT/out/$distro/prefix/lib/pkgconfig'

[host_machine]
system = 'linux'
cpu_family = '$cpu_family'
cpu = '$cpu'
endian = 'little'
EOF

    log_info "Generated Meson cross file: $cross_file"
}

# List available distributions
list_distros() {
    echo "Available distributions:"
    for distro in "${!DISTRO_CONFIG[@]}"; do
        IFS='|' read -r codename mirror _ _ <<< "${DISTRO_CONFIG[$distro]}"
        printf "  %-20s (%s)\n" "$distro" "$codename"
    done | sort
}

# Main
TARGET_ARCH="amd64"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            TARGET_ARCH="$2"
            shift 2
            ;; 
        --list)
            list_distros
            exit 0
            ;; 
        -h|--help)
            usage
            exit 0
            ;; 
        -*)
            die "Unknown option: $1"
            ;; 
        *)
            DISTRO="$1"
            shift
            ;; 
    esac
done

if [[ -z "${DISTRO:-}" ]]; then
    usage
    exit 1
fi

setup_sysroot "$DISTRO" "$TARGET_ARCH"