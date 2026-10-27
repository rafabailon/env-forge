#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=modules/install_ansible.sh
source "$ROOT_DIR/modules/install_ansible.sh"
# shellcheck source=modules/install_virtualization.sh
source "$ROOT_DIR/modules/install_virtualization.sh"
# shellcheck source=modules/install_docker.sh
source "$ROOT_DIR/modules/install_docker.sh"

FINAL_STATUS=0
SELECTED_MODULES=()
ASSUME_YES=0
INTERACTIVE=1
RUN_ALL=0
ACTION="run"

usage() {
  cat <<EOF
$ENV_FORGE_NAME $ENV_FORGE_VERSION

Usage: ./setup.sh [OPTIONS]

Run the interactive installer, or select modules non-interactively.

Options:
  -n, --dry-run        Show planned commands without changing the system.
  -c, --check          Report whether the managed tools are installed. No changes.
  -m, --module NAME    Run one module non-interactively. Repeat for several.
  -a, --all            Run all modules non-interactively.
  -y, --yes            Skip confirmation prompts. Use only when intentional.
      --log-file FILE  Write the session log to FILE.
  -l, --list           List available modules and exit.
  -V, --version        Print the version and exit.
  -h, --help           Show this help and exit.

Modules: ${ENV_FORGE_MODULES[*]}
EOF
}

add_selected_module() {
  local module_id="$1" existing
  if ((${#SELECTED_MODULES[@]} > 0)); then
    for existing in "${SELECTED_MODULES[@]}"; do
      if [[ "$existing" == "$module_id" ]]; then
        return 0
      fi
    done
  fi
  SELECTED_MODULES+=("$module_id")
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --dry-run|-n)
        ENV_FORGE_DRY_RUN=1
        export ENV_FORGE_DRY_RUN
        ;;
      --check|-c)
        ACTION="check"
        ;;
      --log-file)
        if (($# < 2)) || [[ -z "$2" ]]; then
          log ERROR "Option $1 requires a file path."
          return 2
        fi
        LOG_FILE="$2"
        export LOG_FILE
        shift
        ;;
      --module|-m)
        if (($# < 2)); then
          log ERROR "Option $1 requires a module name."
          return 2
        fi
        if ! module_exists "$2"; then
          log ERROR "Unknown module: $2. Available modules: ${ENV_FORGE_MODULES[*]}"
          return 2
        fi
        add_selected_module "$2"
        INTERACTIVE=0
        shift
        ;;
      --all|-a)
        RUN_ALL=1
        INTERACTIVE=0
        ;;
      --yes|-y)
        ASSUME_YES=1
        ;;
      --list|-l)
        ACTION="list"
        ;;
      --version|-V)
        ACTION="version"
        ;;
      --help|-h)
        ACTION="help"
        ;;
      --)
        shift
        break
        ;;
      *)
        log ERROR "Unknown option: $1"
        usage >&2
        return 2
        ;;
    esac
    shift
  done
  if (($# > 0)); then
    log ERROR "Unexpected argument: $1"
    usage >&2
    return 2
  fi
  if ((RUN_ALL == 1 && ${#SELECTED_MODULES[@]} > 0)); then
    log ERROR "Use either --all or --module, not both."
    return 2
  fi
  return 0
}

main() {
  parse_args "$@" || return $?
  case "$ACTION" in
    help)
      usage
      return 0
      ;;
    version)
      printf '%s %s\n' "$ENV_FORGE_NAME" "$ENV_FORGE_VERSION"
      return 0
      ;;
    list)
      list_modules
      return 0
      ;;
    check)
      if ! detect_platform /etc/os-release "$(uname -s)"; then
        FINAL_STATUS=1
        return 0
      fi
      if ! check_environment; then
        FINAL_STATUS=1
      fi
      return 0
      ;;
  esac

  if ! init_logging; then
    FINAL_STATUS=1
    return 0
  fi
  trap on_error ERR
  log INFO "Starting $ENV_FORGE_NAME $ENV_FORGE_VERSION."
  log INFO "Log file: $LOG_FILE"

  if ((INTERACTIVE == 0)) &&
    [[ "${ENV_FORGE_DRY_RUN:-0}" != "1" ]] &&
    ((ASSUME_YES == 0)) &&
    [[ ! -t 0 ]]; then
    log ERROR "Non-interactive run requires --yes (or --dry-run)."
    FINAL_STATUS=2
    return 0
  fi

  if ! detect_platform /etc/os-release "$(uname -s)"; then
    FINAL_STATUS=1
    return 0
  fi
  log INFO "Detected platform: $PLATFORM_LABEL ($PACKAGE_MANAGER)."
  if ! preflight; then
    FINAL_STATUS=1
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 && "$PLATFORM_FAMILY" == "debian" ]]; then
    log WARN "Running as root. Docker group setup requires a non-root target user."
  fi

  if ((INTERACTIVE == 0)); then
    if ((RUN_ALL == 1)); then
      SELECTED_MODULES=("${ENV_FORGE_MODULES[@]}")
    fi
    run_selected_modules
    return 0
  fi

  interactive_menu
  return 0
}

interactive_menu() {
  local module_count=${#ENV_FORGE_MODULES[@]}
  local choice=""
  local index module_id
  while true; do
    printf '\n%s %s\n' "$ENV_FORGE_NAME" "$ENV_FORGE_VERSION"
    printf 'Platform: %s (%s)\n' "$PLATFORM_LABEL" "$PACKAGE_MANAGER"
    index=1
    for module_id in "${ENV_FORGE_MODULES[@]}"; do
      printf '%d. Install %s\n' "$index" "$(module_label "$module_id")"
      index=$((index + 1))
    done
    printf '%d. Run all supported modules\n' "$index"
    printf '%d. Exit\n' "$((index + 1))"

    if ! read -r -p 'Choose an option: ' choice; then
      log INFO "Input closed; exiting."
      return 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if ((choice >= 1 && choice <= module_count)); then
        module_id="${ENV_FORGE_MODULES[$((choice - 1))]}"
        run_module "$module_id" || FINAL_STATUS=1
        continue
      fi
      if ((choice == module_count + 1)); then
        run_all_interactive
        continue
      fi
      if ((choice == module_count + 2)); then
        log INFO "Setup finished by user."
        return 0
      fi
    fi
    log WARN "Choose an option from 1 to $((module_count + 2))."
  done
}

run_all_interactive() {
  local module_id failures=0
  for module_id in "${ENV_FORGE_MODULES[@]}"; do
    if ! run_module "$module_id"; then
      failures=$((failures + 1))
      log WARN "Module $module_id failed; continuing with the remaining modules."
    fi
  done
  if ((failures > 0)); then
    log ERROR "$failures module(s) failed."
    FINAL_STATUS=1
  else
    log INFO "All modules completed."
  fi
}

run_selected_modules() {
  local module_id failures=0
  for module_id in "${SELECTED_MODULES[@]}"; do
    if ! run_module "$module_id"; then
      failures=$((failures + 1))
    fi
  done
  if ((failures > 0)); then
    log ERROR "$failures of ${#SELECTED_MODULES[@]} selected module(s) failed."
    FINAL_STATUS=1
  else
    log INFO "All selected modules completed."
  fi
}

run_module() {
  local module_id="$1"
  local function_name label status=0
  if ! function_name="$(module_function "$module_id")"; then
    log ERROR "Unknown module: $module_id"
    return 1
  fi
  label="$(module_label "$module_id")"
  if ! confirm_action "$label"; then
    log INFO "$label module skipped."
    return 0
  fi
  "$function_name" || status=$?
  if ((status == 0)); then
    log INFO "$label module completed."
  else
    log ERROR "$label module failed with exit code $status."
  fi
  return "$status"
}

confirm_action() {
  local label="$1"
  if [[ "${ENV_FORGE_DRY_RUN:-0}" == "1" || "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  local response
  if ! read -r -p "Run $label? This can change your system. [y/N]: " response; then
    log ERROR "No confirmation input available; skipping $label."
    return 1
  fi
  [[ "$response" == "y" || "$response" == "Y" ]]
}

# shellcheck disable=SC2317  # Invoked indirectly by the ERR trap.
on_error() {
  local status=$?
  log ERROR "Setup stopped at line ${BASH_LINENO[0]} (exit code $status)."
  exit "$status"
}

main "$@" || exit $?
exit "$FINAL_STATUS"
