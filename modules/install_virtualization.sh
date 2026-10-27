#!/usr/bin/env bash
set -Eeuo pipefail

install_virtualization_module() {
  log INFO "Installing VirtualBox and Vagrant from the configured platform package repositories."
  case "$PLATFORM_FAMILY:$PACKAGE_MANAGER" in
    debian:apt-get)
      refresh_package_lists || return $?
      run_privileged apt-get install -y virtualbox vagrant || return $?
      ;;
    macos:brew)
      run_cmd brew install --cask virtualbox || return $?
      run_cmd brew install --cask vagrant || return $?
      ;;
    *)
      log ERROR "VirtualBox and Vagrant installation is not configured for this platform."
      return 1
      ;;
  esac
  log INFO "VirtualBox and Vagrant installation finished."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # shellcheck source=lib/common.sh
  source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"
  run_standalone_module install_virtualization_module "$@"
fi
