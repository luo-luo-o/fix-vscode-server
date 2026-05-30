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

DEFAULT_BASE_URL="https://raw.githubusercontent.com/YOUR_GITHUB_USER/fix-vscode-server/master"
BASE_URL="${FIX_VSCODE_SERVER_BASE_URL:-$DEFAULT_BASE_URL}"
BASE_URL="${BASE_URL%/}"

is_container() {
    if [ -n "${FIX_VSCODE_SERVER_FORCE_CONTAINER:-}" ]; then
        return 0
    fi

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

script_dir() {
    local source="${BASH_SOURCE[0]:-}"

    case "$source" in
        ""|-|/dev/fd/*|/proc/self/fd/*)
            return 1
            ;;
    esac

    if [ -L "$source" ] && command -v readlink >/dev/null 2>&1; then
        source="$(readlink -f "$source" 2>/dev/null || printf '%s' "$source")"
    fi

    [ -f "$source" ] || return 1
    cd -P -- "$(dirname -- "$source")" >/dev/null 2>&1 && pwd -P
}

download_helpers() {
    local temp_dir="$1"
    local script
    local url

    if ! command -v curl >/dev/null 2>&1; then
        log_err "curl is required when helper scripts are not available locally."
    fi

    if [[ "$BASE_URL" == *"YOUR_GITHUB_USER"* ]]; then
        log_err "Helper scripts were not found locally. Set FIX_VSCODE_SERVER_BASE_URL to your raw GitHub directory URL."
    fi

    for script in fix-vscode-server-ssh.sh fix-vscode-server-devcontainer.sh; do
        url="$BASE_URL/$script"
        log_info "Downloading $script"
        curl -fsSL "$url" -o "$temp_dir/$script" || log_err "Failed to download $url"
    done
}

if is_container; then
    MODE="devcontainer"
    TARGET_SCRIPT="fix-vscode-server-devcontainer.sh"
else
    MODE="ssh"
    TARGET_SCRIPT="fix-vscode-server-ssh.sh"
fi

log_info "Detected $MODE environment; using $TARGET_SCRIPT"

if LOCAL_DIR="$(script_dir)"; then
    if [ -f "$LOCAL_DIR/$TARGET_SCRIPT" ]; then
        exec bash "$LOCAL_DIR/$TARGET_SCRIPT" "$@"
    fi

    log_warn "$TARGET_SCRIPT was not found next to fix-vscode-server.sh"
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

download_helpers "$TEMP_DIR"
bash "$TEMP_DIR/$TARGET_SCRIPT" "$@"
