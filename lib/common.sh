#!/usr/bin/env bash

if [[ -z "${ENV_FORGE_COMMON_LOADED:-}" ]]; then
  ENV_FORGE_COMMON_LOADED=1
  ENV_FORGE_NAME="Env Forge"
  ENV_FORGE_VERSION="1.1.1"
  ENV_FORGE_MODULES=(ansible virtualization docker)
  ENV_FORGE_TOOLS=(ansible docker docker_compose virtualbox vagrant)

  PLATFORM_LABEL=""
  PLATFORM_FAMILY=""
  DISTRO_ID=""
  PACKAGE_MANAGER=""
  LOG_FILE="${ENV_FORGE_LOG_FILE:-}"
  LOG_INITIALIZED=0
  PACKAGE_LISTS_UPDATED=0

  color_enabled() {
    [[ -t 1 && -z "${NO_COLOR:-}" ]]
  }

  log() {
    local level="$1"
    shift
    local timestamp line color reset
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    line="[$timestamp] [$level] $*"
    color=""
    reset=""
    if color_enabled; then
      case "$level" in
        INFO) color=$'\033[32m' ;;
        WARN) color=$'\033[33m' ;;
        ERROR) color=$'\033[31m' ;;
      esac
      reset=$'\033[0m'
    fi
    printf '%s%s%s\n' "$color" "$line" "$reset"
    if [[ "$LOG_INITIALIZED" == "1" && -n "$LOG_FILE" ]]; then
      printf '%s\n' "$line" >>"$LOG_FILE"
    fi
  }

  init_logging() {
    if [[ -z "${LOG_FILE:-}" ]]; then
      local state_dir
      if [[ -n "${XDG_STATE_HOME:-}" ]]; then
        state_dir="$XDG_STATE_HOME"
      elif [[ -n "${HOME:-}" ]]; then
        state_dir="$HOME/.local/state"
      else
        state_dir="/tmp/env-forge-${UID:-$(id -u)}"
      fi
      LOG_FILE="$state_dir/env-forge/setup-$(date '+%Y%m%d-%H%M%S').log"
    fi
    local log_dir
    log_dir="$(dirname -- "$LOG_FILE")"
    if ! (umask 077; mkdir -p -- "$log_dir"); then
      printf 'Cannot create log directory: %s\n' "$log_dir" >&2
      return 1
    fi
    (umask 077; touch -- "$LOG_FILE") || {
      printf 'Cannot create log file: %s\n' "$LOG_FILE" >&2
      return 1
    }
    chmod 600 -- "$LOG_FILE" || return 1
    LOG_INITIALIZED=1
    export LOG_FILE
  }

  run_cmd() {
    local status=0
    if [[ "${ENV_FORGE_DRY_RUN:-0}" == "1" ]]; then
      local rendered=""
      printf -v rendered ' %q' "$@"
      log INFO "[dry-run]${rendered}"
      return 0
    fi
    if "$@"; then
      return 0
    else
      status=$?
      log ERROR "Command failed (exit $status): $*"
      return "$status"
    fi
  }

  run_privileged() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      run_cmd "$@"
    elif [[ "${ENV_FORGE_DRY_RUN:-0}" == "1" ]]; then
      run_cmd sudo "$@"
    else
      require_command sudo || return $?
      run_cmd sudo "$@"
    fi
  }

  require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
      log ERROR "Required command not found: $1"
      return 1
    fi
  }

  refresh_package_lists() {
    if [[ "$PLATFORM_FAMILY" != "debian" ]]; then
      return 0
    fi
    if [[ "$PACKAGE_LISTS_UPDATED" == "1" ]]; then
      log INFO "Package lists were already refreshed in this session."
      return 0
    fi
    run_privileged apt-get update || return $?
    PACKAGE_LISTS_UPDATED=1
  }

  detect_platform() {
    local release_file="${1:-/etc/os-release}"
    local system_name="${2:-$(uname -s)}"
    local id="" id_like=""
    PLATFORM_LABEL=""
    PLATFORM_FAMILY=""
    DISTRO_ID=""
    PACKAGE_MANAGER=""
    if [[ "$system_name" == "Darwin" ]]; then
      PLATFORM_FAMILY="macos"
      DISTRO_ID="macos"
      PACKAGE_MANAGER="brew"
      PLATFORM_LABEL="macOS"
    elif [[ "$system_name" == "Linux" ]]; then
      if [[ ! -r "$release_file" ]]; then
        log ERROR "Cannot read Linux distribution metadata at $release_file."
        return 1
      fi
      while IFS='=' read -r field value; do
        case "$field" in
          ID) id="${value%$'\r'}" ;;
          ID_LIKE) id_like="${value%$'\r'}" ;;
        esac
      done <"$release_file"
      id="${id#\"}"; id="${id%\"}"
      id="${id#\'}"; id="${id%\'}"
      id_like="${id_like#\"}"; id_like="${id_like%\"}"
      id_like="${id_like#\'}"; id_like="${id_like%\'}"
      id="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
      id_like="$(printf '%s' "$id_like" | tr '[:upper:]' '[:lower:]')"
      DISTRO_ID="$id"
      if [[ "$id" == "ubuntu" || "$id" == "debian" ||
        " $id_like " == *" ubuntu "* || " $id_like " == *" debian "* ]]; then
        PLATFORM_FAMILY="debian"
        PACKAGE_MANAGER="apt-get"
        PLATFORM_LABEL="$id"
      else
        log ERROR "Unsupported Linux distribution '$id'. Supported distributions are Debian/Ubuntu derivatives and macOS."
        return 1
      fi
    else
      log ERROR "Unsupported operating system: $system_name."
      return 1
    fi
  }

  preflight() {
    require_command "$PACKAGE_MANAGER" || return $?
    if [[ "$PLATFORM_FAMILY" == "debian" &&
      "${EUID:-$(id -u)}" -ne 0 &&
      "${ENV_FORGE_DRY_RUN:-0}" != "1" ]]; then
      require_command sudo || return $?
    fi
  }

  module_exists() {
    local module_id
    for module_id in "${ENV_FORGE_MODULES[@]}"; do
      if [[ "$module_id" == "$1" ]]; then
        return 0
      fi
    done
    return 1
  }

  module_function() {
    case "${1:-}" in
      ansible) printf '%s\n' install_ansible_module ;;
      virtualization) printf '%s\n' install_virtualization_module ;;
      docker) printf '%s\n' install_docker_module ;;
      *) return 1 ;;
    esac
  }

  module_label() {
    case "${1:-}" in
      ansible) printf '%s\n' "Ansible" ;;
      virtualization) printf '%s\n' "VirtualBox and Vagrant" ;;
      docker) printf '%s\n' "Docker Engine/Desktop and Compose" ;;
      *) return 1 ;;
    esac
  }

  list_modules() {
    local module_id
    printf '%s %s modules:\n' "$ENV_FORGE_NAME" "$ENV_FORGE_VERSION"
    for module_id in "${ENV_FORGE_MODULES[@]}"; do
      printf '  %-15s %s\n' "$module_id" "$(module_label "$module_id")"
    done
  }

  tool_command() {
    case "${1:-}" in
      ansible) printf '%s\n' ansible ;;
      docker) printf '%s\n' docker ;;
      docker_compose) printf '%s\n' docker ;;
      virtualbox) printf '%s\n' VBoxManage ;;
      vagrant) printf '%s\n' vagrant ;;
      *) return 1 ;;
    esac
  }

  tool_label() {
    case "${1:-}" in
      ansible) printf '%s\n' "Ansible" ;;
      docker) printf '%s\n' "Docker Engine" ;;
      docker_compose) printf '%s\n' "Docker Compose" ;;
      virtualbox) printf '%s\n' "VirtualBox" ;;
      vagrant) printf '%s\n' "Vagrant" ;;
      *) return 1 ;;
    esac
  }

  tool_hint() {
    case "${1:-}" in
      ansible) printf '%s\n' "./setup.sh --module ansible" ;;
      docker | docker_compose) printf '%s\n' "./setup.sh --module docker" ;;
      virtualbox | vagrant) printf '%s\n' "./setup.sh --module virtualization" ;;
      *) return 1 ;;
    esac
  }

  tool_version() {
    case "${1:-}" in
      ansible) ansible --version 2>/dev/null ;;
      docker) docker --version 2>/dev/null ;;
      docker_compose) docker compose version 2>/dev/null || docker-compose --version 2>/dev/null ;;
      virtualbox) VBoxManage --version 2>/dev/null ;;
      vagrant) vagrant --version 2>/dev/null ;;
      *) return 1 ;;
    esac
  }

  tool_available() {
    case "${1:-}" in
      docker_compose)
        if command -v docker >/dev/null 2>&1 &&
          docker compose version >/dev/null 2>&1; then
          return 0
        fi
        if command -v docker-compose >/dev/null 2>&1 &&
          docker-compose --version >/dev/null 2>&1; then
          return 0
        fi
        return 1
        ;;
      *)
        command -v "$(tool_command "$1")" >/dev/null 2>&1
        ;;
    esac
  }

  check_environment() {
    local tool_id command_name version hint missing=0
    printf '%s %s environment check\n' "$ENV_FORGE_NAME" "$ENV_FORGE_VERSION"
    printf 'Platform: %s (%s)\n\n' "${PLATFORM_LABEL:-unknown}" "${PACKAGE_MANAGER:-unknown}"
    for tool_id in "${ENV_FORGE_TOOLS[@]}"; do
      hint="$(tool_hint "$tool_id")"
      if tool_available "$tool_id"; then
        version="$(tool_version "$tool_id" || true)"
        version="${version%%$'\n'*}"
        version="${version%$'\r'}"
        printf '  [ok]      %-15s %s\n' "$(tool_label "$tool_id")" "${version:-installed (version unavailable)}"
      else
        printf '  [missing] %-15s install with %s\n' "$(tool_label "$tool_id")" "$hint"
        missing=1
      fi
    done
    if ((missing == 1)); then
      printf '\nSome tools are missing. Review the plan with: ./setup.sh --dry-run --all\n'
      return 1
    fi
    printf '\nAll checked tools are installed.\n'
  }

  run_standalone_module() {
    local function_name="$1"
    shift
    local assume_yes=0
    local dry_run="${ENV_FORGE_DRY_RUN:-0}"
    local module_dir module_script module_name
    module_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd -P)"
    module_script="$(basename -- "${BASH_SOURCE[1]}")"
    module_name="${module_script%.sh}"

    while (($# > 0)); do
      case "$1" in
        --dry-run|-n)
          dry_run=1
          shift
          ;;
        --yes|-y)
          assume_yes=1
          shift
          ;;
        --help|-h)
          printf 'Usage: %s [--dry-run] [--yes] [--help]\n\n' "$module_script"
          printf 'Run the %s module of %s %s.\n' "$module_name" "$ENV_FORGE_NAME" "$ENV_FORGE_VERSION"
          return 0
          ;;
        *)
          printf 'Unknown option: %s\n' "$1" >&2
          printf 'Usage: %s [--dry-run] [--yes] [--help]\n' "$module_script" >&2
          return 2
          ;;
      esac
    done

    ENV_FORGE_DRY_RUN="$dry_run"
    export ENV_FORGE_DRY_RUN
    # shellcheck source=lib/common.sh
    source "$module_dir/../lib/common.sh"
    init_logging || return $?
    log INFO "Starting $ENV_FORGE_NAME $ENV_FORGE_VERSION module: $module_name."
    detect_platform /etc/os-release "$(uname -s)" || return $?
    log INFO "Detected platform: $PLATFORM_LABEL ($PACKAGE_MANAGER)."
    preflight || return $?
    if [[ "$dry_run" != "1" && "$assume_yes" != "1" ]]; then
      local response
      if ! read -r -p "Run $module_name? This can change your system. [y/N]: " response ||
        [[ "$response" != "y" && "$response" != "Y" ]]; then
        log INFO "Module cancelled by user."
        return 0
      fi
    fi
    "$function_name"
  }
fi
