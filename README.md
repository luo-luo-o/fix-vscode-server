# fix-vscode-server

[中文文档](README_zh.md)

A Bash utility for fixing VS Code Server startup failures on older Linux systems where the system GLIBC is too old for the latest VS Code Server binary, such as Ubuntu 18.04.

If you think it is usful, please give me a Star!
Thanks ( •̀ ω •́ )✧

The main entrypoint is `fix-vscode-server.sh`. Choose the path by where VS Code
installs its server:

- `--ssh` repairs a Remote SSH host.
- `--devcontainer` repairs a Docker/Dev Container image during Dockerfile build.

Without explicit mode:

- During Dockerfile builds with `FIX_VSCODE_SERVER_DOCKERFILE_BUILD=1`, it runs `fix-vscode-server-devcontainer.sh`.
- On normal hosts, it runs `fix-vscode-server-ssh.sh`.
- Inside already-created containers, it refuses to repair in place and tells you to modify the Dockerfile and rebuild the image.

## Supported Hosts

- Linux hosts using `apt-get`
- Architectures: `x86_64`, `aarch64`, `armv7l`
- VS Code Remote SSH hosts and VS Code Dev Containers
- Normal non-root users with `sudo`, or root during Dockerfile image builds

This project is not intended for Windows, macOS, or primary workstation setup.

## What the Scripts Change

The scripts may:

- Install missing tools/packages: `curl`, `binutils` (`ar`), `zstd`, `xz-utils` (`xz`), `patchelf`, `tar`, `findutils`, `grep`, `sed`, and `coreutils`
- Create or update `/opt/vscode_glibc_patch/lib`
- Remove `~/.vscode-server` so VS Code reinstalls the server on the next connection

`fix-vscode-server-ssh.sh` may also:

- Edit `/etc/ssh/sshd_config` to enable `PermitUserEnvironment yes`
- Restart the SSH service when possible
- Write `~/.ssh/environment`

`fix-vscode-server-ssh.sh` is only for Remote SSH hosts. It does not detect, repair, or configure Docker/Dev Container environments.

`fix-vscode-server-devcontainer.sh` is only for Dockerfile build-time repair. It installs the container GLIBC patch, writes container environment files, and avoids SSH daemon configuration.

The Dev Container script does not set `LD_LIBRARY_PATH` for interactive shells. That is intentional: exporting the patched GLIBC path globally can make normal system commands such as `ls`, `cat`, and `ldd` crash inside VS Code terminals. The patch is exposed through `VSCODE_SERVER_CUSTOM_GLIBC_PATH`, `VSCODE_SERVER_PATCHELF_PATH`, and `VSCODE_SERVER_CUSTOM_GLIBC_LINKER` for VS Code Server setup instead.

For Dockerfile-built images, the image should also define the VS Code Server environment variables with `ENV` before containers are created:

```dockerfile
ENV VSCODE_SERVER_CUSTOM_GLIBC_PATH=/opt/vscode_glibc_patch/lib \
    VSCODE_SERVER_PATCHELF_PATH=/usr/bin/patchelf \
    VSCODE_SERVER_CUSTOM_GLIBC_LINKER=/opt/vscode_glibc_patch/lib/ld-vscode-server.so
```

This is required because VS Code Dev Containers starts its server through non-interactive container commands that do not reliably source shell rc files.

Run these scripts only on a target or disposable host/image where these changes are acceptable.

## Usage

### Remote SSH Host

Run this on the Linux machine that VS Code connects to through Remote SSH:

```bash
bash fix-vscode-server.sh
```

That defaults to SSH repair on a normal host. You can also make the mode explicit:

```bash
bash fix-vscode-server.sh --ssh
bash fix-vscode-server-ssh.sh
```

After the script completes, reconnect from VS Code. VS Code should reinstall its server using the configured GLIBC path.

### Remote SSH With Curl

```bash
GITHUB_URL="https://raw.githubusercontent.com/luo-luo-o/fix-vscode-server/main/fix-vscode-server.sh"
GITEE_URL="https://gitee.com/Hluoluoo/fix-vscode-server/raw/main/fix-vscode-server.sh"
(curl -fsSL --connect-timeout 2 --max-time 5 "$GITHUB_URL" || curl -fsSL "$GITEE_URL") | bash -s -- --ssh
```

The first `curl` command fetches the entrypoint from GitHub first and falls back to Gitee if needed. After the entrypoint starts, it downloads the selected helper script from GitHub first. It probes the GitHub raw URL with `curl`; if GitHub cannot be reached or the request exceeds the timeout, it falls back to the Gitee mirror:

- GitHub: `https://raw.githubusercontent.com/luo-luo-o/fix-vscode-server/main`
- Gitee: `https://gitee.com/Hluoluoo/fix-vscode-server/raw/main`

You can tune the probe timeout when GitHub is reachable but slow:

```bash
GITHUB_URL="https://raw.githubusercontent.com/luo-luo-o/fix-vscode-server/main/fix-vscode-server.sh"
GITEE_URL="https://gitee.com/Hluoluoo/fix-vscode-server/raw/main/fix-vscode-server.sh"
(curl -fsSL --connect-timeout 2 --max-time 3 "$GITHUB_URL" || curl -fsSL "$GITEE_URL") |
    FIX_VSCODE_SERVER_SOURCE_MAX_TIME=3 bash -s -- --ssh
```

### Dockerfile Build

For Docker/Dev Container usage, run the repair while building the image. **Do not run the repair inside an already-created container.**

Add this block near the end of your `Dockerfile`:

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

Then **rebuild the image and recreate the container**

If your project uses Dev Containers, rebuild from VS Code with **Dev Containers:
Rebuild Container** after updating the Dockerfile.

### Docker Compose

If `docker-compose.yml` or `docker-compose.yaml` uses only `image: ...`, add a small `Dockerfile` that extends that image, then make the service build from it.

```dockerfile
FROM your-existing-image:tag

# Paste the Dockerfile build block from the previous section here.
```

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
```

Then rebuild and recreate the service:

```bash
docker compose build --no-cache app
docker compose up -d --force-recreate app
```

### Do Not Repair Existing Containers In Place

These commands are intentionally rejected:

```bash
docker exec -it my-container bash
bash fix-vscode-server.sh
bash fix-vscode-server.sh --devcontainer
```

Modify the image build instead, rebuild the image, and create a new container from the
rebuilt image. This avoids guessing and replaying the original `docker run` or Compose
runtime arguments.

## Troubleshooting

If VS Code still fails after reconnecting:

- Confirm `~/.ssh/environment` contains `VSCODE_SERVER_CUSTOM_GLIBC_PATH`, `VSCODE_SERVER_PATCHELF_PATH`, and `VSCODE_SERVER_CUSTOM_GLIBC_LINKER` for SSH mode.
- Confirm `/etc/ssh/sshd_config` has `PermitUserEnvironment yes` for SSH mode.
- For Dockerfile-built containers, confirm the image or container environment includes `VSCODE_SERVER_CUSTOM_GLIBC_PATH`, `VSCODE_SERVER_PATCHELF_PATH`, and `VSCODE_SERVER_CUSTOM_GLIBC_LINKER`.
- If commands segfault only in the VS Code terminal but work with `docker exec`, remove any old `LD_LIBRARY_PATH` injection from shell startup files and rebuild the image.
- Restart SSH manually if the script could not restart it.
- Delete `~/.vscode-server` again and reconnect.
- Check that your architecture is supported with `uname -m`.
- When using a custom source, confirm `FIX_VSCODE_SERVER_BASE_URL` points to a raw script directory that contains all three scripts.

## Contributing

Keep changes focused and test on a disposable Linux VM or container when behavior changes. See [AGENTS.md](AGENTS.md) for repository guidelines.
