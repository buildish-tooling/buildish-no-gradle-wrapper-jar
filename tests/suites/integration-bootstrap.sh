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

# Bootstrap-installer scenarios for tests/integration.sh.

# Exercise the checked-in bootstrap template guard so unreplaced release
# placeholders fail closed instead of attempting a partial install.
exercise_bootstrap_template_guard_failure() {
  project_dir=$1
  bootstrap_kind=$2

  log "exercising $bootstrap_kind bootstrap installer unrendered-template guard in '$project_dir'"
  gradle_init_fixture "$project_dir"

  case "$bootstrap_kind" in
    posix)
      run_posix_bootstrap_installer_capture "$TOOL_DIR/bootstrap-install.sh" "$project_dir"
      ;;
    powershell)
      run_powershell_bootstrap_installer_capture "$TOOL_DIR/bootstrap-install.ps1" "$project_dir"
      ;;
    *)
      fail "unknown bootstrap kind '$bootstrap_kind'"
      ;;
  esac

  assert_last_command_failed "$bootstrap_kind bootstrap installer unexpectedly ran even though the repository copy is an unrendered template."
  assert_last_output_contains 'release placeholders' "$bootstrap_kind bootstrap installer failure output did not mention the release-placeholder guard."
  assert_helper_files_absent "$project_dir"
}

# Exercise bootstrap detached-signature verification by tampering with the
# signed manifest after signing and expecting the install to fail closed.
exercise_bootstrap_signature_failure() {
  project_dir=$1
  bootstrap_kind=$2
  server_root="$project_dir-bootstrap-release"

  log "exercising $bootstrap_kind bootstrap installer detached-signature failure in '$project_dir'"
  gradle_init_fixture "$project_dir"
  prepare_bootstrap_release_fixture "$server_root" "$bootstrap_kind" complete tampered

  case "$bootstrap_kind" in
    posix)
      run_posix_bootstrap_installer_capture "$server_root/bootstrap-install.sh" "$project_dir"
      ;;
    powershell)
      run_powershell_bootstrap_installer_capture "$server_root/bootstrap-install.ps1" "$project_dir"
      ;;
    *)
      stop_test_http_server
      fail "unknown bootstrap kind '$bootstrap_kind'"
      ;;
  esac

  stop_test_http_server
  assert_last_command_failed "$bootstrap_kind bootstrap installer unexpectedly accepted a tampered manifest signature."
  assert_last_output_contains 'Detached signature verification failed' "$bootstrap_kind bootstrap installer failure output did not mention detached-signature verification failure."
  assert_helper_files_absent "$project_dir"
}

# Exercise bootstrap enforcement that every signed payload file must appear in
# the manifest exactly once before anything is installed.
exercise_bootstrap_missing_manifest_entry_failure() {
  project_dir=$1
  bootstrap_kind=$2
  server_root="$project_dir-bootstrap-release"

  log "exercising $bootstrap_kind bootstrap installer missing-manifest-entry failure in '$project_dir'"
  gradle_init_fixture "$project_dir"
  prepare_bootstrap_release_fixture "$server_root" "$bootstrap_kind" missing-helper valid

  case "$bootstrap_kind" in
    posix)
      run_posix_bootstrap_installer_capture "$server_root/bootstrap-install.sh" "$project_dir"
      ;;
    powershell)
      run_powershell_bootstrap_installer_capture "$server_root/bootstrap-install.ps1" "$project_dir"
      ;;
    *)
      stop_test_http_server
      fail "unknown bootstrap kind '$bootstrap_kind'"
      ;;
  esac

  stop_test_http_server
  assert_last_command_failed "$bootstrap_kind bootstrap installer unexpectedly accepted an incomplete signed payload manifest."
  assert_last_output_contains 'did not contain exactly one checksum entry' "$bootstrap_kind bootstrap installer failure output did not mention the missing manifest entry."
  assert_last_output_contains 'buildish-no-gradle-wrapper-jar.ps1' "$bootstrap_kind bootstrap installer failure output did not identify the missing payload file entry."
  assert_helper_files_absent "$project_dir"
}

# Exercise the release-style bootstrap happy path from signed localhost payloads
# through helper installation and launcher patch verification.
exercise_bootstrap_success() {
  project_dir=$1
  bootstrap_kind=$2
  server_root="$project_dir-bootstrap-release"

  log "exercising $bootstrap_kind bootstrap installer happy path in '$project_dir'"
  gradle_init_fixture "$project_dir"
  prepare_bootstrap_release_fixture "$server_root" "$bootstrap_kind" complete valid

  case "$bootstrap_kind" in
    posix)
      run_posix_bootstrap_installer_capture "$server_root/bootstrap-install.sh" "$project_dir"
      ;;
    powershell)
      run_powershell_bootstrap_installer_capture "$server_root/bootstrap-install.ps1" "$project_dir"
      ;;
    *)
      stop_test_http_server
      fail "unknown bootstrap kind '$bootstrap_kind'"
      ;;
  esac

  stop_test_http_server
  assert_last_command_succeeded "$bootstrap_kind bootstrap installer failed during the happy-path smoke test."
  assert_installer_distribution_sha_warning_output "$bootstrap_kind bootstrap installer"
  [ ! -e "$project_dir/gradle/wrapper/gradle-wrapper.jar" ] || fail "$bootstrap_kind bootstrap installer should remove the existing gradle-wrapper.jar via install.*."
  assert_helper_files "$project_dir"
  assert_launcher_patches "$project_dir"
}

# Run the bootstrap installer matrix covering template guards, manifest/signature
# failures, and the happy path for both POSIX and PowerShell entrypoints.
run_bootstrap_suite() {
  test_root=$1

  log "starting bootstrap installer suite (test_root='$test_root')"
  create_bootstrap_signing_fixture "$test_root/bootstrap-signing"

  exercise_bootstrap_template_guard_failure "$test_root/bootstrap-template-guard-posix" posix
  exercise_bootstrap_template_guard_failure "$test_root/bootstrap-template-guard-powershell" powershell
  exercise_bootstrap_signature_failure "$test_root/bootstrap-signature-failure-posix" posix
  exercise_bootstrap_signature_failure "$test_root/bootstrap-signature-failure-powershell" powershell
  exercise_bootstrap_missing_manifest_entry_failure "$test_root/bootstrap-missing-entry-posix" posix
  exercise_bootstrap_missing_manifest_entry_failure "$test_root/bootstrap-missing-entry-powershell" powershell
  exercise_bootstrap_success "$test_root/bootstrap-success-posix" posix
  exercise_bootstrap_success "$test_root/bootstrap-success-powershell" powershell
}