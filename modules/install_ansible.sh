#!/usr/bin/env bash
set -Eeuo pipefail

install_ansible_module() {
  log INFO "Installing Ansible from the configured platform package repositories."
  case "$PLATFORM_FAMILY:$PACKAGE_MANAGER" in
    debian:apt-get)
      refresh_package_lists || return $?
      run_privileged apt-get install -y ansible || return $?
      ;;
    macos:brew)
      run_cmd brew install ansible || return $?
      ;;
    *)
      log ERROR "Ansible installation is not configured for this platform."
      return 1
      ;;
  esac
  log INFO "Ansible installation finished. Verify with: ansible --version"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # shellcheck source=lib/common.sh
  source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"
  run_standalone_module install_ansible_module "$@"
fi
