# Repository Guidelines

## Project Structure & Module Organization

This repository contains Bash utilities for repairing VS Code Server startup failures
on older Linux GLIBC environments:

- `fix-vscode-server.sh`: main entrypoint. By default it runs SSH repair on normal
  hosts and Dockerfile build-time Dev Container repair only when
  `FIX_VSCODE_SERVER_DOCKERFILE_BUILD=1` is set. It refuses in-place repair from
  inside already-created containers.
- `fix-vscode-server-ssh.sh`: repairs Remote SSH hosts by installing an isolated
  GLIBC runtime path, configuring SSH environment injection, and clearing the local
  VS Code Server cache.
- `fix-vscode-server-devcontainer.sh`: repairs Docker/Dev Container images during
  Dockerfile builds, writes container environment files, avoids global
  `LD_LIBRARY_PATH`, and clears the container VS Code Server cache.
- `README.md`: English user documentation.
- `README_zh.md`: Chinese user documentation.

Keep core scripts at the repository root unless the project grows enough to justify
`scripts/` or `tests/`.

## Build, Test, and Development Commands

This project has no build step. Use these checks before committing script changes:

- `bash -n fix-vscode-server.sh`: validates the main entrypoint syntax.
- `bash -n fix-vscode-server-ssh.sh`: validates SSH repair syntax.
- `bash -n fix-vscode-server-devcontainer.sh`: validates Dev Container repair syntax.
- `shellcheck fix-vscode-server.sh fix-vscode-server-ssh.sh fix-vscode-server-devcontainer.sh`: runs static analysis when ShellCheck is installed.
- `git diff --check`: catches whitespace errors before commit.

Do not run repair flows casually on a primary workstation or important container. The
scripts can install packages, write under `/opt/vscode_glibc_patch`, edit SSH
  configuration, restart SSH, and remove `~/.vscode-server`.

For behavior validation, use a disposable Linux VM or disposable Docker container.

## Runtime Modes

Prefer these modes in examples and tests:

- `bash fix-vscode-server.sh`: repair a Remote SSH host by default on a normal host.
- `bash fix-vscode-server.sh --ssh`: explicitly repair a Remote SSH host.
- `FIX_VSCODE_SERVER_DOCKERFILE_BUILD=1 bash fix-vscode-server.sh`: run Dev
  Container repair from a Dockerfile `RUN` step.

For containers, prefer Dockerfile build-time repair. The
`VSCODE_SERVER_CUSTOM_GLIBC_PATH`, `VSCODE_SERVER_PATCHELF_PATH`, and
`VSCODE_SERVER_CUSTOM_GLIBC_LINKER` must exist in the Docker-level environment before
VS Code installs its server.

Do not reintroduce automatic repair of already-running containers. That flow requires
committing containers and recreating them with reconstructed runtime arguments, which is
too risky for this project.

## Dockerfile Build-Time Behavior

Container documentation should show build-time repair in a Dockerfile:

- Download `fix-vscode-server.sh` from GitHub first, Gitee fallback.
- Run it with `FIX_VSCODE_SERVER_DOCKERFILE_BUILD=1 bash "$fix_script"`.
- Set `ENV VSCODE_SERVER_CUSTOM_GLIBC_PATH`,
  `VSCODE_SERVER_PATCHELF_PATH`, and `VSCODE_SERVER_CUSTOM_GLIBC_LINKER` after repair.
- For Compose users with only `image: ...`, document extending that image with a
  Dockerfile and changing the service to `build:`.
- Document that `docker exec ... bash` followed by the repair script is rejected.
- Do not recommend repairing an already-created container as the normal path.

## Download Source Behavior

The entrypoint supports GitHub and Gitee raw sources. GitHub is preferred, and Gitee is
the fallback when GitHub is unreachable or too slow. Preserve these overrides:

- `FIX_VSCODE_SERVER_BASE_URL`: force a raw script directory and skip automatic source
  selection.
- `FIX_VSCODE_SERVER_GITHUB_BASE_URL`: override the GitHub raw script directory.
- `FIX_VSCODE_SERVER_GITEE_BASE_URL`: override the Gitee raw script directory.
- `FIX_VSCODE_SERVER_SOURCE_CONNECT_TIMEOUT`: tune GitHub probe connect timeout.
- `FIX_VSCODE_SERVER_SOURCE_MAX_TIME`: tune GitHub probe total timeout.

## Coding Style & Naming Conventions

Use Bash with `set -euo pipefail` and `IFS=$'\n\t'` preserved. Prefer small helper
functions for repeated logging, mode parsing, source selection, and failure handling.

Use uppercase names for constants and environment-style values such as `PATCH_DIR`,
`LINKER_NAME`, `TEMP_DIR`, and `VSCODE_GLIBC_LINKER`; use lowercase for local
function variables.

Quote variable expansions unless Bash pattern matching or arrays require otherwise.
Use four-space indentation inside conditionals, loops, and functions.

## Testing Guidelines

At minimum, run `bash -n` for all scripts and `git diff --check`. Run ShellCheck when
available.

For SSH changes, test on a disposable Linux VM or target host and record distro,
architecture, user privileges, and SSH restart result.

For Dev Container changes, test with a disposable Dockerfile-built image. Record base
image, architecture, and whether VS Code Attach used a container created from an image
with the required `VSCODE_SERVER_*` environment variables.

When changing download logic, validate the affected `uname -m` branch and source
fallback behavior when feasible.

## Commit & Pull Request Guidelines

Use short imperative commit subjects, for example `add dockerfile repair docs` or
`fix source fallback`.

Pull requests should include a short description, reason for the change, tested
commands, target OS/architecture, Docker base image when applicable, and any expected
side effects. Include terminal output snippets only when they clarify validation or
failures.

## Security & Configuration Tips

Treat package installation, SSH configuration, Dockerfile repair, and cleanup paths as
high risk. Avoid broad deletes, unquoted paths, and silent privilege escalation. Prefer
explicit warnings before modifying system files or restarting services.
