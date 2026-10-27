#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=modules/install_ansible.sh
source "$ROOT_DIR/modules/install_ansible.sh"
# shellcheck source=modules/install_virtualization.sh
source "$ROOT_DIR/modules/install_virtualization.sh"
# shellcheck source=modules/install_docker.sh
source "$ROOT_DIR/modules/install_docker.sh"

CHECKS=0
failures=0
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/env-forge-tests.XXXXXX")"

cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  failures=$((failures + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

assert_contains() {
  local output="$1" expected="$2" label="$3"
  if [[ "$output" == *"$expected"* ]]; then
    pass "$label"
  else
    fail "$label (missing: $expected)"
  fi
}

assert_not_contains() {
  local output="$1" unexpected="$2" label="$3"
  if [[ "$output" != *"$unexpected"* ]]; then
    pass "$label"
  else
    fail "$label (unexpected: $unexpected)"
  fi
}

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '$actual')"
  fi
}

assert_status() {
  local expected="$1" label="$2"
  shift 2
  local status=0
  "$@" >/dev/null 2>&1 || status=$?
  assert_equals "$status" "$expected" "$label"
}

assert_fails() {
  local label="$1"
  shift
  local status=0
  "$@" >/dev/null 2>&1 || status=$?
  if ((status != 0)); then
    pass "$label"
  else
    fail "$label (command unexpectedly succeeded)"
  fi
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

test_platform_detection() {
  printf 'ID=ubuntu\nID_LIKE=debian\n' >"$TEMP_DIR/os-release"
  detect_platform "$TEMP_DIR/os-release" Linux
  assert_contains "$PLATFORM_FAMILY:$PACKAGE_MANAGER:$PLATFORM_LABEL" "debian:apt-get:ubuntu" "Ubuntu platform detection"

  printf 'ID=linuxmint\nID_LIKE="ubuntu debian"\n' >"$TEMP_DIR/os-release"
  detect_platform "$TEMP_DIR/os-release" Linux
  assert_contains "$PLATFORM_FAMILY:$PACKAGE_MANAGER" "debian:apt-get" "Ubuntu derivative detection"

  printf 'ID="UBUNTU"\r\nID_LIKE="DEBIAN"\r\n' >"$TEMP_DIR/os-release"
  detect_platform "$TEMP_DIR/os-release" Linux
  assert_contains "$PLATFORM_FAMILY:$PACKAGE_MANAGER:$DISTRO_ID" "debian:apt-get:ubuntu" "Quoted, CRLF, and uppercase metadata are normalized"

  printf 'ID=debian\n' >"$TEMP_DIR/os-release"
  detect_platform "$TEMP_DIR/os-release" Linux
  assert_contains "$PLATFORM_FAMILY:$PACKAGE_MANAGER:$PLATFORM_LABEL" "debian:apt-get:debian" "Debian without ID_LIKE is detected"

  printf 'ID=fedora\nID_LIKE=fedora\n' >"$TEMP_DIR/os-release"
  assert_fails "Unsupported Linux distribution fails closed" detect_platform "$TEMP_DIR/os-release" Linux
  detect_platform "$TEMP_DIR/os-release" Darwin
  assert_contains "$PLATFORM_FAMILY:$PACKAGE_MANAGER" "macos:brew" "macOS platform detection"
}

test_branding_and_cli() {
  local output
  output="$("$ROOT_DIR/setup.sh" --version)"
  assert_equals "$output" "$ENV_FORGE_NAME $ENV_FORGE_VERSION" "Version reports the Env Forge name and version"
  if [[ "$ENV_FORGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "Version uses semantic versioning"
  else
    fail "Version uses semantic versioning (got: $ENV_FORGE_VERSION)"
  fi

  output="$("$ROOT_DIR/setup.sh" --help)"
  assert_contains "$output" "Env Forge" "Help uses the Env Forge name"
  assert_contains "$output" "--module" "Help documents module selection"
  assert_contains "$output" "--all" "Help documents running all modules"
  assert_contains "$output" "--check" "Help documents the environment check"
  assert_contains "$output" "--log-file" "Help documents the log file override"
  assert_not_contains "$output" "DevEnvironment" "Help no longer uses the old project name"

  output="$("$ROOT_DIR/setup.sh" --list)"
  assert_contains "$output" "ansible" "Module list includes Ansible"
  assert_contains "$output" "virtualization" "Module list includes virtualization"
  assert_contains "$output" "docker" "Module list includes Docker"
}

test_static_structure() {
  local executable script
  for executable in \
    "$ROOT_DIR/setup.sh" \
    "$ROOT_DIR/modules/install_ansible.sh" \
    "$ROOT_DIR/modules/install_virtualization.sh" \
    "$ROOT_DIR/modules/install_docker.sh"; do
    if [[ -x "$executable" ]]; then
      pass "Executable: ${executable#"$ROOT_DIR"/}"
    else
      fail "Executable: ${executable#"$ROOT_DIR"/}"
    fi
  done
  if [[ -r "$ROOT_DIR/lib/common.sh" ]]; then
    pass "Readable: lib/common.sh"
  else
    fail "Readable: lib/common.sh"
  fi
  for script in \
    "$ROOT_DIR/setup.sh" \
    "$ROOT_DIR/lib/common.sh" \
    "$ROOT_DIR/modules/install_ansible.sh" \
    "$ROOT_DIR/modules/install_virtualization.sh" \
    "$ROOT_DIR/modules/install_docker.sh" \
    "$ROOT_DIR/tests/test_setup.sh"; do
    if bash -n "$script"; then
      pass "Syntax: ${script#"$ROOT_DIR"/}"
    else
      fail "Syntax: ${script#"$ROOT_DIR"/}"
    fi
  done
}

test_module_registry() {
  local module_id function_name label unique_count
  for module_id in "${ENV_FORGE_MODULES[@]}"; do
    if ! function_name="$(module_function "$module_id")"; then
      fail "Module $module_id has a dispatch function"
      continue
    fi
    if declare -F "$function_name" >/dev/null; then
      pass "Module $module_id dispatches to $function_name"
    else
      fail "Module $module_id dispatches to a missing function: $function_name"
    fi
    if label="$(module_label "$module_id")" && [[ -n "$label" ]]; then
      pass "Module $module_id has a label"
    else
      fail "Module $module_id has a label"
    fi
  done
  unique_count="$(printf '%s\n' "${ENV_FORGE_MODULES[@]}" | sort -u | wc -l | tr -d ' ')"
  assert_equals "$unique_count" "${#ENV_FORGE_MODULES[@]}" "Module registry contains no duplicate identifiers"
  if module_function does-not-exist >/dev/null 2>&1; then
    fail "Unknown modules are rejected by the registry"
  else
    pass "Unknown modules are rejected by the registry"
  fi
}

test_dry_run_modules() {
  local output update_count
  export ENV_FORGE_DRY_RUN=1
  export SUDO_USER="${SUDO_USER:-$(id -un)}"
  if [[ "$SUDO_USER" == "root" ]]; then
    export SUDO_USER="nobody"
  fi
  PLATFORM_FAMILY=debian
  PACKAGE_MANAGER=apt-get
  PACKAGE_LISTS_UPDATED=0

  output="$(install_ansible_module)"
  assert_contains "$output" "apt-get update" "Ansible plan refreshes package lists"
  assert_contains "$output" "apt-get install -y ansible" "Ansible Debian install plan"

  output="$(install_virtualization_module)"
  assert_contains "$output" "apt-get install -y virtualbox vagrant" "VirtualBox/Vagrant Debian install plan"

  PACKAGE_LISTS_UPDATED=0
  {
    install_ansible_module
    install_virtualization_module
  } >"$TEMP_DIR/repeated-plans.log" 2>&1
  update_count="$(grep -c 'apt-get update' "$TEMP_DIR/repeated-plans.log" || true)"
  assert_equals "$update_count" "1" "Package lists are refreshed once per session"

  output="$(install_docker_module 2>&1)" || true
  assert_contains "$output" "apt-get install -y docker.io docker-compose-v2" "Docker Debian install plan"
  assert_contains "$output" "socket permissions" "Docker socket permissions are not weakened"
  assert_not_contains "$output" "chmod" "Docker installer never chmods the daemon socket"

  PLATFORM_FAMILY=macos
  PACKAGE_MANAGER=brew
  output="$(install_ansible_module)"
  assert_contains "$output" "brew install ansible" "Ansible macOS install plan"
  output="$(install_docker_module)"
  assert_contains "$output" "brew install --cask docker" "Docker Desktop macOS install plan"
  output="$(install_virtualization_module)"
  assert_contains "$output" "brew install --cask virtualbox" "VirtualBox macOS install plan"

  PLATFORM_FAMILY=unsupported
  PACKAGE_MANAGER=unknown
  assert_fails "Unsupported module platform is rejected" install_ansible_module
  unset ENV_FORGE_DRY_RUN
}

test_environment_check() {
  local all_bin="$TEMP_DIR/check-bin" partial_bin="$TEMP_DIR/check-partial-bin"
  local compose_bin="$TEMP_DIR/check-compose-bin"
  local output status tool
  mkdir -p "$all_bin" "$partial_bin" "$compose_bin"
  for tool in ansible docker VBoxManage vagrant; do
    printf '#!/bin/sh\nprintf "%%s 9.9.9\\n" "%s"\n' "$tool" >"$all_bin/$tool"
    chmod +x "$all_bin/$tool"
  done
  cp "$all_bin/ansible" "$partial_bin/ansible"
  printf '#!/bin/sh\ncase "$1" in\n  --version) printf "Docker version 9.9.9\\n" ;;\n  *) exit 1 ;;\nesac\n' >"$compose_bin/docker"
  chmod +x "$compose_bin/docker"

  PLATFORM_LABEL=ubuntu
  PACKAGE_MANAGER=apt-get
  status=0
  output="$(PATH="$all_bin" check_environment)" || status=$?
  assert_equals "$status" "0" "Environment check succeeds when every tool is present"
  assert_contains "$output" "Env Forge $ENV_FORGE_VERSION environment check" "Environment check reports the Env Forge name"
  assert_contains "$output" "Platform: ubuntu (apt-get)" "Environment check reports the platform"
  assert_contains "$output" "Docker Compose" "Environment check reports Docker Compose"
  assert_contains "$output" "All checked tools are installed" "Environment check reports a clean result"

  status=0
  output="$(PATH="$partial_bin" check_environment)" || status=$?
  assert_equals "$status" "1" "Environment check fails when tools are missing"
  assert_contains "$output" "[missing]" "Environment check marks missing tools"
  assert_contains "$output" "./setup.sh --module docker" "Environment check suggests the install module"

  status=0
  output="$(PATH="$compose_bin" check_environment)" || status=$?
  assert_equals "$status" "1" "Docker without Compose is not reported as a complete installation"
  assert_contains "$output" "[ok]      Docker Engine" "Environment check still recognizes Docker Engine"
  assert_contains "$output" "[missing] Docker Compose" "Environment check separates a missing Compose plugin"

  output="$("$ROOT_DIR/setup.sh" --check 2>&1)" || true
  assert_contains "$output" "environment check" "Setup --check runs the environment check"
  assert_contains "$output" "Platform:" "Setup --check reports the current platform"
}

test_docker_prerequisites() {
  local output status=0
  (
    PLATFORM_FAMILY=debian
    PACKAGE_MANAGER=apt-get
    PACKAGE_LISTS_UPDATED=0
    ENV_FORGE_DRY_RUN=0
    require_command() {
      if [[ "$1" == "getent" ]]; then
        log ERROR "Required command not found: $1"
        return 1
      fi
      return 0
    }
    run_privileged() {
      printf 'unexpected privileged command: %s\n' "$*"
      return 0
    }
    install_docker_module
  ) >"$TEMP_DIR/docker-prerequisites.log" 2>&1 || status=$?
  output="$(cat "$TEMP_DIR/docker-prerequisites.log")"
  assert_equals "$status" "1" "Docker module fails before install when prerequisites are missing"
  assert_contains "$output" "Required command not found: getent" "Missing Docker prerequisite is reported"
  assert_not_contains "$output" "apt-get update" "Docker install does not start after a failed prerequisite check"
}

test_logging_and_standalone_modules() {
  local output log_file mode default_log
  log_file="$TEMP_DIR/standalone.log"
  output="$(
    ENV_FORGE_DRY_RUN=1 ENV_FORGE_LOG_FILE="$log_file" \
      "$ROOT_DIR/modules/install_ansible.sh" 2>&1
  )"
  assert_contains "$output" "[dry-run]" "Standalone module supports the dry-run environment variable"
  mode="$(file_mode "$log_file")"
  assert_equals "$mode" "600" "Log file is private to its owner"
  assert_contains "$(cat "$log_file")" "Starting Env Forge" "Log file records the Env Forge startup line"

  output="$(
    ENV_FORGE_LOG_FILE="$TEMP_DIR/dry-run-flag.log" \
      "$ROOT_DIR/modules/install_ansible.sh" --dry-run 2>&1
  )"
  assert_contains "$output" "[dry-run]" "Standalone module accepts --dry-run"

  output="$("$ROOT_DIR/modules/install_ansible.sh" --help)"
  assert_contains "$output" "Usage:" "Standalone module help documents usage"
  assert_contains "$output" "install_ansible" "Standalone module help identifies the module"

  default_log="$(
    unset LOG_FILE XDG_STATE_HOME
    HOME="$TEMP_DIR/home"
    init_logging >/dev/null
    printf '%s\n' "$LOG_FILE"
  )"
  assert_contains "$default_log" "$TEMP_DIR/home/.local/state/env-forge/setup-" "Default log path uses the home state directory"
  assert_equals "$(file_mode "$default_log")" "600" "Default log file is private to its owner"
}

test_orchestrator_cli() {
  local output log_file update_count exit_choice count
  log_file="$TEMP_DIR/orchestrator.log"

  output="$(
    ENV_FORGE_DRY_RUN=1 ENV_FORGE_LOG_FILE="$log_file" \
      "$ROOT_DIR/setup.sh" --module ansible 2>&1
  )"
  assert_contains "$output" "Installing Ansible" "Orchestrator runs a selected module"
  assert_not_contains "$output" "Installing Docker" "Orchestrator runs only the selected module"
  assert_contains "$output" "All selected modules completed" "Selected module run reports success"

  output="$(
    ENV_FORGE_DRY_RUN=1 ENV_FORGE_LOG_FILE="$TEMP_DIR/all.log" \
      "$ROOT_DIR/setup.sh" --all 2>&1
  )"
  assert_contains "$output" "Installing Ansible" "All-module run plans Ansible"
  assert_contains "$output" "Installing VirtualBox" "All-module run plans VirtualBox and Vagrant"
  assert_contains "$output" "Installing Docker" "All-module run plans Docker"
  assert_contains "$output" "[dry-run]" "All-module run renders commands"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    assert_contains "$output" "brew install --cask docker" "All-module macOS run plans Docker Desktop"
  else
    assert_contains "$output" "socket permissions" "All-module Linux run preserves socket permissions"
    update_count="$(grep -c 'apt-get update' <<<"$output" || true)"
    assert_equals "$update_count" "1" "All-module run refreshes package lists once"
  fi

  assert_status 2 "Unknown module is rejected" \
    "$ROOT_DIR/setup.sh" --module does-not-exist --dry-run
  assert_status 2 "Unknown option is rejected" \
    "$ROOT_DIR/setup.sh" --unknown-option
  assert_status 2 "Conflicting selection options are rejected" \
    "$ROOT_DIR/setup.sh" --all --module ansible --dry-run
  assert_status 2 "Missing --log-file value is rejected" \
    "$ROOT_DIR/setup.sh" --log-file

  output="$(
    ENV_FORGE_DRY_RUN=1 ENV_FORGE_LOG_FILE="$TEMP_DIR/dedupe.log" \
      "$ROOT_DIR/setup.sh" --module ansible --module ansible 2>&1
  )"
  count="$(grep -c 'Installing Ansible' <<<"$output" || true)"
  assert_equals "$count" "1" "Duplicate module selections run only once"

  output="$(
    ENV_FORGE_DRY_RUN=1 ENV_FORGE_LOG_FILE="$TEMP_DIR/env-log.log" \
      "$ROOT_DIR/setup.sh" --module ansible --log-file "$TEMP_DIR/cli-log.log" 2>&1
  )"
  assert_contains "$output" "Log file: $TEMP_DIR/cli-log.log" "CLI log file override is reported"
  assert_equals "$(file_mode "$TEMP_DIR/cli-log.log")" "600" "CLI log file is private to its owner"
  if [[ ! -e "$TEMP_DIR/env-log.log" ]]; then
    pass "CLI log file takes precedence over the environment variable"
  else
    fail "CLI log file takes precedence over the environment variable"
  fi

  run_without_confirmation() {
    env ENV_FORGE_DRY_RUN=0 ENV_FORGE_LOG_FILE="$TEMP_DIR/no-confirmation.log" \
      "$ROOT_DIR/setup.sh" --all </dev/null
  }
  assert_status 2 "Non-interactive run without --yes fails closed" run_without_confirmation

  exit_choice=$((${#ENV_FORGE_MODULES[@]} + 2))
  output="$(
    printf '%s\n' "$exit_choice" |
      ENV_FORGE_DRY_RUN=1 ENV_FORGE_LOG_FILE="$TEMP_DIR/menu.log" \
        "$ROOT_DIR/setup.sh" 2>&1
  )"
  assert_contains "$output" "Setup finished by user" "Interactive menu exits cleanly"
}

test_module_stops_after_failed_update() {
  local output status=0
  (
    PLATFORM_FAMILY=debian
    PACKAGE_MANAGER=apt-get
    PACKAGE_LISTS_UPDATED=0
    ENV_FORGE_DRY_RUN=0
    run_privileged() {
      printf 'mock command: %s\n' "$*"
      return 23
    }
    install_ansible_module
  ) >"$TEMP_DIR/failed-update.log" 2>&1 || status=$?
  output="$(cat "$TEMP_DIR/failed-update.log")"
  assert_equals "$status" "23" "Repository update failure status is preserved"
  assert_contains "$output" "mock command: apt-get update" "Repository update failure is surfaced"
  assert_not_contains "$output" "apt-get install" "Package installation stops after update failure"
}

test_platform_detection
test_branding_and_cli
test_static_structure
test_module_registry
test_dry_run_modules
test_environment_check
test_docker_prerequisites
test_logging_and_standalone_modules
test_orchestrator_cli
test_module_stops_after_failed_update

if ((failures > 0)); then
  printf '\n%d of %d check(s) failed.\n' "$failures" "$CHECKS" >&2
  exit 1
fi
printf '\nAll %d Env Forge checks passed.\n' "$CHECKS"
