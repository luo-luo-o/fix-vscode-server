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

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

if [ "$(id -u)" -eq 0 ]; then
    log_err "Do not run the SSH repair script as root. Run it as the target SSH user with sudo privileges."
fi

log_info "Checking SSH host environment..."

ARCH="$(uname -m)"
GLIBC_VER="2.35"
PATCH_DIR="/opt/vscode_glibc_patch/lib"

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

REQUIRED_TOOLS=("curl" "ar" "zstd" "patchelf" "tar")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_warn "Missing tool $tool; installing it with apt-get..."
        $SUDO apt-get update && $SUDO apt-get install -y "$tool" ||
            log_err "Failed to install $tool. Check network access and apt sources."
    fi
done

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
log_info "Architecture: $ARCH"
log_info "GLIBC patch directory: $PATCH_DIR"
log_info "Patchelf: $PATCHELF_BIN"
log_info "Linker: $LINKER_ALIAS"
log_info "Reconnect from VS Code and click Retry if prompted."
log_info "------------------------------------------------"
