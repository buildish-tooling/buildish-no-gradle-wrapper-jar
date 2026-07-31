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

# Helper launcher-argument and PowerShell stream-protocol scenarios.

# Exercise POSIX helper argument deduplication across the split and compact
# --init-script / -I spellings used by real Gradle invocations.
exercise_posix_helper_init_script_deduplication() {
  project_dir=$1
  init_script_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.init.gradle.kts"

  log "exercising POSIX helper init-script deduplication in '$project_dir'"

  run_posix_helper_direct_capture_args "$project_dir" --init-script "$init_script_path" --stacktrace
  assert_last_command_succeeded 'POSIX helper failed while checking --init-script <path> deduplication.'
  assert_last_output_exact_line_count '--init-script' 1 'POSIX helper duplicated the split --init-script flag.'
  assert_last_output_exact_line_count "$init_script_path" 1 'POSIX helper duplicated the split init-script path.'

  run_posix_helper_direct_capture_args "$project_dir" -I "$init_script_path" --stacktrace
  assert_last_command_succeeded 'POSIX helper failed while checking -I <path> deduplication.'
  assert_last_output_exact_line_count '-I' 1 'POSIX helper duplicated the split -I flag.'
  assert_last_output_exact_line_count "$init_script_path" 1 'POSIX helper duplicated the split -I init-script path.'

  run_posix_helper_direct_capture_args "$project_dir" "--init-script=$init_script_path" --stacktrace
  assert_last_command_succeeded 'POSIX helper failed while checking --init-script=<path> deduplication.'
  assert_last_output_exact_line_count "--init-script=$init_script_path" 1 'POSIX helper duplicated the compact --init-script=<path> argument.'

  run_posix_helper_direct_capture_args "$project_dir" "-I$init_script_path" --stacktrace
  assert_last_command_succeeded 'POSIX helper failed while checking -I<path> deduplication.'
  assert_last_output_exact_line_count "-I$init_script_path" 1 'POSIX helper duplicated the compact -I<path> argument.'
}

# Exercise PowerShell helper init-script injection and deduplication so every
# path stays quoted while crossing cmd.exe, including paths with metacharacters.
exercise_powershell_helper_init_script_output() {
  project_dir=$1
  init_script_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.init.gradle.kts"
  expected_output="--init-script \"$init_script_path\""

  log "exercising PowerShell helper init-script output in '$project_dir'"

  run_powershell_helper_direct "$project_dir"
  assert_last_command_succeeded 'PowerShell helper failed while checking init-script injection output.'
  assert_last_output_equals "$expected_output" 'PowerShell helper did not quote the injected init-script path as expected.'

  run_powershell_helper_direct "$project_dir" "--stacktrace --init-script \"$init_script_path\""
  assert_last_command_succeeded 'PowerShell helper failed while checking init-script deduplication.'
  assert_last_output_equals '' 'PowerShell helper should not emit a duplicate init-script argument when the caller already supplied it.'
}

# A recovery warning must remain on stderr even when the optional init script is
# absent and the helper's only stdout protocol value is an empty line. Otherwise
# gradlew.bat's `for /f` loop mistakes the warning for Java arguments.
exercise_powershell_helper_recovery_stream_protocol() {
  project_dir=$1
  version=$2
  jar_path="$project_dir/gradle/wrapper/gradle-wrapper.jar"
  init_script_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.init.gradle.kts"

  log "exercising PowerShell helper recovery stream protocol in '$project_dir'"
  write_file_with_size "$jar_path" $((HELPER_MAX_JAR_BYTES + 1)) ''
  rm -f "$init_script_path"

  run_powershell_helper_direct_capture_streams "$project_dir"
  [ "$CAPTURED_STATUS" -eq 0 ] || fail "PowerShell helper did not recover with a missing optional init script (exit status=$CAPTURED_STATUS, stderr=$CAPTURED_STDERR)."
  [ "$CAPTURED_STDOUT" = '' ] || fail "PowerShell helper recovery polluted its empty stdout protocol value (stdout=$CAPTURED_STDOUT)."
  [ "$CAPTURED_STDOUT_BYTE_COUNT" -eq 1 ] && [ "$CAPTURED_STDOUT_LINE_COUNT" -eq 1 ] ||
    fail "PowerShell helper recovery should emit exactly one empty stdout protocol line (bytes=$CAPTURED_STDOUT_BYTE_COUNT, lines=$CAPTURED_STDOUT_LINE_COUNT)."
  assert_last_stderr_contains 'warning: Existing Gradle wrapper JAR verification failed; the helper will re-download it.' 'PowerShell helper recovery warning was not emitted on stderr.'
  assert_metadata_for_version "$project_dir" "$version"
}

# Fatal diagnostics also belong exclusively to stderr; stdout must not expose a
# string that gradlew.bat could reinterpret as launcher arguments.
exercise_powershell_helper_failure_stream_protocol() {
  project_dir=$1

  log "exercising PowerShell helper failure stream protocol in '$project_dir'"
  rm -f "$project_dir/gradle/wrapper/gradle-wrapper.properties"

  run_powershell_helper_direct_capture_streams "$project_dir"
  [ "$CAPTURED_STATUS" -ne 0 ] || fail 'PowerShell helper unexpectedly succeeded without gradle-wrapper.properties.'
  [ "$CAPTURED_STDOUT_BYTE_COUNT" -eq 0 ] ||
    fail "PowerShell helper fatal failure wrote to the stdout protocol (bytes=$CAPTURED_STDOUT_BYTE_COUNT, stdout=$CAPTURED_STDOUT)."
  assert_last_stderr_contains 'Gradle wrapper properties file was not found' 'PowerShell helper fatal diagnostic was not emitted on stderr.'
}

# Run platform-specific launcher and stream-protocol contracts.
run_helper_protocol_suite() {
  local scenario_root=$1
  local posix_base_project=$2
  local powershell_base_project=$3
  local powershell_version=$4

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-init-script-dedup"
  exercise_posix_helper_init_script_deduplication "$scenario_root/posix-init-script-dedup"

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-recovery-stream-protocol"
  exercise_powershell_helper_recovery_stream_protocol "$scenario_root/powershell-recovery-stream-protocol" "$powershell_version"

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-missing-properties"
  exercise_powershell_helper_failure_stream_protocol "$scenario_root/powershell-missing-properties"

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell helper with spaces"
  exercise_powershell_helper_init_script_output "$scenario_root/powershell helper with spaces"

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell&helper^(meta)%pct!bang"
  exercise_powershell_helper_init_script_output "$scenario_root/powershell&helper^(meta)%pct!bang"
}
