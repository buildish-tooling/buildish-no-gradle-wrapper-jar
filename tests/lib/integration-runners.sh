#!/bin/bash
#
# Copyright 2026 The Buildish Authors
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

# Run the generated wrapper for smoke checks where only success matters and the
# command output itself is not part of the assertion surface.
run_wrapper() {
  project_dir=$1
  shift
  log "running ./gradlew $* in '$project_dir' (GRADLE_USER_HOME='$(gradle_user_home "$project_dir")')"
  (cd "$project_dir" && GRADLE_USER_HOME=$(gradle_user_home "$project_dir") ./gradlew --no-daemon "$@" >/dev/null)
}

# Run the wrapper while capturing output so wrapper-update and failure-path tests
# can assert on emitted warnings and diagnostics.
run_wrapper_capture() {
  project_dir=$1
  shift
  output_file=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-test.XXXXXX")
  log "running ./gradlew $* in '$project_dir' (GRADLE_USER_HOME='$(gradle_user_home "$project_dir")')"
  set +e
  (cd "$project_dir" && GRADLE_USER_HOME=$(gradle_user_home "$project_dir") ./gradlew --no-daemon "$@") >"$output_file" 2>&1
  CAPTURED_STATUS=$?
  set -e
  store_captured_output_from_file "$output_file"
  rm -f "$output_file"
}

# Run plain Gradle with the checked-in init script attached so init-script-only
# tests can inspect its patching and warning behavior directly.
run_gradle_with_init_script_capture() {
  project_dir=$1
  shift
  output_file=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-test.XXXXXX")
  log "running gradle $* with init script in '$project_dir' (GRADLE_USER_HOME='$(gradle_user_home "$project_dir")')"
  set +e
  (cd "$project_dir" && GRADLE_USER_HOME=$(gradle_user_home "$project_dir") gradle -p "$project_dir" --no-daemon --console=plain --init-script "$(gradle_init_script_path "$project_dir")" "$@") >"$output_file" 2>&1
  CAPTURED_STATUS=$?
  set -e
  store_captured_output_from_file "$output_file"
  rm -f "$output_file"
}

# Run the POSIX installer in capture mode so installer tests can reuse the same
# assertion helpers as the PowerShell path.
run_posix_installer_capture() {
  project_dir=$1
  log "installing POSIX helper into '$project_dir'"
  run_and_capture sh "$TOOL_DIR/install.sh" --trusted-source-dir "$TOOL_DIR" "$project_dir"
}

# Run the PowerShell installer in capture mode so cross-platform installer tests
# share one assertion style after output normalization.
run_powershell_installer_capture() {
  project_dir=$1
  log "installing PowerShell helper into '$project_dir'"
  run_and_capture pwsh -NoLogo -NoProfile -File "$TOOL_DIR/install.ps1" --trusted-source-dir "$TOOL_DIR" "$project_dir"
}

# Run the POSIX unsafe-dev installer with captured output because these tests
# care about the warning banner and CI guardrails as much as the exit code.
run_posix_unsafe_dev_installer_capture() {
  project_dir=$1
  shift
  log "running POSIX unsafe dev installer into '$project_dir'"
  run_and_capture env "$@" sh "$TOOL_DIR/unsafe-dev-install.sh" --yes-i-know-this-is-unsafe "$project_dir"
}

# Run the PowerShell unsafe-dev installer with captured output so the same
# acknowledgement and CI-barrier checks apply on both platforms.
run_powershell_unsafe_dev_installer_capture() {
  project_dir=$1
  shift
  log "running PowerShell unsafe dev installer into '$project_dir'"
  run_and_capture env "$@" pwsh -NoLogo -NoProfile -File "$TOOL_DIR/unsafe-dev-install.ps1" --yes-i-know-this-is-unsafe "$project_dir"
}

# Run a POSIX bootstrap script against a fixture while capturing its signed
# bootstrap diagnostics for follow-up assertions.
run_posix_bootstrap_installer_capture() {
  bootstrap_script_path=$1
  project_dir=$2
  log "running POSIX bootstrap installer '$bootstrap_script_path' into '$project_dir'"
  run_and_capture sh "$bootstrap_script_path" "$project_dir"
}

# Run a rendered POSIX bootstrap with a short deadline for deterministic stalled
# response coverage.
run_posix_bootstrap_installer_capture_with_timeout() {
  bootstrap_script_path=$1
  project_dir=$2
  timeout_seconds=$3
  log "running POSIX bootstrap installer '$bootstrap_script_path' into '$project_dir' with timeout ${timeout_seconds}s"
  run_and_capture env BUILDISH_BOOTSTRAP_INSTALL_HTTP_TIMEOUT_SECONDS="$timeout_seconds" sh "$bootstrap_script_path" "$project_dir"
}

# Run a PowerShell bootstrap script against a fixture while capturing output in
# the normalized form needed for portable stderr assertions.
run_powershell_bootstrap_installer_capture() {
  bootstrap_script_path=$1
  project_dir=$2
  log "running PowerShell bootstrap installer '$bootstrap_script_path' into '$project_dir'"
  run_and_capture pwsh -NoLogo -NoProfile -File "$bootstrap_script_path" "$project_dir"
}

# Source the POSIX helper directly to exercise its recovery logic without going
# through the full launcher or Gradle process tree.
run_posix_helper_direct() {
  project_dir=$1
  helper_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.sh"
  log "running POSIX helper directly in '$project_dir'"
  run_and_capture env APP_HOME="$project_dir" sh -c 'helper_path=$1; set --; . "$helper_path"' sh "$helper_path"
}

# Run the POSIX helper with a short production-equivalent network deadline so
# stalled-response behavior can be tested without waiting for the default.
run_posix_helper_direct_with_timeout() {
  project_dir=$1
  timeout_seconds=$2
  helper_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.sh"
  log "running POSIX helper directly in '$project_dir' with timeout value '$timeout_seconds'"
  run_and_capture env APP_HOME="$project_dir" BUILDISH_NO_GRADLE_WRAPPER_JAR_HTTP_TIMEOUT_SECONDS="$timeout_seconds" sh -c 'helper_path=$1; set --; . "$helper_path"' sh "$helper_path"
}

# Source the POSIX helper and echo the resulting argv so init-script injection
# tests can reason about exact argument deduplication behavior.
run_posix_helper_direct_capture_args() {
  project_dir=$1
  shift
  helper_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.sh"
  log "running POSIX helper directly in '$project_dir' with args: $*"
  run_and_capture env APP_HOME="$project_dir" sh -c 'helper_path=$1; shift; set -- "$@"; . "$helper_path"; for arg do printf "%s\n" "$arg"; done' sh "$helper_path" "$@"
}

# Run the PowerShell helper directly and feed it synthetic original args so its
# launcher-argument injection logic can be tested in isolation.
run_powershell_helper_direct() {
  project_dir=$1
  original_args=${2:-}
  helper_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.ps1"
  log "running PowerShell helper directly in '$project_dir'"
  run_and_capture env APP_HOME="$project_dir" BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS="$original_args" pwsh -NoLogo -NoProfile -File "$helper_path"
}

# Run the PowerShell helper while retaining its stdout protocol and stderr
# diagnostics separately. Byte and line counts preserve an otherwise invisible
# empty protocol line after command substitution trims trailing newlines.
run_powershell_helper_direct_capture_streams() {
  project_dir=$1
  original_args=${2:-}
  timeout_seconds=${3-}
  helper_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.ps1"
  stdout_file=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-stdout.XXXXXX")
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-stderr.XXXXXX")
  log "running PowerShell helper directly with separate streams in '$project_dir'"

  set +e
  if [ "$#" -ge 3 ]; then
    env APP_HOME="$project_dir" BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS="$original_args" BUILDISH_NO_GRADLE_WRAPPER_JAR_HTTP_TIMEOUT_SECONDS="$timeout_seconds" pwsh -NoLogo -NoProfile -File "$helper_path" >"$stdout_file" 2>"$stderr_file"
  else
    env APP_HOME="$project_dir" BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS="$original_args" pwsh -NoLogo -NoProfile -File "$helper_path" >"$stdout_file" 2>"$stderr_file"
  fi
  CAPTURED_STATUS=$?
  set -e

  CAPTURED_STDOUT=$(cat "$stdout_file")
  CAPTURED_STDERR=$(cat "$stderr_file")
  CAPTURED_STDERR_NORMALIZED=$(normalize_output_file_for_assertions "$stderr_file")
  CAPTURED_STDOUT_BYTE_COUNT=$(wc -c < "$stdout_file" | tr -d '[:space:]')
  CAPTURED_STDOUT_LINE_COUNT=$(wc -l < "$stdout_file" | tr -d '[:space:]')
  rm -f "$stdout_file" "$stderr_file"
}

# Run the PowerShell helper with a shortened HTTP timeout so the timeout path is
# testable without waiting on production-sized retry windows.
run_powershell_helper_direct_with_timeout() {
  project_dir=$1
  timeout_seconds=$2
  original_args=${3:-}
  helper_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.ps1"
  log "running PowerShell helper directly in '$project_dir' with timeout value '$timeout_seconds'"
  run_and_capture env APP_HOME="$project_dir" BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS="$original_args" BUILDISH_NO_GRADLE_WRAPPER_JAR_HTTP_TIMEOUT_SECONDS="$timeout_seconds" pwsh -NoLogo -NoProfile -File "$helper_path"
}
