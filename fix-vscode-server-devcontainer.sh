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

has_container_marker() {
    if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
        return 0
    fi

    if grep -qaE 'docker|kubepods|containerd|libpod|podman' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi

    if [ -n "${REMOTE_CONTAINERS:-}" ] || [ -n "${VSCODE_REMOTE_CONTAINERS_SESSION:-}" ] || [ -n "${DEVCONTAINER:-}" ]; then
        return 0
    fi

    return 1
}

if [ -z "${FIX_VSCODE_SERVER_DOCKERFILE_BUILD:-}" ]; then
    if ! has_container_marker; then
        log_err "Use fix-vscode-server.sh on SSH hosts, or set FIX_VSCODE_SERVER_DOCKERFILE_BUILD=1 in a Dockerfile RUN step."
    fi

    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "Do not repair an already-created container from inside the container." >&2
    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "Please add the Dockerfile build-time repair block, rebuild the image, and recreate the container." >&2
    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "不要在已经创建好的容器内部执行修复。" >&2
    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "请修改 Dockerfile，加入构建时修复步骤，然后重新构建镜像并重建容器。" >&2
    exit 1
fi

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

apt_package_for_tool() {
    case "$1" in
        ar)
            printf '%s\n' "binutils"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

log_info "Checking Dev Container environment..."

ARCH="$(uname -m)"
GLIBC_VER="2.31"
PATCH_DIR="/opt/vscode_glibc_patch/lib"

case "$ARCH" in
    x86_64)
        URL="http://mirrors.kernel.org/ubuntu/pool/main/g/glibc/libc6_2.31-0ubuntu9_amd64.deb"
        LINKER_NAME="ld-linux-x86-64.so.2"
        ;;
    aarch64)
        URL="http://mirrors.kernel.org/ubuntu/pool/main/g/glibc/libc6_2.31-0ubuntu9_arm64.deb"
        LINKER_NAME="ld-linux-aarch64.so.1"
        ;;
    armv7l|armv6l)
        URL="http://mirrors.kernel.org/ubuntu/pool/main/g/glibc/libc6_2.31-0ubuntu9_armhf.deb"
        LINKER_NAME="ld-linux-armhf.so.3"
        ;;
    *)
        log_err "Unsupported architecture: $ARCH"
        ;;
esac

REQUIRED_TOOLS=("curl" "ar" "zstd" "patchelf" "tar")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        package="$(apt_package_for_tool "$tool")"
        log_warn "Missing tool $tool; installing package $package with apt-get..."
        $SUDO apt-get update && $SUDO apt-get install -y "$package" ||
            log_err "Failed to install package $package for tool $tool. Check network access and apt sources."
    fi
done

log_info "Preparing GLIBC patch directory: $PATCH_DIR"
$SUDO mkdir -p "$PATCH_DIR" || log_err "Failed to create $PATCH_DIR"

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
ar x libc6.deb || log_err "Failed to unpack DEB package with ar."

if [ -f data.tar.zst ]; then
    zstd -d data.tar.zst && tar -xf data.tar
elif [ -f data.tar.xz ]; then
    tar -xf data.tar.xz
else
    log_err "Expected data.tar.zst or data.tar.xz was not found."
fi

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

TARGET_RC="$HOME/.bashrc"
if [ -n "${SHELL:-}" ] && [[ "$SHELL" == *"zsh"* ]]; then
    TARGET_RC="$HOME/.zshrc"
elif [ -f "$HOME/.zshrc" ]; then
    TARGET_RC="$HOME/.zshrc"
fi

BLOCK_MARKER="# === VSCODE_GLIBC_PATCH_MARKER ==="
if [ -f "$TARGET_RC" ]; then
    sed -i "/$BLOCK_MARKER/,/$BLOCK_MARKER/d" "$TARGET_RC"
fi

cat <<EOF >>"$TARGET_RC"
# === VSCODE_GLIBC_PATCH_MARKER ===
# VS Code Server custom glibc sysroot.
export VSCODE_SERVER_CUSTOM_GLIBC_PATH="$PATCH_DIR"
export VSCODE_SERVER_PATCHELF_PATH="$PATCHELF_BIN"
export VSCODE_SERVER_CUSTOM_GLIBC_LINKER="$LINKER_ALIAS"
# === VSCODE_GLIBC_PATCH_MARKER ===
EOF

$SUDO tee /etc/profile.d/vscode-glibc-patch.sh >/dev/null <<EOF
# VS Code Server custom glibc sysroot.
export VSCODE_SERVER_CUSTOM_GLIBC_PATH="$PATCH_DIR"
export VSCODE_SERVER_PATCHELF_PATH="$PATCHELF_BIN"
export VSCODE_SERVER_CUSTOM_GLIBC_LINKER="$LINKER_ALIAS"
EOF
$SUDO chmod 644 /etc/profile.d/vscode-glibc-patch.sh

$SUDO touch /etc/environment 2>/dev/null || true
if [ -f /etc/environment ]; then
    $SUDO sed -i \
        -e '/^VSCODE_SERVER_CUSTOM_GLIBC_PATH=/d' \
        -e '/^VSCODE_SERVER_PATCHELF_PATH=/d' \
        -e '/^VSCODE_SERVER_CUSTOM_GLIBC_LINKER=/d' \
        /etc/environment 2>/dev/null || true
    printf '%s\n' \
        "VSCODE_SERVER_CUSTOM_GLIBC_PATH=$PATCH_DIR" \
        "VSCODE_SERVER_PATCHELF_PATH=$PATCHELF_BIN" \
        "VSCODE_SERVER_CUSTOM_GLIBC_LINKER=$LINKER_ALIAS" |
        $SUDO tee -a /etc/environment >/dev/null || true
fi

log_info "Wrote Dev Container environment files."
log_info "Interactive shells are not configured with LD_LIBRARY_PATH, so system commands keep using the system GLIBC."
log_warn "For Dockerfile-built images, also set these Dockerfile ENV values before creating containers:"
log_warn "  ENV VSCODE_SERVER_CUSTOM_GLIBC_PATH=$PATCH_DIR \\"
log_warn "      VSCODE_SERVER_PATCHELF_PATH=$PATCHELF_BIN \\"
log_warn "      VSCODE_SERVER_CUSTOM_GLIBC_LINKER=$LINKER_ALIAS"

log_info "Removing old VS Code Server cache..."
rm -rf "$HOME/.vscode-server"

log_info "------------------------------------------------"
log_info "Dev Container repair completed successfully."
log_info "Architecture: $ARCH"
log_info "GLIBC patch directory: $PATCH_DIR"
log_info "Patchelf: $PATCHELF_BIN"
log_info "Linker: $LINKER_ALIAS"
log_info "For VS Code Attach, rebuild the image with the printed Dockerfile ENV values before creating containers."
log_info "------------------------------------------------"
