# Repository Guidelines

## Project Structure & Module Organization

This repository currently contains one executable Bash utility:

- `fix-vscode-server-ssh.sh`: installs a compatible GLIBC runtime path for VS Code Server over SSH, configures SSH environment injection, and clears the local VS Code Server cache.

There are no separate source, test, or asset directories yet. Keep additional scripts at the root unless the project grows enough to justify `scripts/` or `tests/`.

## Build, Test, and Development Commands

This project has no build step. Use these checks before committing script changes:

- `bash -n fix-vscode-server-ssh.sh`: validates Bash syntax without executing the script.
- `shellcheck fix-vscode-server-ssh.sh`: runs static analysis when ShellCheck is installed.
- `git diff --check`: catches whitespace errors before commit.
- `chmod +x fix-vscode-server-ssh.sh && ./fix-vscode-server-ssh.sh`: runs the script on a disposable or target Linux host only.

Do not run the script casually on a primary workstation. It can install packages, write under `/home/linuxbrew`, edit `/etc/ssh/sshd_config`, restart SSH, and remove `~/.vscode-server`.

## Coding Style & Naming Conventions

Use Bash with `set -euo pipefail` and `IFS=$'\n\t'` preserved. Prefer small helper functions for repeated logging or failure handling. Use uppercase names for constants and environment-style values such as `PATCH_DIR`, `LINKER_NAME`, and `TEMP_DIR`; use lowercase only for local loop variables.

Quote variable expansions unless Bash pattern matching or arrays require otherwise. Use four-space indentation inside conditionals, loops, and functions.

## Testing Guidelines

There is no automated test framework. At minimum, run `bash -n` and ShellCheck if available. For behavior changes, test in a disposable Linux VM or container and record the distro, architecture, user privileges, and SSH restart result. When changing download logic, validate the affected `uname -m` branch.

## Commit & Pull Request Guidelines

The current history uses short imperative subjects, for example `add scripts`. Continue with concise subjects such as `fix ssh environment setup` or `add arm64 validation`.

Pull requests should include a short description, the reason for the change, tested commands, target OS/architecture, and any expected side effects. Link related issues when available, and include terminal output snippets only when they clarify validation or failures.

## Security & Configuration Tips

Treat changes to package installation, SSH configuration, and cleanup paths as high risk. Avoid broad deletes, unquoted paths, and silent privilege escalation. Prefer explicit warnings before modifying system files or restarting services.
