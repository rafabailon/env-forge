# Env Forge

Env Forge is a small, reviewable Bash installer for common local development and virtualization tools: Ansible, VirtualBox with Vagrant, and Docker with Compose. It supports Debian/Ubuntu derivatives through `apt-get` and macOS through Homebrew.

The installer is interactive by default. It also has a non-interactive CLI, a read-only environment check, renders every command in dry-run mode, writes private logs, and never runs downloaded shell scripts.

## Safety first

- Review the scripts before running them. Installing system tools changes your machine.
- Package installation may request administrator authentication through `sudo`.
- Run `setup.sh` as your regular account, **not** with `sudo`; privileged commands request elevation individually.
- The installer asks for confirmation before installing packages or changing group membership. Dry runs and `--yes` do not prompt.
- Use `--yes` only when you have reviewed the planned commands, for example together with `--dry-run`.
- Run `./setup.sh --check` to inspect the current installation without changing anything.
- Docker `docker` group membership grants root-equivalent access to the host. Add only trusted users.
- Env Forge never makes the Docker socket world-writable and never changes its permissions; the daemon manages the socket.
- On Linux, packages come from the repositories already configured on the system. Env Forge does not add third-party repositories.
- On macOS, tools are installed via Homebrew. Docker is installed as Docker Desktop and must be started from Applications.

## Supported platforms and modules

| Module | Platform | Installer | Result |
|---|---|---|---|
| `ansible` | Debian / Ubuntu derivatives | `apt-get` package `ansible` | Ansible CLI |
| `ansible` | macOS with Homebrew | `brew install ansible` | Ansible CLI |
| `virtualization` | Debian / Ubuntu derivatives | `apt-get` packages `virtualbox` and `vagrant` | VirtualBox and Vagrant |
| `virtualization` | macOS with Homebrew | Homebrew casks `virtualbox` and `vagrant` | VirtualBox and Vagrant |
| `docker` | Debian / Ubuntu derivatives | `apt-get` packages `docker.io` and `docker-compose-v2` | Docker Engine, Compose, and `docker` group access |
| `docker` | macOS with Homebrew | Docker Desktop cask | Docker Desktop and Compose |

Other Linux distributions are deliberately rejected instead of being given guessed package names or unreviewed repository configuration. On Ubuntu and Debian, the configured repositories must provide `virtualbox`, `vagrant`, and `docker-compose-v2`.

## Prerequisites

- Bash 3.2 or newer
- Debian/Ubuntu: `apt-get`; `sudo` when running as a non-root user
- macOS: Homebrew (`brew`)
- `getent`, `groupadd`, and `usermod` for the Linux Docker group setup

Env Forge does not install its own prerequisites. Missing commands are reported before a module runs.

## Verify an existing environment

The read-only check reports the detected platform and whether each managed tool is available. It never installs packages, requests `sudo`, or writes a log file:

```bash
./setup.sh --check
```

The output marks every tool as `[ok]` or `[missing]` and suggests the module that provides it. The command exits `0` when all tools are present and `1` when anything is missing, which makes it suitable for scripts and post-install validation.

## Run interactively

From the project directory:

```bash
chmod +x setup.sh modules/install_*.sh tests/test_setup.sh
./setup.sh
```

The menu lets you install one module, run all three, or exit. A module can also be run directly:

```bash
./modules/install_ansible.sh
./modules/install_virtualization.sh
./modules/install_docker.sh
```

## Command-line options

```text
Usage: ./setup.sh [OPTIONS]

  -n, --dry-run        Show planned commands without changing the system.
  -c, --check          Report whether the managed tools are installed. No changes.
  -m, --module NAME    Run one module non-interactively. Repeat for several.
  -a, --all            Run all modules non-interactively.
  -y, --yes            Skip confirmation prompts. Use only when intentional.
      --log-file FILE  Write the session log to FILE.
  -l, --list           List available modules and exit.
  -V, --version        Print the version and exit.
  -h, --help           Show help and exit.
```

Examples:

```bash
# Inspect the current installation without changing anything
./setup.sh --check

# Inspect all planned commands without installing anything
./setup.sh --all --dry-run

# Run only Ansible after reviewing its plan
./setup.sh --module ansible --dry-run
./setup.sh --module ansible --yes

# Run several selected modules
./setup.sh --module ansible --module docker --yes

# Keep the session log at a specific path
./setup.sh --module docker --log-file ./env-forge-docker.log

# Discover module identifiers
./setup.sh --list
```

`--all` and `--module` cannot be combined. Duplicate `--module` values are ignored, so a module runs at most once per invocation. A non-interactive run that would make changes requires `--yes`; without a terminal to confirm, it fails closed instead of silently skipping work.

Standalone modules accept the same safety flags:

```bash
./modules/install_ansible.sh --dry-run
./modules/install_ansible.sh --yes
./modules/install_ansible.sh --help
```

## Environment variables

| Variable | Purpose |
|---|---|
| `ENV_FORGE_DRY_RUN=1` | Same as `--dry-run`. |
| `ENV_FORGE_LOG_FILE=/path/to/file` | Override the log file path. `--log-file` takes precedence. |
| `XDG_STATE_HOME=/path` | Base directory for the default log location. |
| `NO_COLOR=1` | Disable colored console output. |
| `SUDO_USER` | Identifies the regular user who receives Docker group membership. |

## Logs

Env Forge writes logs to `~/.local/state/env-forge/setup-YYYYMMDD-HHMMSS.log` (or `$XDG_STATE_HOME/env-forge/`). Use `--log-file FILE` or `ENV_FORGE_LOG_FILE` to choose another path. When `HOME` is unset, the default falls back to a per-user directory under `/tmp`. New log directories are created with owner-only permissions, log files are restricted to mode `600`, and dry-run commands are recorded in the log as well as printed to the terminal. `--check` does not write a log.

## Docker group and session refresh

On Debian/Ubuntu, the Docker module creates the `docker` group if needed, adds the invoking non-root user, and enables the Docker service when `systemctl` is available. It validates the required user and group tools before installing packages, so a missing prerequisite cannot leave a half-configured installation. It does not modify the Docker socket directly.

Group membership is loaded at login. Log out and back in, or start a fresh login session. For a temporary shell, `newgrp docker` starts a subshell with the group active. Verify with:

```bash
id -nG
docker version
docker compose version
```

Membership in the Docker group allows host-level root-equivalent control. Do not add untrusted accounts.

On macOS, start Docker Desktop from Applications and wait for its engine to become ready. Linux group setup does not apply.

## Idempotency and behavior

- Each module can be rerun safely; `apt-get` and Homebrew skip packages that are already current.
- Duplicate `--module` selections are de-duplicated, so each selected module runs once.
- Package lists are refreshed at most once per process. Running all modules performs one `apt-get update`, not one per module.
- A failed repository update stops that module before any package is installed, and the original exit status is preserved.
- Docker prerequisites are checked before package installation on Linux, avoiding a partial group configuration.
- When running all modules, a failure is reported and the remaining modules still run; the final exit status is non-zero.
- Existing Docker group membership is detected without relying on word-splitting pipelines, and `systemctl enable --now docker` is idempotent when the service is already enabled.

## Tests

The test suite is dependency-free and exercises platform parsing, CLI behavior, command plans in dry-run mode, the read-only environment check, logging permissions, module-registry consistency, safety behavior, and failure propagation. It **does not** install packages, invoke `sudo`, change group membership, or alter system configuration.

```bash
bash tests/test_setup.sh
```

The suite currently performs 93 checks. It also syntax-checks every shell script.

If ShellCheck is installed, run:

```bash
shellcheck setup.sh lib/common.sh modules/*.sh tests/*.sh
```

## Project structure

```text
setup.sh                          Interactive and non-interactive orchestrator
lib/common.sh                     Logging, platform detection, module and tool
                                  registries, environment check, package-list
                                  refresh, and safe command runner
modules/install_ansible.sh        Ansible module
modules/install_virtualization.sh VirtualBox and Vagrant module
modules/install_docker.sh         Docker, Compose, and Linux group module
tests/test_setup.sh               Dependency-free shell tests
CHANGELOG.md                      Release history
```

## License

MIT. See [LICENSE](LICENSE).
