#!/bin/bash

# ====================================================
# VS Code Server 跨架构/跨场景修复脚本 (隔离空投版)
# 适配：x86_64 / aarch64 / armv7l / armv6l
# 场景：完美兼顾 SSH 远程 与 Docker Dev Containers
# ====================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- 自动处理权限前缀 ---
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo &> /dev/null; then
    SUDO="sudo"
fi

# [0/6] 环境预检
log_info "正在检查执行环境..."
ARCH=$(uname -m)
[[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" && "$ARCH" != "armv7l" && "$ARCH" != "armv6l" ]] && log_err "不支持的架构: $ARCH"

# 精准检测是否处于 Docker/Dev Container 容器
IS_DOCKER=false
if [ -n "${FIX_VSCODE_SERVER_FORCE_CONTAINER:-}" ] ||
   [ -f /.dockerenv ] ||
   [ -f /run/.containerenv ] ||
   (grep -qaiE 'docker|kubepods|containerd|libpod|podman' /proc/1/cgroup 2>/dev/null); then
    IS_DOCKER=true
fi

if [ "$(id -u)" -eq 0 ]; then
    if [ "$IS_DOCKER" = true ]; then
        log_warn "检测到当前处于 Docker 环境，允许以 root 用户继续执行。"
    else
        log_err "请勿在物理机上直接使用 root 运行此脚本，以免造成权限混乱。"
    fi
fi

# [1/6] 检查并安装必要系统工具
log_info "正在预检系统工具..."
REQUIRED_TOOLS=("curl" "ar" "zstd" "patchelf" "tar")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log_warn "未发现工具 $tool，尝试安装..."
        $SUDO apt-get update && $SUDO apt-get install -y "$tool" || log_err "安装 $tool 失败，请检查网络或软件源。"
    fi
done

# [2/6] 路径准备（隔离非系统路径，不污染全局库）
PATCH_DIR="/opt/vscode_glibc_patch/lib"
log_info "配置库存储目录: $PATCH_DIR"
$SUDO mkdir -p "$PATCH_DIR" || log_err "创建目录失败，请检查磁盘空间或权限。"
if [ "$IS_DOCKER" = false ]; then
    $SUDO chown -R $(whoami):$(whoami) /opt/vscode_glibc_patch 2>/dev/null || true
fi

# [3/6] 确定下载地址与系统库名称（Docker 容器环境优选更稳健的 GLIBC 2.31 降低内核冲突风险）
if [ "$IS_DOCKER" = true ]; then
    # 容器环境用 Ubuntu 20.04 的 GLIBC 2.31 (完全满足 VS Code >= 2.28 要求，且更契合老旧内核)
    GLIBC_VER="2.31"
    if [ "$ARCH" = "aarch64" ]; then
        URL="http://mirrors.kernel.org/ubuntu/pool/main/g/glibc/libc6_2.31-0ubuntu9_arm64.deb"
        LINKER_NAME="ld-linux-aarch64.so.1"
    elif [[ "$ARCH" = "armv7l" || "$ARCH" = "armv6l" ]]; then
        URL="http://mirrors.kernel.org/ubuntu/pool/main/g/glibc/libc6_2.31-0ubuntu9_armhf.deb"
        LINKER_NAME="ld-linux-armhf.so.3"
    else
        URL="http://mirrors.kernel.org/ubuntu/pool/main/g/glibc/libc6_2.31-0ubuntu9_amd64.deb"
        LINKER_NAME="ld-linux-x86-64.so.2"
    fi
else
    # 独立物理机/虚拟机用 Ubuntu 22.04 的 GLIBC 2.35
    GLIBC_VER="2.35"
    if [ "$ARCH" = "aarch64" ]; then
        URL="http://ports.ubuntu.com/pool/main/g/glibc/libc6_2.35-0ubuntu3_arm64.deb"
        LINKER_NAME="ld-linux-aarch64.so.1"
    elif [[ "$ARCH" = "armv7l" || "$ARCH" = "armv6l" ]]; then
        URL="http://ports.ubuntu.com/pool/main/g/glibc/libc6_2.35-0ubuntu3_armhf.deb"
        LINKER_NAME="ld-linux-armhf.so.3"
    else
        URL="http://mirrors.kernel.org/ubuntu/pool/main/g/glibc/libc6_2.35-0ubuntu3_amd64.deb"
        LINKER_NAME="ld-linux-x86-64.so.2"
    fi
fi

# [4/6] 下载与解压 (带重试逻辑)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
cd "$TEMP_DIR"

log_info "正在下载 GLIBC ${GLIBC_VER} 核心包 (3次重试机会)..."
MAX_RETRIES=3; COUNT=0; SUCCESS=false
while [ $COUNT -lt $MAX_RETRIES ]; do
    if curl -L -f -o libc6.deb "$URL"; then SUCCESS=true; break; fi
    COUNT=$((COUNT+1))
    log_warn "下载失败，正在进行第 $COUNT 次重试..."
    sleep 2
done
[[ "$SUCCESS" = false ]] && log_err "无法下载 GLIBC 包，请检查网络连接。"

log_info "正在解压并提取库文件..."
ar x libc6.deb || log_err "DEB 包解析错误 (ar x 失败)。"

if [ -f "data.tar.zst" ]; then
    zstd -d data.tar.zst && tar -xf data.tar
elif [ -f "data.tar.xz" ]; then
    tar -xf data.tar.xz
else
    log_err "未找到预期的 data.tar 压缩文件。"
fi

LIB_SRC=$(find . -name "$LINKER_NAME" | xargs dirname | head -n 1)
[[ -z "$LIB_SRC" ]] && log_err "在解压包中未找到核心 Linker ($LINKER_NAME)。"

$SUDO cp -r "$LIB_SRC"/* "$PATCH_DIR/"
log_info "库文件已成功拷贝至 $PATCH_DIR"

# [5/6] 验证链接与 patchelf
PATCHELF_BIN=$(which patchelf)
LINKER_PATH="$PATCH_DIR/$LINKER_NAME"
[[ ! -x "$LINKER_PATH" ]] && log_err "Linker 文件权限错误或不存在: $LINKER_PATH"

# [6/6] 核心条件分支分类配置
if [ "$IS_DOCKER" = true ]; then
    log_info "【场景：Docker 容器】正在通过 Shell 启动项进行精准局部拦截配置..."
    
    # 检测用户的常用 Shell 配置文件
    TARGET_RC=""
    if [ -n "${SHELL:-}" ] && [[ "$SHELL" == *"zsh"* ]]; then
        TARGET_RC="$HOME/.zshrc"
    elif [ -f "$HOME/.zshrc" ]; then
        TARGET_RC="$HOME/.zshrc"
    else
        TARGET_RC="$HOME/.bashrc"
    fi
    log_info "目标配置文件: $TARGET_RC"

    # 构建注入的黑魔法代码块（仅对 VS Code 探测或拉起服务的进程追加环境变量）
    BLOCK_MARKER="# === VSCODE_GLIBC_PATCH_MARKER ==="
    
    # 先清理掉旧的拦截标记（防止重复写入）
    if [ -f "$TARGET_RC" ]; then
        sed -i "/$BLOCK_MARKER/,/$BLOCK_MARKER/d" "$TARGET_RC"
    fi

    # 写入安全的拦截逻辑
    cat << 'EOF' >> "$TARGET_RC"
# === VSCODE_GLIBC_PATCH_MARKER ===
# 仅对 VS Code 容器嗅探和 Server 派生进程按需加载高版本库，彻底避免系统命令段错误
if [ -n "${VSCODE_REMOTE_CONTAINERS_SESSION:-}" ] || [[ "$(cat /proc/$PPID/cmdline 2>/dev/null)" == *vscode* ]]; then
    export LD_LIBRARY_PATH="/opt/vscode_glibc_patch/lib:${LD_LIBRARY_PATH:-}"
fi
# === VSCODE_GLIBC_PATCH_MARKER ===
EOF

    log_info "容器专属动态劫持策略已成功写入 $TARGET_RC 。"

else
    log_info "【场景：SSH 远程】正在进行标准 SSH 环境注入..."
    if [ -f /etc/ssh/sshd_config ]; then
        if ! grep -q "PermitUserEnvironment yes" /etc/ssh/sshd_config; then
            log_warn "修改 /etc/ssh/sshd_config 以启用 PermitUserEnvironment..."
            $SUDO sed -i 's/^#\(PermitUserEnvironment\) no/\1 yes/' /etc/ssh/sshd_config
            $SUDO sed -i 's/^\(PermitUserEnvironment\) no/\1 yes/' /etc/ssh/sshd_config
            $SUDO systemctl restart ssh || log_warn "SSH 重启失败，请手动执行: sudo systemctl restart ssh"
        fi
    fi

    # 写入 ~/.ssh/environment
    mkdir -p ~/.ssh
    cat <<EOF > ~/.ssh/environment
VSCODE_SERVER_CUSTOM_GLIBC_PATH=$PATCH_DIR
VSCODE_SERVER_PATCHELF_PATH=$PATCHELF_BIN
VSCODE_SERVER_CUSTOM_GLIBC_LINKER=$LINKER_PATH
EOF
    chmod 600 ~/.ssh/environment
    log_info "SSH 环境变量注入完成。"
fi

# 清理 VS Code 缓存触发重装
log_info "清理旧的 VS Code Server 缓存..."
rm -rf ~/.vscode-server

log_info "------------------------------------------------"
log_info "✅ 脚本执行成功！"
log_info "当前架构: $ARCH"
log_info "适配模式: $([ "$IS_DOCKER" = true ] && echo "Docker 局部拦截模式 (非破坏性)" || echo "SSH 环境注入模式")"
log_info "目标组件验证: $($LINKER_PATH --version | head -n 1)"
log_info "请返回宿主机 VS Code 界面点击 Retry 重新连接。"
log_info "------------------------------------------------"
