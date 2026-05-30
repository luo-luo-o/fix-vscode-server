# fix-vscode-server

A Bash utility for fixing VS Code Server startup failures on older Linux systems where the system GLIBC is too old for the latest VS Code Server binary, such as Ubuntu 18.04.

The main entrypoint is `fix-vscode-server.sh`. It detects whether it is running inside a Docker/Dev Container environment:

- In a container, it runs `fix-vscode-server-devcontainer.sh`.
- Outside a container, it runs `fix-vscode-server-ssh.sh`.

## Supported Hosts

- Linux hosts using `apt-get`
- Architectures: `x86_64`, `aarch64`, `armv7l`, `armv6l`
- VS Code Remote SSH hosts and VS Code Dev Containers
- Normal non-root users with `sudo`, or root inside containers

This project is not intended for Windows, macOS, or primary workstation setup.

## What the Scripts Change

The scripts may:

- Install missing tools: `curl`, `ar`, `zstd`, `patchelf`, and `tar`
- Create or update `/opt/vscode_glibc_patch/lib`
- Remove `~/.vscode-server` so VS Code reinstalls the server on the next connection

`fix-vscode-server-ssh.sh` may also:

- Edit `/etc/ssh/sshd_config` to enable `PermitUserEnvironment yes`
- Restart the SSH service when possible
- Write `~/.ssh/environment`

`fix-vscode-server-devcontainer.sh` runs the shared installer in container mode and writes a shell startup block so VS Code container sessions load the patched GLIBC path without changing SSH settings.

Run these scripts only on a target or disposable host/container where these changes are acceptable.

## Usage

Clone the repository on the remote Linux host or inside the dev container, then run:

```bash
bash fix-vscode-server.sh
```

You can also run a specific mode directly:

```bash
bash fix-vscode-server-ssh.sh
bash fix-vscode-server-devcontainer.sh
```

After the script completes, reconnect from VS Code. VS Code should reinstall its server using the configured GLIBC path.

## Curl Usage

```bash
BASE_URL="https://raw.githubusercontent.com/luo-luo-o/fix-vscode-server/main"
curl -fsSL "$BASE_URL/fix-vscode-server.sh" | FIX_VSCODE_SERVER_BASE_URL="$BASE_URL" bash
```

The `FIX_VSCODE_SERVER_BASE_URL` value lets the downloaded entrypoint fetch `fix-vscode-server-ssh.sh` or `fix-vscode-server-devcontainer.sh` from the same repository.

Because `DEFAULT_BASE_URL` is set in the entrypoint scripts, users can also run:

```bash
curl -fsSL "https://raw.githubusercontent.com/luo-luo-o/fix-vscode-server/main/fix-vscode-server.sh" | bash
```

## Validation

Before editing or contributing changes, validate the scripts with:

```bash
bash -n fix-vscode-server.sh
bash -n fix-vscode-server-ssh.sh
bash -n fix-vscode-server-devcontainer.sh
shellcheck fix-vscode-server.sh fix-vscode-server-ssh.sh fix-vscode-server-devcontainer.sh
git diff --check
```

`shellcheck` is optional but recommended.

## Troubleshooting

If VS Code still fails after reconnecting:

- Confirm `~/.ssh/environment` contains `VSCODE_SERVER_CUSTOM_GLIBC_PATH`, `VSCODE_SERVER_PATCHELF_PATH`, and `VSCODE_SERVER_CUSTOM_GLIBC_LINKER` for SSH mode.
- Confirm `/etc/ssh/sshd_config` has `PermitUserEnvironment yes` for SSH mode.
- Restart SSH manually if the script could not restart it.
- Delete `~/.vscode-server` again and reconnect.
- Check that your architecture is supported with `uname -m`.
- When using curl, confirm `FIX_VSCODE_SERVER_BASE_URL` points to the raw GitHub directory that contains all three scripts.

## Contributing

Keep changes focused and test on a disposable Linux VM or container when behavior changes. See [AGENTS.md](AGENTS.md) for repository guidelines.
