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

# Installer-focused scenarios for tests/integration.sh. The entrypoint sources
# this after the shared helper libraries.

# Exercise the shared output normalizer itself so future assertion cleanups do
# not regress either the PowerShell or plain-Linux output contracts.
exercise_output_normalization_contract() {
  output_file=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-test.XXXXXX")

  log 'checking captured-output normalization contract'
  cat >"$output_file" <<'EOF'
Exception: /tmp/bootstrap-install.ps1:47
Line |
  47 |  throw 'This checked-in bootstrap-install.ps1 still contains unreplace …
     |  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     | This checked-in bootstrap-install.ps1 still contains unreplaced release
     | placeholders. Use a release-generated bootstrap-install.ps1 or the
     | reviewed local-copy/manual-verification flow.
EOF
  store_captured_output_from_file "$output_file"
  assert_last_output_contains 'release placeholders' 'normalized PowerShell stderr did not collapse wrapped message fragments into one searchable sentence.'
  [ "$CAPTURED_OUTPUT" != "$CAPTURED_OUTPUT_NORMALIZED" ] || fail 'PowerShell stderr normalization did not remove the presentation-only render block.'

  python3 - <<'PY' "$output_file"
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(
    b'\x1b[31;1mWrite-Error: /tmp/buildish-no-gradle-wrapper-jar.ps1:708\x1b[0m\n'
    b'\x1b[31;1mLine |\x1b[0m\n'
    b'\x1b[31;1m 708 |  \xe2\x80\xa6 Write-Error "buildish-no-gradle-wrapper-jar: $($_.Exception.Message)"\x1b[0m\n'
    b'\x1b[31;1m     |                                                   ~~~~~~~~~~~~~~~~~~~~\x1b[0m\n'
    b'\x1b[31;1m     | buildish-no-gradle-wrapper-jar: wrapper checksum must not be a symbolic\x1b[0m\n'
    b'\x1b[31;1m     | link:\x1b[0m\n'
    b"\x1b[31;1m     | '/tmp/gradle-wrapper-8.14.4.sha256'.\x1b[0m\n"
)
PY
  store_captured_output_from_file "$output_file"
  assert_last_output_contains 'wrapper checksum must not be a symbolic link:' 'normalized PowerShell Write-Error stderr did not collapse wrapped message fragments into one searchable sentence when ANSI terminal sequences were present.'
  assert_last_output_not_contains 'Line |' 'normalized PowerShell Write-Error stderr still contained the presentation-only render block header.'

  cat >"$output_file" <<'EOF'
plain linux stderr line
EOF
  store_captured_output_from_file "$output_file"
  [ "$CAPTURED_OUTPUT" = "$CAPTURED_OUTPUT_NORMALIZED" ] || fail 'Linux/plain stderr should be left unchanged by captured-output normalization.'

  rm -f "$output_file"
}

# Exercise installer failure when gradle-wrapper.properties is missing, because
# patching without wrapper metadata would leave the project in an unknown state.
exercise_installer_missing_properties_failure() {
  project_dir=$1
  installer_kind=$2

  log "exercising $installer_kind installer missing-properties failure in '$project_dir'"
  gradle_init_fixture "$project_dir"
  rm -f "$project_dir/gradle/wrapper/gradle-wrapper.properties"

  "run_${installer_kind}_installer_capture" "$project_dir"
  assert_last_command_failed "$installer_kind installer unexpectedly succeeded without gradle-wrapper.properties."
  assert_last_output_contains 'Gradle wrapper properties file was not found' "$installer_kind installer failure output did not mention the missing gradle-wrapper.properties file."
}

# Exercise the installer CLI guard that requires an explicit trusted source dir
# before helper files are copied into a project.
exercise_installer_requires_trusted_source_dir_failure() {
  project_dir=$1
  installer_kind=$2

  log "exercising $installer_kind installer missing --trusted-source-dir failure in '$project_dir'"
  gradle_init_fixture "$project_dir"

  case "$installer_kind" in
    posix)
      run_and_capture sh "$TOOL_DIR/install.sh" "$project_dir"
      ;;
    powershell)
      run_and_capture pwsh -NoLogo -NoProfile -File "$TOOL_DIR/install.ps1" "$project_dir"
      ;;
    *)
      fail "unknown installer kind '$installer_kind'"
      ;;
  esac

  assert_last_command_failed "$installer_kind installer unexpectedly succeeded without --trusted-source-dir."
  assert_last_output_contains 'trusted-source-dir is required' "$installer_kind installer failure output did not explain that --trusted-source-dir is mandatory."
}

# Exercise the unsafe-dev installer acknowledgement guard so the dangerous flow
# cannot run without an explicit opt-in flag.
exercise_unsafe_dev_installer_requires_acknowledgement_failure() {
  project_dir=$1
  installer_kind=$2

  log "exercising $installer_kind unsafe dev installer missing-acknowledgement failure in '$project_dir'"
  gradle_init_fixture "$project_dir"

  case "$installer_kind" in
    posix)
      run_and_capture sh "$TOOL_DIR/unsafe-dev-install.sh" "$project_dir"
      ;;
    powershell)
      run_and_capture pwsh -NoLogo -NoProfile -File "$TOOL_DIR/unsafe-dev-install.ps1" "$project_dir"
      ;;
    *)
      fail "unknown installer kind '$installer_kind'"
      ;;
  esac

  assert_last_command_failed "$installer_kind unsafe dev installer unexpectedly succeeded without the unsafe acknowledgement flag."
  assert_last_output_contains 'yes-i-know-this-is-unsafe' "$installer_kind unsafe dev installer failure output did not mention the mandatory unsafe acknowledgement flag."
}

# Exercise the unsafe-dev installer CI barrier so the intentionally unsafe flow
# refuses to run in automated environments.
exercise_unsafe_dev_installer_ci_barrier_failure() {
  project_dir=$1
  installer_kind=$2

  log "exercising $installer_kind unsafe dev installer CI barrier in '$project_dir'"
  gradle_init_fixture "$project_dir"

  case "$installer_kind" in
    posix)
      run_and_capture env CI=true sh "$TOOL_DIR/unsafe-dev-install.sh" --yes-i-know-this-is-unsafe "$project_dir"
      ;;
    powershell)
      run_and_capture env CI=true pwsh -NoLogo -NoProfile -File "$TOOL_DIR/unsafe-dev-install.ps1" --yes-i-know-this-is-unsafe "$project_dir"
      ;;
    *)
      fail "unknown installer kind '$installer_kind'"
      ;;
  esac

  assert_last_command_failed "$installer_kind unsafe dev installer unexpectedly ran in a CI-marked environment."
  assert_last_output_contains 'not suitable for CI environments' "$installer_kind unsafe dev installer failure output did not mention that the script is not suitable for CI environments."
}

# Exercise the unsafe-dev installer happy path on a localhost mirror so the
# warning banner and helper installation still get a smoke test outside CI.
exercise_unsafe_dev_installer_success() {
  project_dir=$1
  installer_kind=$2

  if current_environment_looks_like_ci; then
    log "skipping $installer_kind unsafe dev installer success path because the current environment already looks like CI."
    return 0
  fi

  log "exercising $installer_kind unsafe dev installer success path in '$project_dir'"
  gradle_init_fixture "$project_dir"
  start_static_http_server "$TOOL_DIR"

  case "$installer_kind" in
    posix)
      run_posix_unsafe_dev_installer_capture "$project_dir" BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL="http://127.0.0.1:$TEST_HTTP_SERVER_PORT"
      ;;
    powershell)
      run_powershell_unsafe_dev_installer_capture "$project_dir" BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL="http://127.0.0.1:$TEST_HTTP_SERVER_PORT"
      ;;
    *)
      stop_test_http_server
      fail "unknown installer kind '$installer_kind'"
      ;;
  esac

  stop_test_http_server
  assert_last_command_succeeded "$installer_kind unsafe dev installer failed during the happy-path smoke test."
  assert_last_output_contains 'downloads and executes unverified content' "$installer_kind unsafe dev installer did not emit the loud unsafe warning banner."
  assert_helper_files "$project_dir"
}

# Exercise the end-to-end POSIX installer flow, then upgrade the wrapper to a
# target version and verify the helper still patches and recovers correctly.
exercise_wrapper_update_to_version() {
  project_dir=$1
  bootstrap_gradle_version=$2
  target_version=$3

  log "starting wrapper exercise for target Gradle '$target_version' in '$project_dir'"
  gradle_init_fixture "$project_dir" "$bootstrap_gradle_version"
  run_posix_installer_capture "$project_dir"
  assert_last_command_succeeded 'POSIX installer failed during the wrapper exercise.'
  assert_installer_distribution_sha_warning_output 'POSIX installer'
  [ ! -e "$project_dir/gradle/wrapper/gradle-wrapper.jar" ] || fail 'install.sh should remove the existing gradle-wrapper.jar.'
  assert_helper_files "$project_dir"
  assert_launcher_patches "$project_dir"
  assert_gitignore_updates "$project_dir"

  log "verifying freshly installed helper for '$project_dir'"
  run_wrapper "$project_dir" help
  initial_version=$(extract_gradle_version "$project_dir")
  [ -n "$initial_version" ] || fail 'unable to extract the initial Gradle version after install.sh.'
  assert_metadata_for_version "$project_dir" "$initial_version"

  log "upgrading wrapper in '$project_dir' from '$initial_version' to '$target_version'"
  run_wrapper_capture "$project_dir" wrapper --gradle-version "$target_version" --distribution-type bin
  assert_last_command_succeeded 'Gradle wrapper update failed during the wrapper exercise.'
  assert_init_distribution_sha_warning_output 'Gradle init script'
  updated_version=$(extract_gradle_version "$project_dir")
  [ "$updated_version" = "$target_version" ] || fail "expected updated Gradle version '$target_version' but found '$updated_version'."
  assert_launcher_patches "$project_dir"

  log "verifying upgraded helper for '$project_dir' at Gradle '$updated_version'"
  run_wrapper "$project_dir" help
  assert_metadata_for_version "$project_dir" "$updated_version"
}

# Run the default PowerShell installer smoke path and verify the installed
# helper/launcher artifacts behave like the POSIX path.
run_powershell_installer_flow() {
  project_dir=$1
  log "running default PowerShell installer flow in '$project_dir'"
  gradle_init_fixture "$project_dir"
  run_powershell_installer_capture "$project_dir"
  assert_last_command_succeeded 'PowerShell installer failed during the default integration flow.'
  assert_installer_distribution_sha_warning_output 'PowerShell installer'
  [ ! -e "$project_dir/gradle/wrapper/gradle-wrapper.jar" ] || fail 'install.ps1 should remove the existing gradle-wrapper.jar.'
  assert_helper_files "$project_dir"
  assert_launcher_patches "$project_dir"
  assert_gitignore_updates "$project_dir"

  log "verifying PowerShell-installed helper for '$project_dir'"
  run_wrapper "$project_dir" help
  installed_version=$(extract_gradle_version "$project_dir")
  [ -n "$installed_version" ] || fail 'unable to extract the installed Gradle version after install.ps1.'
  assert_metadata_for_version "$project_dir" "$installed_version"
}

# Exercise the shared launcher-patch contract across install and init-script
# sources so one path cannot silently drift from the others.
exercise_launcher_patch_contract_consistency() {
  log 'checking launcher patch contract consistency across install and init-script sources'

  python3 - <<'PY' "$TOOL_DIR/install.sh" "$TOOL_DIR/install.ps1" "$TOOL_DIR/buildish-no-gradle-wrapper-jar.init.gradle.kts" || fail 'launcher patch contract drifted across installer/init-script sources.'
from pathlib import Path
import re
import sys

paths = [Path(argument) for argument in sys.argv[1:]]
texts = {path.name: path.read_text().replace('\r\n', '\n') for path in paths}
shared_patterns = [
    r'for %%i in \(.+%APP_HOME%.+\) do set APP_HOME=%%~fi',
    r'powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File .*buildish-no-gradle-wrapper-jar\.ps1',
    r'org\.gradle\.wrapper\.GradleWrapperMain %\*',
    r'-classpath .*gradle-wrapper\.jar.* %\*',
    r'-jar .*gradle-wrapper\.jar.* %\*',
]

for name, text in texts.items():
    for pattern in shared_patterns:
        if re.search(pattern, text) is None:
            raise SystemExit(f"{name} is missing launcher contract pattern: {pattern!r}")
PY
}

# Reserved placeholder for installer-side download size checks so future work
# can slot into the suite without reshaping the surrounding runners.
exercise_installer_oversized_tool_download_failure() {
  :
}

# Reserved placeholder for installer-side timeout coverage once the installer is
# taught to fetch tool files through a timeout-controlled path.
exercise_powershell_installer_download_timeout_failure() {
  :
}

# Run the installer-centric portion of the default integration suite, including
# the shared output-normalization contract, both installers, and unsafe-dev
# guardrail checks.
run_installer_suite() {
  test_root=$1
  posix_project_dir=$2
  powershell_project_dir=$3

  log "starting installer suite (test_root='$test_root')"
  exercise_output_normalization_contract
  exercise_launcher_patch_contract_consistency
  exercise_wrapper_update_to_version "$posix_project_dir" '' "$UPDATED_GRADLE_VERSION"
  run_powershell_installer_flow "$powershell_project_dir"
  exercise_installer_missing_properties_failure "$test_root/posix-installer-missing-properties" posix
  exercise_installer_missing_properties_failure "$test_root/powershell-installer-missing-properties" powershell
  exercise_installer_requires_trusted_source_dir_failure "$test_root/posix-installer-requires-trusted-source-dir" posix
  exercise_installer_requires_trusted_source_dir_failure "$test_root/powershell-installer-requires-trusted-source-dir" powershell
  exercise_unsafe_dev_installer_requires_acknowledgement_failure "$test_root/posix-unsafe-dev-requires-ack" posix
  exercise_unsafe_dev_installer_requires_acknowledgement_failure "$test_root/powershell-unsafe-dev-requires-ack" powershell
  exercise_unsafe_dev_installer_ci_barrier_failure "$test_root/posix-unsafe-dev-ci-barrier" posix
  exercise_unsafe_dev_installer_ci_barrier_failure "$test_root/powershell-unsafe-dev-ci-barrier" powershell
  exercise_unsafe_dev_installer_success "$test_root/posix-unsafe-dev-success" posix
  exercise_unsafe_dev_installer_success "$test_root/powershell-unsafe-dev-success" powershell
}