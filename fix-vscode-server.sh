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

DEFAULT_GITHUB_BASE_URL="https://raw.githubusercontent.com/luo-luo-o/fix-vscode-server/main"
DEFAULT_GITEE_BASE_URL="https://gitee.com/Hluoluoo/fix-vscode-server/raw/main"
SOURCE_CONNECT_TIMEOUT="${FIX_VSCODE_SERVER_SOURCE_CONNECT_TIMEOUT:-2}"
SOURCE_MAX_TIME="${FIX_VSCODE_SERVER_SOURCE_MAX_TIME:-5}"
BASE_URL=""
SOURCE_NAME=""
REQUESTED_MODE="auto"
MODE_WAS_SET=false

has_dockerfile_build_flag() {
    [ -n "${FIX_VSCODE_SERVER_DOCKERFILE_BUILD:-}" ]
}

is_container_marker() {
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

container_rebuild_error() {
    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "Do not repair an already-created container from inside the container." >&2
    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "Please add the Dockerfile build-time repair block, rebuild the image, and recreate the container." >&2
    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "不要在已经创建好的容器内部执行修复。" >&2
    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "请修改 Dockerfile，加入构建时修复步骤，然后重新构建镜像并重建容器。" >&2
    exit 1
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

download_helper() {
    local temp_dir="$1"
    local script="$2"
    local fallback_base_url
    local url

    if ! command -v curl >/dev/null 2>&1; then
        log_err "curl is required when helper scripts are not available locally."
    fi

    url="$BASE_URL/$script"
    log_info "Downloading $script from $SOURCE_NAME"
    if curl -fsSL "$url" -o "$temp_dir/$script"; then
        return 0
    fi

    fallback_base_url="${FIX_VSCODE_SERVER_GITEE_BASE_URL:-$DEFAULT_GITEE_BASE_URL}"
    fallback_base_url="${fallback_base_url%/}"
    if [ -n "${FIX_VSCODE_SERVER_BASE_URL:-}" ] || [ "$BASE_URL" = "$fallback_base_url" ]; then
        log_err "Failed to download $url"
    fi

    url="$fallback_base_url/$script"
    log_warn "Download from GitHub failed; retrying from Gitee."
    curl -fsSL "$url" -o "$temp_dir/$script" || log_err "Failed to download $url"
}

select_download_source() {
    local script="$1"
    local github_base_url
    local gitee_base_url
    local probe_time

    if [ -n "${FIX_VSCODE_SERVER_BASE_URL:-}" ]; then
        BASE_URL="${FIX_VSCODE_SERVER_BASE_URL%/}"
        SOURCE_NAME="custom source"
        log_info "Using download source from FIX_VSCODE_SERVER_BASE_URL: $BASE_URL"
        return 0
    fi

    github_base_url="${FIX_VSCODE_SERVER_GITHUB_BASE_URL:-$DEFAULT_GITHUB_BASE_URL}"
    gitee_base_url="${FIX_VSCODE_SERVER_GITEE_BASE_URL:-$DEFAULT_GITEE_BASE_URL}"
    github_base_url="${github_base_url%/}"
    gitee_base_url="${gitee_base_url%/}"

    log_info "Probing GitHub download source..."
    if probe_time="$(curl -fsSL -o /dev/null -w '%{time_total}' \
        --connect-timeout "$SOURCE_CONNECT_TIMEOUT" \
        --max-time "$SOURCE_MAX_TIME" \
        "$github_base_url/$script" 2>/dev/null)"; then
        BASE_URL="$github_base_url"
        SOURCE_NAME="GitHub ($BASE_URL, probe ${probe_time}s)"
        return 0
    fi

    BASE_URL="$gitee_base_url"
    SOURCE_NAME="Gitee ($BASE_URL)"
    log_warn "GitHub source is unreachable or slower than ${SOURCE_MAX_TIME}s; using Gitee."
}

usage() {
    cat <<EOF
Usage:
  bash fix-vscode-server.sh [--ssh|--devcontainer]

Modes:
  --ssh                 Repair a Remote SSH host.
  --devcontainer        Repair a Docker/Dev Container image during Dockerfile build.
  -h, --help                  Show this help.

Without explicit mode:
  - Dockerfile builds with FIX_VSCODE_SERVER_DOCKERFILE_BUILD=1 use Dev Container repair.
  - Normal hosts use SSH repair.
  - Already-created containers are not repaired in place; rebuild the image instead.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --ssh)
                if [ "$MODE_WAS_SET" = true ] && [ "$REQUESTED_MODE" != "ssh" ]; then
                    log_err "--ssh cannot be combined with --devcontainer."
                fi
                REQUESTED_MODE="ssh"
                MODE_WAS_SET=true
                ;;
            --devcontainer)
                if [ "$MODE_WAS_SET" = true ] && [ "$REQUESTED_MODE" != "devcontainer" ]; then
                    log_err "--devcontainer cannot be combined with --ssh."
                fi
                REQUESTED_MODE="devcontainer"
                MODE_WAS_SET=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_err "Unknown argument: $1"
                ;;
        esac

        shift
    done
}

run_target_script() {
    local mode="$1"
    local target_script
    local local_dir
    local temp_dir

    case "$mode" in
        ssh)
            if is_container_marker; then
                container_rebuild_error
            fi
            target_script="fix-vscode-server-ssh.sh"
            ;;
        devcontainer)
            if ! has_dockerfile_build_flag; then
                is_container_marker && container_rebuild_error
                log_err "Use --devcontainer only from a Dockerfile RUN step with FIX_VSCODE_SERVER_DOCKERFILE_BUILD=1."
            fi
            target_script="fix-vscode-server-devcontainer.sh"
            ;;
        *)
            log_err "Unknown target mode: $mode"
            ;;
    esac

    log_info "Using $target_script"

    if local_dir="$(script_dir)"; then
        if [ -f "$local_dir/$target_script" ]; then
            exec bash "$local_dir/$target_script"
        fi

        log_warn "$target_script was not found next to fix-vscode-server.sh"
    fi

    temp_dir="$(mktemp -d)"
    trap 'rm -rf "$temp_dir"' EXIT

    select_download_source "$target_script"
    download_helper "$temp_dir" "$target_script"
    bash "$temp_dir/$target_script"
}

parse_args "$@"

case "$REQUESTED_MODE" in
    ssh|devcontainer)
        MODE="$REQUESTED_MODE"
        ;;
    auto)
        if has_dockerfile_build_flag; then
            MODE="devcontainer"
        elif is_container_marker; then
            container_rebuild_error
        else
            MODE="ssh"
        fi
        ;;
    *)
        log_err "Unknown requested mode: $REQUESTED_MODE"
        ;;
esac

run_target_script "$MODE"
