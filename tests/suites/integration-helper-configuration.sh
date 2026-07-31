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

# Helper configuration, timeout, and external-dependency scenarios.

# Exercise the PowerShell helper timeout path against a stalling localhost
# server so its timeout diagnostics and cleanup behavior are regression-covered.
exercise_powershell_helper_download_timeout_failure() {
  project_dir=$1
  version=$2
  sha_path="$project_dir/gradle/wrapper/gradle-wrapper-$version.sha256"

  log "exercising PowerShell helper download-timeout failure in '$project_dir' for Gradle '$version'"
  rm -f "$sha_path"

  start_stalling_http_server
  configure_helper_download_urls "$project_dir" powershell "http://127.0.0.1:$TEST_HTTP_SERVER_PORT"

  run_powershell_helper_direct_with_timeout "$project_dir" "$POWERSHELL_HTTP_TIMEOUT_SECONDS_FOR_TESTS"
  stop_test_http_server

  assert_last_command_failed 'PowerShell helper unexpectedly succeeded even though the download endpoint stalled.'
  assert_last_output_mentions_timeout "$POWERSHELL_HTTP_TIMEOUT_SECONDS_FOR_TESTS" 'PowerShell helper timeout failure output did not mention the configured timeout.'
  [ ! -e "$sha_path" ] || fail "PowerShell helper should not publish a timed-out checksum download into '$sha_path'."
}

# Exercise the equivalent POSIX curl connect/overall deadline against the same
# stalling server used for PowerShell.
exercise_posix_helper_download_timeout_failure() {
  project_dir=$1
  version=$2
  sha_path="$project_dir/gradle/wrapper/gradle-wrapper-$version.sha256"

  log "exercising POSIX helper download-timeout failure in '$project_dir' for Gradle '$version'"
  rm -f "$sha_path"

  start_stalling_http_server
  configure_helper_download_urls "$project_dir" posix "http://127.0.0.1:$TEST_HTTP_SERVER_PORT"

  run_posix_helper_direct_with_timeout "$project_dir" "$POWERSHELL_HTTP_TIMEOUT_SECONDS_FOR_TESTS"
  stop_test_http_server

  assert_last_command_failed 'POSIX helper unexpectedly succeeded even though the download endpoint stalled.'
  assert_last_output_mentions_timeout "$POWERSHELL_HTTP_TIMEOUT_SECONDS_FOR_TESTS" 'POSIX helper timeout failure output did not mention the configured timeout.'
  [ ! -e "$sha_path" ] || fail "POSIX helper should not publish a timed-out checksum download into '$sha_path'."
}

# Invalid timeout configuration must fail before any project mutation. Exercise
# both a zero value and non-numeric input because the two parsers use different
# platform-native integer validation mechanisms.
exercise_helper_invalid_timeout_configuration_failure() {
  project_dir=$1
  helper_kind=$2
  invalid_value=$3
  snapshot_dir=$project_dir.before-invalid-timeout

  log "exercising $helper_kind helper invalid timeout '$invalid_value' in '$project_dir'"
  copy_project_fixture "$project_dir" "$snapshot_dir"

  case $helper_kind in
    posix)
      run_posix_helper_direct_with_timeout "$project_dir" "$invalid_value"
      assert_last_command_failed "POSIX helper unexpectedly accepted invalid timeout '$invalid_value'."
      assert_last_output_contains 'buildish-no-gradle-wrapper-jar: BUILDISH_NO_GRADLE_WRAPPER_JAR_HTTP_TIMEOUT_SECONDS must be a positive integer.' 'POSIX helper invalid-timeout failure did not use the stable helper diagnostic.'
      ;;
    powershell)
      run_powershell_helper_direct_capture_streams "$project_dir" '' "$invalid_value"
      [ "$CAPTURED_STATUS" -ne 0 ] || fail "PowerShell helper unexpectedly accepted invalid timeout '$invalid_value'."
      [ "$CAPTURED_STDOUT_BYTE_COUNT" -eq 0 ] ||
        fail "PowerShell helper invalid-timeout failure wrote to the stdout protocol (bytes=$CAPTURED_STDOUT_BYTE_COUNT, stdout=$CAPTURED_STDOUT)."
      assert_last_stderr_contains 'buildish-no-gradle-wrapper-jar: Buildish helper HTTP timeout must be a positive integer' 'PowerShell helper invalid-timeout failure did not use the stable stderr diagnostic.'
      if printf '%s' "$CAPTURED_STDERR_NORMALIZED" | grep -Fq 'Line |'; then
        fail 'PowerShell helper invalid-timeout failure leaked a raw PowerShell error record.'
      fi
      ;;
    *)
      fail "unknown helper kind '$helper_kind'"
      ;;
  esac
  diff -r "$snapshot_dir" "$project_dir" >/dev/null || fail "$helper_kind helper changed the project after rejecting invalid timeout '$invalid_value'."
}

# Verification must fail closed when GPG is absent. Use a controlled PATH and
# absolute interpreter paths so the test proves the helper's own dependency
# check rather than the test harness's command lookup.
exercise_helper_missing_gpg_failure() {
  project_dir=$1
  helper_kind=$2
  restricted_path=$project_dir.missing-gpg-path
  snapshot_dir=$project_dir.before-missing-gpg

  log "exercising $helper_kind helper missing-GPG failure in '$project_dir'"
  [ ! -e "$restricted_path" ] || fail "missing-GPG test PATH already exists at '$restricted_path'."
  mkdir "$restricted_path"
  copy_project_fixture "$project_dir" "$snapshot_dir"

  case $helper_kind in
    posix)
      curl_command=$(command -v curl)
      shell_command=$(command -v sh)
      [ -n "$curl_command" ] && [ -n "$shell_command" ] || fail 'missing-GPG test requires curl and sh paths.'
      ln -s "$curl_command" "$restricted_path/curl"
      helper_path=$project_dir/gradle/buildish-no-gradle-wrapper-jar.sh
      run_and_capture env PATH="$restricted_path" APP_HOME="$project_dir" "$shell_command" -c 'helper_path=$1; set --; . "$helper_path"' sh "$helper_path"
      assert_last_command_failed 'POSIX helper unexpectedly succeeded without GPG.'
      assert_last_output_contains "Required command 'gpg' was not found on PATH." 'POSIX helper missing-GPG failure did not identify the unavailable command.'
      ;;
    powershell)
      powershell_command=$(pwsh -NoLogo -NoProfile -Command '(Get-Process -Id $PID).Path')
      [ -n "$powershell_command" ] || fail 'missing-GPG test could not resolve the PowerShell executable path.'
      helper_path=$project_dir/gradle/buildish-no-gradle-wrapper-jar.ps1
      run_and_capture env PATH="$restricted_path" APP_HOME="$project_dir" "$powershell_command" -NoLogo -NoProfile -File "$helper_path"
      assert_last_command_failed 'PowerShell helper unexpectedly succeeded without GPG.'
      assert_last_output_contains "A GnuPG command ('gpg') is required" 'Non-Windows PowerShell helper missing-GPG failure did not identify the unavailable command.'
      ;;
    *)
      fail "unknown helper kind '$helper_kind'"
      ;;
  esac

  diff -r "$snapshot_dir" "$project_dir" >/dev/null || fail "$helper_kind helper changed the project while failing closed without GPG."
}

# Non-Windows PowerShell must resolve the conventional `gpg` name directly,
# even when an executable named `gpg.exe` is available beside it on PATH.
exercise_powershell_helper_non_windows_gpg_resolution() {
  project_dir=$1
  restricted_path=$project_dir.non-windows-gpg-path
  powershell_command=$(pwsh -NoLogo -NoProfile -Command '(Get-Process -Id $PID).Path')
  gpg_command=$(command -v gpg)

  log "exercising non-Windows PowerShell GPG resolution in '$project_dir'"
  [ -n "$powershell_command" ] || fail 'GPG-resolution test could not resolve the PowerShell executable path.'
  [ -n "$gpg_command" ] || fail 'GPG-resolution test requires gpg on PATH.'
  [ ! -e "$restricted_path" ] || fail "GPG-resolution test PATH already exists at '$restricted_path'."
  mkdir "$restricted_path"
  ln -s "$gpg_command" "$restricted_path/gpg"
  printf '#!/bin/sh\nexit 97\n' > "$restricted_path/gpg.exe"
  chmod +x "$restricted_path/gpg.exe"

  helper_path=$project_dir/gradle/buildish-no-gradle-wrapper-jar.ps1
  run_and_capture env PATH="$restricted_path" APP_HOME="$project_dir" "$powershell_command" -NoLogo -NoProfile -File "$helper_path"
  assert_last_command_succeeded 'Non-Windows PowerShell helper selected gpg.exe instead of gpg.'
}

# POSIX external-tool prerequisites must be checked before any cached artifact
# is inspected or removed. A controlled PATH proves both the first downloader
# guard and the checksum-tool alternative guard without relying on host layout.
exercise_posix_helper_missing_tool_failure() {
  project_dir=$1
  missing_tool_kind=$2
  restricted_path=$project_dir.missing-$missing_tool_kind-path
  snapshot_dir=$project_dir.before-missing-$missing_tool_kind
  shell_command=$(command -v sh)

  log "exercising POSIX helper missing-$missing_tool_kind failure in '$project_dir'"
  [ -n "$shell_command" ] || fail "missing-$missing_tool_kind test requires an absolute sh path."
  [ ! -e "$restricted_path" ] || fail "missing-$missing_tool_kind test PATH already exists at '$restricted_path'."
  mkdir "$restricted_path"
  copy_project_fixture "$project_dir" "$snapshot_dir"

  case $missing_tool_kind in
    curl)
      expected_diagnostic="Required command 'curl' was not found on PATH."
      ;;
    checksum)
      for retained_command in curl gpg mktemp; do
        retained_command_path=$(command -v "$retained_command")
        [ -n "$retained_command_path" ] || fail "missing-checksum test requires '$retained_command'."
        ln -s "$retained_command_path" "$restricted_path/$retained_command"
      done
      expected_diagnostic="Neither 'sha256sum' nor 'shasum' is available for checksum verification."
      ;;
    *)
      fail "unknown missing POSIX helper tool kind '$missing_tool_kind'"
      ;;
  esac

  helper_path=$project_dir/gradle/buildish-no-gradle-wrapper-jar.sh
  run_and_capture env PATH="$restricted_path" APP_HOME="$project_dir" "$shell_command" -c 'helper_path=$1; set --; . "$helper_path"' sh "$helper_path"
  assert_last_command_failed "POSIX helper unexpectedly succeeded without $missing_tool_kind tooling."
  assert_last_output_contains "$expected_diagnostic" "POSIX helper missing-$missing_tool_kind failure did not identify the unavailable prerequisite."
  diff -r "$snapshot_dir" "$project_dir" >/dev/null || fail "POSIX helper changed the project while failing closed without $missing_tool_kind tooling."
}

# Exercise helper rejection of non-canonical distribution URLs so the wrapper
# source stays pinned to the supported services.gradle.org location.
exercise_helper_invalid_distribution_failure() {
  project_dir=$1
  helper_kind=$2
  properties_path="$project_dir/gradle/wrapper/gradle-wrapper.properties"

  log "exercising $helper_kind helper invalid-distribution failure in '$project_dir'"
  set_wrapper_property "$properties_path" distributionUrl 'https\://example.invalid/distributions/gradle-9.4.1-bin.zip'

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_failed "$helper_kind helper unexpectedly accepted a non-canonical distributionUrl."

  assert_last_output_contains 'distributionUrl must be a canonical' "$helper_kind helper failure output did not mention the canonical distributionUrl requirement."
  assert_last_output_contains 'services.gradle.org URL' "$helper_kind helper failure output did not mention the required services.gradle.org host."
}

# Exercise helper failure when gradle-wrapper.properties is missing so the
# helper refuses to guess the target distribution metadata.
exercise_helper_missing_properties_failure() {
  project_dir=$1
  helper_kind=$2

  log "exercising $helper_kind helper missing-properties failure in '$project_dir'"
  rm -f "$project_dir/gradle/wrapper/gradle-wrapper.properties"

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_failed "$helper_kind helper unexpectedly succeeded without gradle-wrapper.properties."
  assert_last_output_contains 'Gradle wrapper properties file was not found' "$helper_kind helper failure output did not mention that gradle-wrapper.properties was missing."
  assert_last_output_contains 'gradle-wrapper.properties' "$helper_kind helper failure output did not mention the missing gradle-wrapper.properties path."
}

# Exercise helper failure when distributionUrl is absent so recovery cannot fall
# back to an implicit or attacker-controlled distribution source.
exercise_helper_missing_distribution_url_failure() {
  project_dir=$1
  helper_kind=$2
  properties_path="$project_dir/gradle/wrapper/gradle-wrapper.properties"

  log "exercising $helper_kind helper missing-distributionUrl failure in '$project_dir'"
  remove_wrapper_property "$properties_path" distributionUrl

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_failed "$helper_kind helper unexpectedly succeeded without distributionUrl."
  assert_last_output_contains 'distributionUrl entry' "$helper_kind helper failure output did not mention the missing distributionUrl entry."
}

# The project-owned digest is a security-critical configuration input. Reject
# missing, duplicate, and non-canonical values before cached or downloaded
# artifacts can influence wrapper-JAR acceptance.
exercise_helper_wrapper_pin_validation_failure() {
  project_dir=$1
  helper_kind=$2
  failure_kind=$3
  properties_path="$project_dir/gradle/wrapper/gradle-wrapper.properties"

  case $failure_kind in
    missing)
      log "exercising $helper_kind helper missing wrapper-JAR pin failure in '$project_dir'"
      remove_wrapper_property "$properties_path" buildishWrapperJarSha256Sum
      expected_message='missing the required buildishWrapperJarSha256Sum entry'
      ;;
    duplicate)
      log "exercising $helper_kind helper duplicate wrapper-JAR pin failure in '$project_dir'"
      existing_pin=$(sed -n 's/^buildishWrapperJarSha256Sum=//p' "$properties_path")
      printf '%s\n' "buildishWrapperJarSha256Sum=$existing_pin" >> "$properties_path"
      expected_message='duplicate buildishWrapperJarSha256Sum entries'
      ;;
    malformed)
      log "exercising $helper_kind helper malformed wrapper-JAR pin failure in '$project_dir'"
      set_wrapper_property "$properties_path" buildishWrapperJarSha256Sum 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      expected_message='must be exactly one lowercase 64-character SHA-256 value'
      ;;
    *)
      fail "unknown wrapper pin failure kind '$failure_kind'"
      ;;
  esac

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_failed "$helper_kind helper unexpectedly accepted a $failure_kind wrapper-JAR pin."
  assert_last_output_contains "$expected_message" "$helper_kind helper did not explain the $failure_kind wrapper-JAR pin failure."
}

# Exercise helper support for two-segment Gradle versions so metadata caching is
# not coupled to three-segment release numbers.
exercise_helper_two_segment_version_support() {
  project_dir=$1
  helper_kind=$2
  target_version=$3
  properties_path="$project_dir/gradle/wrapper/gradle-wrapper.properties"
  jar_path="$project_dir/gradle/wrapper/gradle-wrapper.jar"

  log "exercising $helper_kind helper two-segment Gradle version support in '$project_dir' for Gradle '$target_version'"
  GRADLE_USER_HOME=$(gradle_user_home "$project_dir") \
    gradle -p "$project_dir" --no-daemon --console=plain wrapper --gradle-version "$target_version" --distribution-type bin >/dev/null
  target_wrapper_pin=$(fetch_gradle_wrapper_checksum "$target_version")
  set_wrapper_property "$properties_path" buildishWrapperJarSha256Sum "$target_wrapper_pin"
  rm -f "$jar_path" "$project_dir/gradle/wrapper/gradle-wrapper-$target_version.sha256" "$project_dir/gradle/wrapper/gradle-wrapper-$target_version.asc"

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_succeeded "$helper_kind helper did not support the two-segment Gradle version '$target_version'."
  assert_metadata_for_version "$project_dir" "$target_version"

  if [ "$helper_kind" = powershell ]; then
    init_script_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.init.gradle.kts"
    expected_output="--init-script \"$init_script_path\""
    assert_last_output_equals "$expected_output" 'PowerShell helper emitted diagnostics or HTTP response objects while downloading and verifying a two-segment Gradle wrapper.'
  fi
}

# Run common configuration/dependency cases for one helper, with platform-only
# prerequisites kept in literal branches so asymmetry is visible during review.
run_helper_configuration_for_kind() {
  local scenario_root=$1
  local base_project=$2
  local version=$3
  local helper_kind=$4
  local invalid_timeout
  local failure_kind
  local missing_tool_kind

  copy_project_fixture "$base_project" "$scenario_root/$helper_kind-invalid-distribution-url"
  exercise_helper_invalid_distribution_failure "$scenario_root/$helper_kind-invalid-distribution-url" "$helper_kind"

  copy_project_fixture "$base_project" "$scenario_root/$helper_kind-download-timeout"
  case $helper_kind in
    posix)
      exercise_posix_helper_download_timeout_failure "$scenario_root/$helper_kind-download-timeout" "$version"
      ;;
    powershell)
      exercise_powershell_helper_download_timeout_failure "$scenario_root/$helper_kind-download-timeout" "$version"
      ;;
  esac

  for invalid_timeout in 0 not-a-number; do
    copy_project_fixture "$base_project" "$scenario_root/$helper_kind-invalid-timeout-$invalid_timeout"
    exercise_helper_invalid_timeout_configuration_failure "$scenario_root/$helper_kind-invalid-timeout-$invalid_timeout" "$helper_kind" "$invalid_timeout"
  done

  copy_project_fixture "$base_project" "$scenario_root/$helper_kind-missing-gpg"
  exercise_helper_missing_gpg_failure "$scenario_root/$helper_kind-missing-gpg" "$helper_kind"

  case $helper_kind in
    posix)
      for missing_tool_kind in curl checksum; do
        copy_project_fixture "$base_project" "$scenario_root/posix-missing-$missing_tool_kind"
        exercise_posix_helper_missing_tool_failure "$scenario_root/posix-missing-$missing_tool_kind" "$missing_tool_kind"
      done
      copy_project_fixture "$base_project" "$scenario_root/posix-missing-properties"
      exercise_helper_missing_properties_failure "$scenario_root/posix-missing-properties" posix
      ;;
    powershell)
      copy_project_fixture "$base_project" "$scenario_root/powershell-non-windows-gpg-resolution"
      exercise_powershell_helper_non_windows_gpg_resolution "$scenario_root/powershell-non-windows-gpg-resolution"
      ;;
  esac

  copy_project_fixture "$base_project" "$scenario_root/$helper_kind-missing-distribution-url"
  exercise_helper_missing_distribution_url_failure "$scenario_root/$helper_kind-missing-distribution-url" "$helper_kind"

  for failure_kind in missing duplicate malformed; do
    copy_project_fixture "$base_project" "$scenario_root/$helper_kind-wrapper-pin-$failure_kind"
    exercise_helper_wrapper_pin_validation_failure "$scenario_root/$helper_kind-wrapper-pin-$failure_kind" "$helper_kind" "$failure_kind"
  done

  copy_project_fixture "$base_project" "$scenario_root/$helper_kind-two-segment-version"
  exercise_helper_two_segment_version_support "$scenario_root/$helper_kind-two-segment-version" "$helper_kind" "$TWO_SEGMENT_GRADLE_VERSION"
}

run_helper_configuration_suite() {
  local scenario_root=$1
  local posix_base_project=$2
  local powershell_base_project=$3
  local posix_version=$4
  local powershell_version=$5

  run_helper_configuration_for_kind "$scenario_root" "$posix_base_project" "$posix_version" posix
  run_helper_configuration_for_kind "$scenario_root" "$powershell_base_project" "$powershell_version" powershell
}
