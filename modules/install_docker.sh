#!/usr/bin/env bash
set -Eeuo pipefail

install_docker_module() {
  log INFO "Installing Docker and Compose from the configured platform package repositories."
  case "$PLATFORM_FAMILY:$PACKAGE_MANAGER" in
    debian:apt-get)
      validate_docker_prerequisites || return $?
      refresh_package_lists || return $?
      run_privileged apt-get install -y docker.io docker-compose-v2 || return $?
      configure_docker_group || return $?
      ;;
    macos:brew)
      run_cmd brew install --cask docker || return $?
      log WARN "Start Docker Desktop from Applications before using Docker Compose."
      ;;
    *)
      log ERROR "Docker installation is not configured for this platform."
      return 1
      ;;
  esac
  log INFO "Docker installation finished. Verify with: docker version"
}

docker_target_user() {
  local target_user="${SUDO_USER:-$(id -un)}"
  if [[ -z "$target_user" ]]; then
    log ERROR "Cannot determine the regular user for Docker group membership."
    return 1
  fi
  if [[ "$target_user" == "root" && "${ENV_FORGE_DRY_RUN:-0}" != "1" ]]; then
    log ERROR "Run setup as a regular user; sudo will be requested only for privileged commands."
    return 1
  fi
  printf '%s\n' "$target_user"
}

validate_docker_prerequisites() {
  if [[ "$PLATFORM_FAMILY" != "debian" ]]; then
    log ERROR "The Docker group setup applies only to Linux installations."
    return 1
  fi
  if [[ "${ENV_FORGE_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  docker_target_user >/dev/null || return $?
  require_command getent || return $?
  require_command groupadd || return $?
  require_command usermod || return $?
}

configure_docker_group() {
  if [[ "$PLATFORM_FAMILY" != "debian" ]]; then
    log ERROR "The Docker group setup applies only to Linux installations."
    return 1
  fi
  local target_user groups
  target_user="$(docker_target_user)" || return $?
  require_command getent || return $?
  require_command groupadd || return $?
  require_command usermod || return $?
  if ! getent passwd "$target_user" >/dev/null; then
    log ERROR "Target user does not exist: $target_user"
    return 1
  fi
  if ! getent group docker >/dev/null; then
    run_privileged groupadd --system docker || return $?
  fi
  if ! groups="$(id -nG "$target_user")"; then
    log ERROR "Cannot read group membership for user: $target_user"
    return 1
  fi
  case " $groups " in
    *" docker "*)
      log INFO "User $target_user is already a member of the docker group."
      ;;
    *)
      run_privileged usermod -aG docker "$target_user" || return $?
      ;;
  esac
  if command -v systemctl >/dev/null 2>&1; then
    run_privileged systemctl enable --now docker || return $?
  fi
  log WARN "Docker group membership grants root-equivalent access to this host."
  log INFO "Log out and back in (or start a new login session) before using Docker without sudo."
  log INFO "The installer does not change Docker socket permissions; the daemon manages its socket."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # shellcheck source=lib/common.sh
  source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"
  run_standalone_module install_docker_module "$@"
fi
