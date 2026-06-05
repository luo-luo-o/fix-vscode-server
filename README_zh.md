# fix-vscode-server

[English](README.md)

如果你觉得好用的话，请给个 Star ， 谢谢！( •̀ ω •́ )✧

一个 Bash 工具，用于修复旧版 Linux 系统上 VS Code Server 启动失败的问题。这类问题通常是系统 GLIBC 版本太旧，无法满足新版 VS Code Server 二进制文件要求，例如 Ubuntu 18.04。

主入口是 `fix-vscode-server.sh`。先根据 VS Code Server 安装的位置选择使用方式：

- `--ssh`：修复 Remote SSH 主机。
- `--devcontainer`：在 Dockerfile 构建镜像时修复 Docker/Dev Container 镜像。

如果不指定模式：

- 在 Dockerfile 构建过程中设置 `FIX_VSCODE_SERVER_DOCKERFILE_BUILD=1` 时，执行 `fix-vscode-server-devcontainer.sh`。
- 在普通主机上运行时，执行 `fix-vscode-server-ssh.sh`。
- 如果在已经创建好的容器内部运行，脚本会拒绝原地修复，并提示修改 Dockerfile 后重新构建镜像和容器。

## 支持环境

- 使用 `apt-get` 的 Linux 主机
- 架构：`x86_64`、`aarch64`、`armv7l`
- VS Code Remote SSH 主机和 VS Code Dev Containers
- SSH 场景下使用有 `sudo` 权限的普通用户，Dockerfile 构建镜像时允许 root 用户

本项目不用于 Windows、macOS 或主力工作站的本机环境修复。

## 脚本会修改什么

脚本可能会：

- 安装缺失工具/软件包：`curl`、`binutils`（提供 `ar`）、`zstd`、`xz-utils`（提供 `xz`）、`patchelf`、`tar`、`findutils`、`grep`、`sed`、`coreutils`
- 创建或更新 `/opt/vscode_glibc_patch/lib`
- 删除 `~/.vscode-server`，让 VS Code 下次连接时重新安装 server

`fix-vscode-server-ssh.sh` 还可能会：

- 修改 `/etc/ssh/sshd_config`，启用 `PermitUserEnvironment yes`
- 尝试重启 SSH 服务
- 写入 `~/.ssh/environment`

`fix-vscode-server-ssh.sh` 只用于 Remote SSH 主机。它不会检测、修复或配置 Docker/Dev Container 环境。

`fix-vscode-server-devcontainer.sh` 只用于 Dockerfile 构建时修复。它会安装容器 GLIBC patch，写入容器环境文件，并避免修改 SSH daemon 配置。

Dev Container 脚本不会为交互 shell 设置 `LD_LIBRARY_PATH`。这是有意设计：全局导出 patched GLIBC 路径可能导致 VS Code 终端中的普通系统命令，例如 `ls`、`cat`、`ldd` 崩溃。脚本通过 `VSCODE_SERVER_CUSTOM_GLIBC_PATH`、`VSCODE_SERVER_PATCHELF_PATH` 和 `VSCODE_SERVER_CUSTOM_GLIBC_LINKER` 将 patch 暴露给 VS Code Server 安装流程。

## 使用方式

### Remote SSH 主机

在 VS Code 通过 Remote SSH 连接的 Linux 主机上运行：

```bash
bash fix-vscode-server.sh
```

在普通主机上不指定参数时，默认执行 SSH 修复。也可以显式指定 SSH 模式：

```bash
bash fix-vscode-server.sh --ssh
bash fix-vscode-server-ssh.sh
```

脚本完成后，从 VS Code 重新连接。VS Code 应该会使用配置好的 GLIBC 路径重新安装 server。

### Remote SSH 使用 Curl

```bash
GITHUB_URL="https://raw.githubusercontent.com/luo-luo-o/fix-vscode-server/main/fix-vscode-server.sh"
GITEE_URL="https://gitee.com/Hluoluoo/fix-vscode-server/raw/main/fix-vscode-server.sh"
(curl -fsSL --connect-timeout 2 --max-time 5 "$GITHUB_URL" || curl -fsSL "$GITEE_URL") | bash -s -- --ssh
```

第一个 `curl` 会优先从 GitHub 下载入口脚本，失败时回退到 Gitee。入口脚本启动后，也会优先从 GitHub 下载选中的 helper 脚本。它会用 `curl` 探测 GitHub raw URL；如果 GitHub 无法连接或超过超时时间，就切换到 Gitee 镜像：

- GitHub: `https://raw.githubusercontent.com/luo-luo-o/fix-vscode-server/main`
- Gitee: `https://gitee.com/Hluoluoo/fix-vscode-server/raw/main`

GitHub 可连接但较慢时，可以调整探测超时：

```bash
GITHUB_URL="https://raw.githubusercontent.com/luo-luo-o/fix-vscode-server/main/fix-vscode-server.sh"
GITEE_URL="https://gitee.com/Hluoluoo/fix-vscode-server/raw/main/fix-vscode-server.sh"
(curl -fsSL --connect-timeout 2 --max-time 3 "$GITHUB_URL" || curl -fsSL "$GITEE_URL") |
    FIX_VSCODE_SERVER_SOURCE_MAX_TIME=3 bash -s -- --ssh
```

### 在构建镜像时运行修复

Docker/Dev Container 场景必须在构建镜像时进行修复。**不要在已经创建好的容器内部执行修复**。

只需要在 `Dockerfile` 末尾加上以下内容即可

```dockerfile
USER root

ARG FIX_VSCODE_SERVER_GITHUB_BASE_URL="https://raw.githubusercontent.com/luo-luo-o/fix-vscode-server/main"
ARG FIX_VSCODE_SERVER_GITEE_BASE_URL="https://gitee.com/Hluoluoo/fix-vscode-server/raw/main"

RUN set -eux; \
    if ! command -v bash >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then \
        apt-get update; \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash curl ca-certificates; \
        rm -rf /var/lib/apt/lists/*; \
    fi; \
    fix_script="$(mktemp)"; \
    fix_source="$FIX_VSCODE_SERVER_GITHUB_BASE_URL"; \
    if ! curl -fsSL --connect-timeout 2 --max-time 5 "$fix_source/fix-vscode-server.sh" -o "$fix_script"; then \
        fix_source="$FIX_VSCODE_SERVER_GITEE_BASE_URL"; \
        curl -fsSL "$fix_source/fix-vscode-server.sh" -o "$fix_script"; \
    fi; \
    FIX_VSCODE_SERVER_BASE_URL="$fix_source" FIX_VSCODE_SERVER_DOCKERFILE_BUILD=1 bash "$fix_script"; \
    rm -f "$fix_script"

ENV VSCODE_SERVER_CUSTOM_GLIBC_PATH=/opt/vscode_glibc_patch/lib \
    VSCODE_SERVER_PATCHELF_PATH=/usr/bin/patchelf \
    VSCODE_SERVER_CUSTOM_GLIBC_LINKER=/opt/vscode_glibc_patch/lib/ld-vscode-server.so
```

然后**重新构建镜像并重新创建容器**

如果项目使用 VS Code Dev Containers，在修改 Dockerfile 后执行 **Dev Containers:
Rebuild Container**。

### Docker Compose

如果 `docker-compose.yml` 或 `docker-compose.yaml` 只有 `image: ...`，请新增一个 `Dockerfile` 继承原镜像，然后让 service 使用这个 Dockerfile 构建。

```dockerfile
FROM your-existing-image:tag

# 在这里粘贴上一节中的 Dockerfile 构建修复片段。
```

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
```

然后重新构建并重建 service：

```bash
docker compose build --no-cache app
docker compose up -d --force-recreate app
```

### 不要原地修复已有容器

以下用法会被脚本拒绝：

```bash
docker exec -it my-container bash
bash fix-vscode-server.sh
bash fix-vscode-server.sh --devcontainer
```

正确做法是修改镜像构建过程，重新构建镜像，再用新镜像创建容器。这样可以避免脚本猜测并复原原始
`docker run` 或 Compose 运行参数带来的风险。

## 故障排查

如果 VS Code 重新连接后仍然失败：

- SSH 模式下，确认 `~/.ssh/environment` 包含 `VSCODE_SERVER_CUSTOM_GLIBC_PATH`、`VSCODE_SERVER_PATCHELF_PATH` 和 `VSCODE_SERVER_CUSTOM_GLIBC_LINKER`。
- SSH 模式下，确认 `/etc/ssh/sshd_config` 包含 `PermitUserEnvironment yes`。
- Dockerfile 构建容器时，确认镜像或容器环境包含 `VSCODE_SERVER_CUSTOM_GLIBC_PATH`、`VSCODE_SERVER_PATCHELF_PATH` 和 `VSCODE_SERVER_CUSTOM_GLIBC_LINKER`。
- 如果只有 VS Code 终端中的命令 segfault，而 `docker exec` 中命令正常，移除 shell 启动文件里旧的 `LD_LIBRARY_PATH` 注入并重新构建镜像。
- 如果脚本无法重启 SSH，请手动重启 SSH。
- 再次删除 `~/.vscode-server` 后重新连接。
- 使用 `uname -m` 确认架构受支持。
- 使用自定义下载源时，确认 `FIX_VSCODE_SERVER_BASE_URL` 指向包含所有三个脚本的 raw 脚本目录。

## 贡献

变更应保持聚焦。涉及行为变化时，请在一次性 Linux VM 或容器中测试。仓库规范见 [AGENTS.md](AGENTS.md)。
