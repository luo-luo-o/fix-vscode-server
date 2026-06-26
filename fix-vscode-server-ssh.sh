#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$1"; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1"; }
log_err() {
    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1" >&2
    exit 1
}

OS_ID="unknown"
OS_VERSION_ID="unknown"
OS_PRETTY_NAME="unknown"
CPP_SYMBOL_REQUIRED="GLIBCXX_3.4.26"
CPP_RUNTIME_PATCHED=false

SUDO=""
if [ "$EUID" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

if [ "$EUID" -eq 0 ]; then
    log_err "Do not run the SSH repair script as root. Run it as the target SSH user with sudo privileges."
fi

apt_package_for_tool() {
    case "$1" in
        ar|strings)
            printf '%s\n' "binutils"
            ;;
        basename|cat|chmod|chown|cp|dirname|ln|mkdir|mktemp|rm|sleep|sort|tail|tee|touch|true|uname|whoami)
            printf '%s\n' "coreutils"
            ;;
        find)
            printf '%s\n' "findutils"
            ;;
        xz)
            printf '%s\n' "xz-utils"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

load_os_release() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION_ID="${VERSION_ID:-unknown}"
        OS_PRETTY_NAME="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
    fi
}

extract_deb_payload() {
    local deb_path="$1"
    local target_dir="$2"

    mkdir -p "$target_dir"
    (
        cd "$target_dir"
        ar x "$deb_path"
        if [ -f data.tar.zst ]; then
            zstd -d data.tar.zst
            tar -xf data.tar
        elif [ -f data.tar.xz ]; then
            tar -xf data.tar.xz
        else
            log_err "Expected data.tar.zst or data.tar.xz was not found in $deb_path."
        fi
    )
}

join_words() {
    local IFS=' '
    printf '%s' "$*"
}

package_in_list() {
    local package="$1"
    local existing

    shift
    for existing in "$@"; do
        [ "$existing" = "$package" ] && return 0
    done

    return 1
}

apt_install_packages() {
    if [ -n "$SUDO" ]; then
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    fi
}

ensure_required_tools() {
    local missing_tools=()
    local missing_packages=()
    local package
    local tool

    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            package="$(apt_package_for_tool "$tool")"
            missing_tools+=("$tool")

            if ! package_in_list "$package" "${missing_packages[@]}"; then
                missing_packages+=("$package")
            fi
        fi
    done

    if [ "${#missing_packages[@]}" -eq 0 ]; then
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        log_err "Missing required tools ($(join_words "${missing_tools[@]}")), and apt-get was not found."
    fi

    if [ "$EUID" -ne 0 ] && [ -z "$SUDO" ]; then
        log_err "Missing required tools ($(join_words "${missing_tools[@]}")), and sudo was not found."
    fi

    log_warn "Missing required tools: $(join_words "${missing_tools[@]}")"
    log_warn "Installing packages with apt-get: $(join_words "${missing_packages[@]}")"
    $SUDO apt-get update && apt_install_packages "${missing_packages[@]}" ||
        log_err "Failed to install required packages. Check network access and apt sources."
}

find_system_libstdcpp() {
    find /usr/lib /lib -name 'libstdc++.so.6' -print -quit 2>/dev/null
}

system_libstdcpp_needs_patch() {
    local libstdcpp_path

    libstdcpp_path="$(find_system_libstdcpp)"
    if [ -z "$libstdcpp_path" ]; then
        log_warn "System libstdc++.so.6 was not found; enabling C++ runtime patch."
        return 0
    fi

    if strings "$libstdcpp_path" 2>/dev/null | grep -Fq "$CPP_SYMBOL_REQUIRED"; then
        return 1
    fi

    log_warn "System libstdc++.so.6 at $libstdcpp_path does not provide $CPP_SYMBOL_REQUIRED."
    return 0
}

select_cpp_runtime_source() {
    case "$ARCH" in
        x86_64)
            CPP_REPO_BASE="http://mirrors.kernel.org/ubuntu/pool/main/g"
            CPP_DEB_ARCH="amd64"
            ;;
        aarch64)
            CPP_REPO_BASE="http://ports.ubuntu.com/ubuntu-ports/pool/main/g"
            CPP_DEB_ARCH="arm64"
            ;;
        armv7l|armv6l)
            CPP_REPO_BASE="http://ports.ubuntu.com/ubuntu-ports/pool/main/g"
            CPP_DEB_ARCH="armhf"
            ;;
        *)
            log_err "Unsupported architecture for C++ runtime patch: $ARCH"
            ;;
    esac
}

pick_cpp_runtime_deb() {
    local repo_dir="$1"
    local package_prefix="$2"

    curl -fsSL "$repo_dir/" |
        grep -oE "${package_prefix}_[^\"<> ]+_${CPP_DEB_ARCH}\\.deb" |
        sort -Vu |
        tail -n1
}

patch_cpp_runtime() {
    local gcc_dir
    local libgcc_deb=""
    local libgcc_path=""
    local libstdcpp_deb=""
    local libstdcpp_path=""
    local repo_dir=""

    select_cpp_runtime_source

    for gcc_dir in gcc-12 gcc-11 gcc-10 gcc-9; do
        repo_dir="$CPP_REPO_BASE/$gcc_dir"
        libstdcpp_deb="$(pick_cpp_runtime_deb "$repo_dir" 'libstdc\+\+6' || true)"
        libgcc_deb="$(pick_cpp_runtime_deb "$repo_dir" 'libgcc(-s1|1)' || true)"
        if [ -n "$libstdcpp_deb" ] && [ -n "$libgcc_deb" ]; then
            break
        fi
    done

    [ -n "$libstdcpp_deb" ] || log_err "Failed to locate libstdc++6 package for $ARCH."
    [ -n "$libgcc_deb" ] || log_err "Failed to locate libgcc package for $ARCH."

    log_warn "Applying C++ runtime patch for $OS_PRETTY_NAME on $ARCH."
    log_info "Downloading libstdc++6 package: $libstdcpp_deb"
    curl -fL -o "$TEMP_DIR/libstdcpp.deb" "$repo_dir/$libstdcpp_deb" ||
        log_err "Failed to download $repo_dir/$libstdcpp_deb"
    log_info "Downloading libgcc package: $libgcc_deb"
    curl -fL -o "$TEMP_DIR/libgcc.deb" "$repo_dir/$libgcc_deb" ||
        log_err "Failed to download $repo_dir/$libgcc_deb"

    extract_deb_payload "$TEMP_DIR/libstdcpp.deb" "$TEMP_DIR/libstdcpp"
    extract_deb_payload "$TEMP_DIR/libgcc.deb" "$TEMP_DIR/libgcc"

    libstdcpp_path="$(find "$TEMP_DIR/libstdcpp" -name 'libstdc++.so.6*' -type f | sort | tail -n1)"
    [ -n "$libstdcpp_path" ] || log_err "Failed to find libstdc++.so.6 in $libstdcpp_deb"
    libgcc_path="$(find "$TEMP_DIR/libgcc" -name 'libgcc_s.so.1' -type f -print -quit)"
    [ -n "$libgcc_path" ] || log_err "Failed to find libgcc_s.so.1 in $libgcc_deb"

    $SUDO cp -f "$libstdcpp_path" "$PATCH_DIR/$(basename "$libstdcpp_path")"
    $SUDO ln -sfn "$PATCH_DIR/$(basename "$libstdcpp_path")" "$PATCH_DIR/libstdc++.so.6"
    $SUDO cp -f "$libgcc_path" "$PATCH_DIR/libgcc_s.so.1"

    if strings "$PATCH_DIR/libstdc++.so.6" 2>/dev/null | grep -Fq "$CPP_SYMBOL_REQUIRED"; then
        CPP_RUNTIME_PATCHED=true
        log_info "C++ runtime patch provides $CPP_SYMBOL_REQUIRED."
    else
        log_err "Patched libstdc++.so.6 still does not provide $CPP_SYMBOL_REQUIRED."
    fi
}

log_info "Checking SSH host environment..."

ARCH="$(uname -m)"
load_os_release
GLIBC_VER="2.35"
PATCH_DIR="/opt/vscode_glibc_patch/lib"
log_info "Detected host: $OS_PRETTY_NAME ($ARCH)"

case "$ARCH" in
    x86_64)
        URL="http://mirrors.kernel.org/ubuntu/pool/main/g/glibc/libc6_2.35-0ubuntu3_amd64.deb"
        LINKER_NAME="ld-linux-x86-64.so.2"
        ;;
    aarch64)
        URL="http://ports.ubuntu.com/pool/main/g/glibc/libc6_2.35-0ubuntu3_arm64.deb"
        LINKER_NAME="ld-linux-aarch64.so.1"
        ;;
    armv7l|armv6l)
        URL="http://ports.ubuntu.com/pool/main/g/glibc/libc6_2.35-0ubuntu3_armhf.deb"
        LINKER_NAME="ld-linux-armhf.so.3"
        ;;
    *)
        log_err "Unsupported architecture: $ARCH"
        ;;
esac

REQUIRED_TOOLS=(
    "curl"
    "ar"
    "zstd"
    "xz"
    "patchelf"
    "tar"
    "find"
    "grep"
    "sed"
    "tee"
    "basename"
    "cat"
    "chmod"
    "chown"
    "cp"
    "dirname"
    "ln"
    "mkdir"
    "mktemp"
    "rm"
    "sleep"
    "sort"
    "strings"
    "tail"
    "true"
    "uname"
    "whoami"
)
ensure_required_tools

log_info "Preparing GLIBC patch directory: $PATCH_DIR"
$SUDO mkdir -p "$PATCH_DIR" || log_err "Failed to create $PATCH_DIR"
$SUDO chown -R "$(whoami):$(whoami)" /opt/vscode_glibc_patch 2>/dev/null || true

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
cd "$TEMP_DIR"

log_info "Downloading GLIBC $GLIBC_VER package..."
MAX_RETRIES=3
COUNT=0
SUCCESS=false
while [ "$COUNT" -lt "$MAX_RETRIES" ]; do
    if curl -L -f -o libc6.deb "$URL"; then
        SUCCESS=true
        break
    fi

    COUNT=$((COUNT + 1))
    log_warn "Download failed; retrying ($COUNT/$MAX_RETRIES)..."
    sleep 2
done

[ "$SUCCESS" = true ] || log_err "Failed to download GLIBC package."

log_info "Extracting GLIBC libraries..."
extract_deb_payload "$TEMP_DIR/libc6.deb" "$TEMP_DIR/glibc"

cd "$TEMP_DIR/glibc"

LINKER_FILE="$(find . -name "$LINKER_NAME" -print -quit)"
[ -n "$LINKER_FILE" ] || log_err "Could not find linker $LINKER_NAME in extracted package."
LIB_SRC="$(dirname "$LINKER_FILE")"

$SUDO cp -r "$LIB_SRC"/* "$PATCH_DIR/"
log_info "Copied GLIBC libraries to $PATCH_DIR"

PATCHELF_BIN="$(command -v patchelf)"
LINKER_PATH="$PATCH_DIR/$LINKER_NAME"
LINKER_ALIAS="$PATCH_DIR/ld-vscode-server.so"

[ -x "$LINKER_PATH" ] || log_err "Linker is missing or not executable: $LINKER_PATH"
$SUDO ln -sfn "$LINKER_PATH" "$LINKER_ALIAS" ||
    log_err "Failed to create stable linker alias: $LINKER_ALIAS"

if "$LINKER_PATH" --library-path "$PATCH_DIR" /bin/true; then
    log_info "Patched linker validation passed."
else
    log_err "Patched linker could not start /bin/true."
fi

if system_libstdcpp_needs_patch; then
    patch_cpp_runtime
else
    log_info "System libstdc++.so.6 already provides $CPP_SYMBOL_REQUIRED; skipping C++ runtime patch."
fi

log_info "Configuring SSH environment injection..."
if [ -f /etc/ssh/sshd_config ]; then
    if ! grep -Eq '^[[:space:]]*PermitUserEnvironment[[:space:]]+yes([[:space:]]|$)' /etc/ssh/sshd_config; then
        log_warn "Enabling PermitUserEnvironment in /etc/ssh/sshd_config..."
        $SUDO sed -i 's/^[[:space:]]*#\?[[:space:]]*PermitUserEnvironment[[:space:]]\+no/PermitUserEnvironment yes/' /etc/ssh/sshd_config

        if ! grep -Eq '^[[:space:]]*PermitUserEnvironment[[:space:]]+yes([[:space:]]|$)' /etc/ssh/sshd_config; then
            printf '\nPermitUserEnvironment yes\n' | $SUDO tee -a /etc/ssh/sshd_config >/dev/null
        fi

        $SUDO systemctl restart ssh ||
            log_warn "SSH restart failed. Restart it manually with: sudo systemctl restart ssh"
    fi
else
    log_warn "/etc/ssh/sshd_config was not found; skipping SSH daemon configuration."
fi

mkdir -p "$HOME/.ssh"
cat >"$HOME/.ssh/environment" <<EOF
VSCODE_SERVER_CUSTOM_GLIBC_PATH=$PATCH_DIR
VSCODE_SERVER_PATCHELF_PATH=$PATCHELF_BIN
VSCODE_SERVER_CUSTOM_GLIBC_LINKER=$LINKER_ALIAS
EOF
chmod 600 "$HOME/.ssh/environment"
log_info "Wrote SSH user environment to $HOME/.ssh/environment"

log_info "Removing old VS Code Server cache..."
rm -rf "$HOME/.vscode-server"

log_info "------------------------------------------------"
log_info "SSH repair completed successfully."
log_info "Host: $OS_PRETTY_NAME"
log_info "Architecture: $ARCH"
log_info "GLIBC patch directory: $PATCH_DIR"
log_info "Patchelf: $PATCHELF_BIN"
log_info "Linker: $LINKER_ALIAS"
if [ "$CPP_RUNTIME_PATCHED" = true ]; then
    log_info "C++ runtime patch: enabled"
else
    log_info "C++ runtime patch: not needed"
fi
log_info "Reconnect from VS Code and click Retry if prompted."
log_info "------------------------------------------------"
