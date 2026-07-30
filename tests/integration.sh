#!/bin/bash
#
# Copyright 2026 The Apache Software Foundation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu

# This script stays the stable public entrypoint for the integration suite.
# It now delegates to sourced helper and scenario modules so the suite remains
# easy to navigate without changing `make test` or CI invocation shape.

TESTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TOOL_DIR=$(CDPATH= cd -- "$TESTS_DIR/.." && pwd)
BUILD_DIR=$TOOL_DIR/build/tests
UPDATED_GRADLE_VERSION=${UPDATED_GRADLE_VERSION:-9.6.1}
TWO_SEGMENT_GRADLE_VERSION=${TWO_SEGMENT_GRADLE_VERSION:-8.14}
HELPER_MAX_METADATA_BYTES=65536
HELPER_MAX_JAR_BYTES=10485760
INSTALLER_MAX_TOOL_FILE_BYTES=262144
POWERSHELL_HTTP_TIMEOUT_SECONDS_FOR_TESTS=2

CAPTURED_OUTPUT=''
CAPTURED_OUTPUT_NORMALIZED=''
CAPTURED_STATUS=0
TEST_HTTP_SERVER_PID=''
TEST_HTTP_SERVER_PORT=''
TEST_HTTP_SERVER_LOG=''
TEST_HTTP_SERVER_PORT_FILE=''
BOOTSTRAP_TEST_GPG_HOME=''
BOOTSTRAP_TEST_SIGNER_FINGERPRINT=''
BOOTSTRAP_TEST_PUBLIC_KEY_PATH=''

# shellcheck source=tests/lib/integration-common.sh
. "$TESTS_DIR/lib/integration-common.sh"
# shellcheck source=tests/lib/integration-fixtures.sh
. "$TESTS_DIR/lib/integration-fixtures.sh"
# shellcheck source=tests/suites/integration-installer.sh
. "$TESTS_DIR/suites/integration-installer.sh"
# shellcheck source=tests/suites/integration-helper-edge.sh
. "$TESTS_DIR/suites/integration-helper-edge.sh"
# shellcheck source=tests/suites/integration-init-script.sh
. "$TESTS_DIR/suites/integration-init-script.sh"
# shellcheck source=tests/suites/integration-bootstrap.sh
. "$TESTS_DIR/suites/integration-bootstrap.sh"

# Run the full default integration suite used by `make test`, including the
# installer, helper edge-case, init-script, and bootstrap scenario groups.
run_default_integration_suite() {
  require_base_commands
  require_command pwsh
  test_root=$(mktemp -d "$BUILD_DIR/integration.XXXXXX")
  trap 'stop_test_http_server; rm -rf "$test_root"' EXIT HUP INT TERM

  log "starting default integration suite (test_root='$test_root')"
  run_installer_suite "$test_root" "$test_root/posix-installer" "$test_root/powershell-installer"
  run_helper_edge_case_suite "$test_root" "$test_root/posix-installer" "$test_root/powershell-installer"
  run_init_script_focused_suite "$test_root"
  run_bootstrap_suite "$test_root"
  log 'all helper-tool integration checks passed.'
}

# Run one version-exercise entry under a controlled Java/Gradle toolchain so the
# caller can probe support for a single target wrapper version.
run_single_version_exercise() {
  bootstrap_gradle_version=$1
  target_version=$2
  require_base_commands
  test_root=$(mktemp -d "$BUILD_DIR/version-single.XXXXXX")
  trap 'rm -rf "$test_root"' EXIT HUP INT TERM

  version_exercise_java_version=$(select_sdkman_java_version_for_version_exercise)
  log "starting single-version exercise (test_root='$test_root', bootstrap Gradle='$bootstrap_gradle_version', target Gradle='$target_version', Java='$version_exercise_java_version')"
  use_sdkman_java_version "$version_exercise_java_version"
  exercise_wrapper_update_to_version "$test_root/version-$target_version" "$bootstrap_gradle_version" "$target_version"
  log "Gradle $target_version wrapper exercise passed (bootstrap Gradle: $bootstrap_gradle_version, Java: $version_exercise_java_version)."
}

# Run the single-version exercise for many targets and summarize which Gradle
# versions passed or failed in this environment.
run_version_list_exercise() {
  [ "$#" -ge 1 ] || fail 'version-list requires a bootstrap Gradle version followed by one or more explicit target versions.'
  bootstrap_gradle_version=$1
  shift
  [ "$#" -ge 1 ] || fail 'version-list requires one or more explicit target Gradle versions.'
  mkdir -p "$BUILD_DIR/version-list"

  passed_versions=''
  failed_versions=''

  log "using SDKMAN bootstrap Gradle $bootstrap_gradle_version for fixture initialization."
  for target_version in "$@"; do
    log_path="$BUILD_DIR/version-list/$(sanitize_for_path "$target_version").log"
    log "starting version-list entry for Gradle '$target_version' (log='$log_path')"
    if bash "$0" single-version "$bootstrap_gradle_version" "$target_version" >"$log_path" 2>&1; then
      log "PASS Gradle $target_version (log: $log_path)"
      passed_versions="${passed_versions}${passed_versions:+ }$target_version"
    else
      echo "integration-test: FAIL Gradle $target_version (log: $log_path)" >&2
      failed_versions="${failed_versions}${failed_versions:+ }$target_version"
    fi
  done

  [ -n "$passed_versions" ] && log "supported versions in this run: $passed_versions"
  if [ -n "$failed_versions" ]; then
    echo "integration-test: unsupported or failing versions in this run: $failed_versions" >&2
    return 1
  fi
}

# Dispatch the script's supported modes so the same file can serve both the
# default integration suite and the explicit version-exercise entrypoints.
main() {
  mode=${1:-default}
  case "$mode" in
    default)
      run_default_integration_suite
      ;;
    single-version)
      [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail 'single-version requires one target version or a bootstrap-version/target-version pair.'
      run_single_version_exercise "$2" "${3:-$2}"
      ;;
    version-list)
      shift
      run_version_list_exercise "$@"
      ;;
    *)
      fail "unknown mode '$mode' (expected: default, single-version, version-list)."
      ;;
  esac
}

main "$@"
