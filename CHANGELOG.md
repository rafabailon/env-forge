# Changelog

All notable changes to Env Forge are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1] - 2026-10-24

### Added

- Docker Compose detection now verifies the Docker Compose plugin or `docker-compose` binary separately from the Docker Engine.
- Tests for partial Docker installations (Docker Engine present but Compose missing).

### Changed

- Bumped the version to 1.1.1.
- `--check` reports Docker Engine and Docker Compose independently, marking each tool accurately when only one is present.

## [1.1.0] - 2026-10-24

### Added

- `--check` / `-c` read-only environment check that reports each managed tool as `[ok]` or `[missing]`, suggests the relevant module, and exits non-zero when anything is missing.
- `--log-file FILE` CLI option for choosing the session log path.
- Docker prerequisite validation before package installation on Debian/Ubuntu.
- Module-registry, environment-check, Docker-prerequisite, log-path, and duplicate-selection tests.
- GitHub Actions CI workflow for Bash syntax checks, ShellCheck, and the full test suite.

### Changed

- Bumped the version to 1.1.0.
- Duplicate `--module` selections are de-duplicated and run at most once per invocation.
- Platform detection now normalizes uppercase `ID`/`ID_LIKE` values and handles CRLF metadata.
- Interactive sessions now return a non-zero status when an attempted module fails.
- `--log-file` takes precedence over `ENV_FORGE_LOG_FILE`, and parse-time errors no longer require a writable log file.
- The default log directory falls back to a per-user `/tmp` path when `HOME` is unset.
- Docker group membership is read without a word-splitting pipeline, and the target user is verified before `usermod`.

### Fixed

- Prevented parse-time log writes before logging is initialized.
- Preserved explicit CLI failure statuses through the top-level entrypoint.
- Avoided a `set -u` failure when `init_logging` is called with `LOG_FILE` unset.

## [1.0.0] - 2026-10-22

### Added

- Non-interactive CLI options: `--module`, `--all`, `--yes`, `--list`, and `--version`.
- `--dry-run`, `--yes`, and `--help` support for standalone modules.
- Central module registry used by the menu, module listing, and CLI dispatch.
- Semantic version and release history.
- Fail-closed validation for non-interactive runs that would make changes without `--yes`.

### Changed

- Renamed the project from “DevEnvironment AutoSetup Suite” to **Env Forge** across scripts, documentation, logs, license attribution, and repository metadata.
- Docker group setup and Docker installation are now reported as separate, clearly labeled steps.
- All-module runs continue after a module failure and return a non-zero final status.
- Log directories are created with owner-only permissions.

### Fixed

- `apt-get update` runs at most once per process instead of once per module.
- Removed unused `curl` and `git` prerequisite checks that could block installation.
- Preserved the original failure status when a repository update fails.
- Prevented unknown options and conflicting module selections from starting an installation.

### Security

- The Docker installer still never changes Docker socket permissions.
- Docker group membership remains an explicit, confirmed action with a root-equivalent warning.
