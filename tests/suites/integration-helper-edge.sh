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

# Helper edge-case scenarios for tests/integration.sh.

# Exercise helper recovery when the cached wrapper JAR is corrupted and both
# metadata sidecars must be re-fetched from the configured source.
exercise_helper_recovery_scenario() {
  project_dir=$1
  version=$2
  helper_kind=$3
  jar_path="$project_dir/gradle/wrapper/gradle-wrapper.jar"
  sha_path="$project_dir/gradle/wrapper/gradle-wrapper-$version.sha256"
  asc_path="$project_dir/gradle/wrapper/gradle-wrapper-$version.asc"

  log "exercising $helper_kind helper recovery scenario in '$project_dir' for Gradle '$version'"
  printf 'corrupted-wrapper-jar\n' > "$jar_path"
  rm -f "$sha_path" "$asc_path"

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_succeeded "$helper_kind helper did not recover from a corrupted wrapper JAR plus missing metadata."
  assert_metadata_for_version "$project_dir" "$version"
}

# Exercise helper recovery when only the wrapper JAR is corrupted and cached
# checksum/signature metadata should be reused instead of re-downloaded.
exercise_helper_recovery_with_cached_metadata() {
  project_dir=$1
  version=$2
  helper_kind=$3
  jar_path="$project_dir/gradle/wrapper/gradle-wrapper.jar"

  log "exercising $helper_kind helper cached-metadata recovery scenario in '$project_dir' for Gradle '$version'"
  printf 'corrupted-wrapper-jar\n' > "$jar_path"

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_succeeded "$helper_kind helper did not recover from a corrupted wrapper JAR while cached metadata remained present."
  assert_metadata_for_version "$project_dir" "$version"
}

# Exercise helper recovery from malformed cached checksum or signature metadata
# so stale sidecars cannot pin the project in a broken state.
exercise_helper_malformed_metadata_recovery() {
  project_dir=$1
  version=$2
  helper_kind=$3
  metadata_kind=$4
  sha_path="$project_dir/gradle/wrapper/gradle-wrapper-$version.sha256"
  asc_path="$project_dir/gradle/wrapper/gradle-wrapper-$version.asc"

  case "$metadata_kind" in
    sha256)
      log "exercising $helper_kind helper malformed-checksum recovery scenario in '$project_dir' for Gradle '$version'"
      printf 'not-a-sha256\n' > "$sha_path"
      ;;
    asc)
      log "exercising $helper_kind helper malformed-signature recovery scenario in '$project_dir' for Gradle '$version'"
      printf 'not-a-signature\n' > "$asc_path"
      ;;
    *)
      fail "unknown metadata kind '$metadata_kind'"
      ;;
  esac

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_succeeded "$helper_kind helper did not recover from malformed cached $metadata_kind metadata."
  assert_metadata_for_version "$project_dir" "$version"
}

# Exercise helper rejection of oversized metadata and wrapper downloads so the
# documented size ceilings are enforced before files are published locally.
exercise_helper_oversized_download_failure() {
  project_dir=$1
  version=$2
  helper_kind=$3
  download_kind=$4
  wrapper_dir="$project_dir/gradle/wrapper"
  jar_path="$wrapper_dir/gradle-wrapper.jar"
  sha_path="$wrapper_dir/gradle-wrapper-$version.sha256"
  asc_path="$wrapper_dir/gradle-wrapper-$version.asc"
  server_root="$project_dir/oversized-download-server"

  rm -rf "$server_root"
  mkdir -p "$server_root"
  cp "$sha_path" "$server_root/wrapper.sha256"
  cp "$asc_path" "$server_root/wrapper.asc"
  cp "$jar_path" "$server_root/gradle-wrapper.jar"

  case "$download_kind" in
    sha256)
      log "exercising $helper_kind helper oversized-checksum download failure in '$project_dir' for Gradle '$version'"
      rm -f "$sha_path"
      write_file_with_size "$server_root/wrapper.sha256" $((HELPER_MAX_METADATA_BYTES + 1)) 'a'
      target_path="$sha_path"
      ;;
    asc)
      log "exercising $helper_kind helper oversized-signature download failure in '$project_dir' for Gradle '$version'"
      rm -f "$asc_path"
      write_file_with_size "$server_root/wrapper.asc" $((HELPER_MAX_METADATA_BYTES + 1)) '-----BEGIN PGP SIGNATURE-----
'
      target_path="$asc_path"
      ;;
    jar)
      log "exercising $helper_kind helper oversized-wrapper-jar download failure in '$project_dir' for Gradle '$version'"
      rm -f "$jar_path"
      write_file_with_size "$server_root/gradle-wrapper.jar" $((HELPER_MAX_JAR_BYTES + 1)) ''
      target_path="$jar_path"
      ;;
    *)
      fail "unknown oversized download kind '$download_kind'"
      ;;
  esac

  start_static_http_server "$server_root"
  configure_helper_download_urls "$project_dir" "$helper_kind" "http://127.0.0.1:$TEST_HTTP_SERVER_PORT"

  "run_${helper_kind}_helper_direct" "$project_dir"
  stop_test_http_server

  assert_last_command_failed "$helper_kind helper unexpectedly accepted an oversized $download_kind download."
  assert_last_output_contains 'maximum allowed size' "$helper_kind helper failure output did not mention the maximum allowed size for the oversized $download_kind download."
  [ ! -e "$target_path" ] || fail "$helper_kind helper should not publish an oversized $download_kind file into '$target_path'."
}

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

# Exercise helper rejection of symlinked integrity artifacts so the runtime path
# cannot be redirected outside the project tree through filesystem indirection.
exercise_helper_symlink_rejection() {
  project_dir=$1
  version=$2
  helper_kind=$3
  target_kind=$4
  symlink_target_root="$project_dir/external-symlink-targets"
  expected_label=''

  mkdir -p "$symlink_target_root"

  case "$target_kind" in
    sha256)
      target_path="$project_dir/gradle/wrapper/gradle-wrapper-$version.sha256"
      symlink_target_path="$symlink_target_root/gradle-wrapper-$version.sha256"
      expected_label='wrapper checksum'
      log "exercising $helper_kind helper symlinked-checksum rejection in '$project_dir' for Gradle '$version'"
      ;;
    init-script)
      target_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.init.gradle.kts"
      symlink_target_path="$symlink_target_root/buildish-no-gradle-wrapper-jar.init.gradle.kts"
      expected_label='Buildish init script'
      log "exercising $helper_kind helper symlinked-init-script rejection in '$project_dir'"
      ;;
    *)
      fail "unknown symlink rejection target '$target_kind'"
      ;;
  esac

  cp "$target_path" "$symlink_target_path"
  rm -f "$target_path"
  ln -s "$symlink_target_path" "$target_path"

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_failed "$helper_kind helper unexpectedly accepted a symlinked $target_kind path."
  assert_last_output_contains "$expected_label must not be a symbolic link:" "$helper_kind helper failure output did not mention the symlink rejection for $target_kind."
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

# Build one genuine older-version source with a digest distinct from the current
# fixture. Its signed checksum/signature/JAR triplet is reused by cache and
# download replay scenarios for both helpers.
prepare_cross_version_replay_source() {
  source_project_dir=$1
  replay_project_dir=$2
  replay_version=$3
  properties_path=$replay_project_dir/gradle/wrapper/gradle-wrapper.properties
  jar_path=$replay_project_dir/gradle/wrapper/gradle-wrapper.jar

  copy_project_fixture "$source_project_dir" "$replay_project_dir"
  GRADLE_USER_HOME=$(gradle_user_home "$replay_project_dir") \
    gradle -p "$replay_project_dir" --no-daemon --console=plain wrapper --gradle-version "$replay_version" --distribution-type bin >/dev/null
  replay_wrapper_pin=$(fetch_gradle_wrapper_checksum "$replay_version")
  set_wrapper_property "$properties_path" buildishWrapperJarSha256Sum "$replay_wrapper_pin"
  rm -f "$jar_path" "$replay_project_dir/gradle/wrapper/gradle-wrapper-$replay_version.sha256" "$replay_project_dir/gradle/wrapper/gradle-wrapper-$replay_version.asc"
  run_posix_helper_direct "$replay_project_dir"
  assert_last_command_succeeded "unable to prepare the genuine Gradle $replay_version replay fixture."
  assert_metadata_for_version "$replay_project_dir" "$replay_version"
}

# Replace all requested-version cache entries with a genuine older signed
# artifact triplet. The project pin must reject the coherent replay before the
# older JAR can be accepted under the newer distributionUrl version.
exercise_helper_cached_cross_version_replay_rejection() {
  project_dir=$1
  older_project_dir=$2
  helper_kind=$3
  requested_version=$(extract_gradle_version "$project_dir")
  older_version=$(extract_gradle_version "$older_project_dir")
  wrapper_dir=$project_dir/gradle/wrapper
  older_wrapper_dir=$older_project_dir/gradle/wrapper

  [ "$requested_version" != "$older_version" ] || fail 'cross-version replay fixture requires distinct requested and older Gradle versions.'
  log "exercising $helper_kind helper cached $older_version-as-$requested_version replay rejection in '$project_dir'"
  cp "$older_wrapper_dir/gradle-wrapper.jar" "$wrapper_dir/gradle-wrapper.jar"
  cp "$older_wrapper_dir/gradle-wrapper-$older_version.sha256" "$wrapper_dir/gradle-wrapper-$requested_version.sha256"
  cp "$older_wrapper_dir/gradle-wrapper-$older_version.asc" "$wrapper_dir/gradle-wrapper-$requested_version.asc"
  replayed_jar_checksum=$(hash_file "$wrapper_dir/gradle-wrapper.jar")

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_failed "$helper_kind helper unexpectedly accepted a genuine older signed wrapper artifact triplet from cache."
  assert_last_output_contains 'buildishWrapperJarSha256Sum does not match the Gradle-published wrapper JAR checksum' "$helper_kind helper did not identify the cached cross-version replay as a project-pin mismatch."
  [ "$(hash_file "$wrapper_dir/gradle-wrapper.jar")" = "$replayed_jar_checksum" ] || fail "$helper_kind helper mutated the cached JAR before rejecting the replayed metadata binding."
}

# Serve the same genuine older triplet under the requested-version download URLs
# to prove the project pin also rejects a coherent substitution by the download
# path rather than trusting HTTPS metadata as the binding authority.
exercise_helper_downloaded_cross_version_replay_rejection() {
  project_dir=$1
  older_project_dir=$2
  helper_kind=$3
  server_root=$project_dir.replay-server
  requested_version=$(extract_gradle_version "$project_dir")
  older_version=$(extract_gradle_version "$older_project_dir")
  wrapper_dir=$project_dir/gradle/wrapper
  older_wrapper_dir=$older_project_dir/gradle/wrapper

  [ "$requested_version" != "$older_version" ] || fail 'downloaded cross-version replay fixture requires distinct Gradle versions.'
  log "exercising $helper_kind helper downloaded $older_version-as-$requested_version replay rejection in '$project_dir'"
  mkdir -p "$server_root"
  cp "$older_wrapper_dir/gradle-wrapper.jar" "$server_root/gradle-wrapper.jar"
  cp "$older_wrapper_dir/gradle-wrapper-$older_version.sha256" "$server_root/wrapper.sha256"
  cp "$older_wrapper_dir/gradle-wrapper-$older_version.asc" "$server_root/wrapper.asc"
  rm -f \
    "$wrapper_dir/gradle-wrapper.jar" \
    "$wrapper_dir/gradle-wrapper-$requested_version.sha256" \
    "$wrapper_dir/gradle-wrapper-$requested_version.asc"

  start_static_http_server "$server_root"
  configure_helper_download_urls "$project_dir" "$helper_kind" "http://127.0.0.1:$TEST_HTTP_SERVER_PORT"
  "run_${helper_kind}_helper_direct" "$project_dir"
  stop_test_http_server

  assert_last_command_failed "$helper_kind helper unexpectedly accepted a genuine older signed wrapper artifact triplet from the download path."
  assert_last_output_contains 'buildishWrapperJarSha256Sum does not match the Gradle-published wrapper JAR checksum' "$helper_kind helper did not identify the downloaded cross-version replay as a project-pin mismatch."
  [ ! -e "$wrapper_dir/gradle-wrapper.jar" ] || fail "$helper_kind helper downloaded or published a wrapper JAR after the upstream checksum disagreed with the project pin."
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
    case $init_script_path in
      *[[:space:]]*) expected_output="--init-script \"$init_script_path\"" ;;
      *) expected_output="--init-script $init_script_path" ;;
    esac
    assert_last_output_equals "$expected_output" 'PowerShell helper emitted diagnostics or HTTP response objects while downloading and verifying a two-segment Gradle wrapper.'
  fi
}

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

# Exercise PowerShell helper init-script injection and deduplication so the
# batch launcher contract keeps quoting paths with spaces correctly.
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

# Run the helper edge-case matrix for both shells on isolated fixture copies so
# recovery, rejection, and timeout behaviors stay symmetric.
run_helper_edge_case_suite() {
  test_root=$1
  posix_base_project=$2
  powershell_base_project=$3
  scenario_root="$test_root/helper-edge-cases"
  posix_version=$(extract_gradle_version "$posix_base_project")
  powershell_version=$(extract_gradle_version "$powershell_base_project")
  replay_source_project=$scenario_root/replay-source

  [ -n "$posix_version" ] || fail 'unable to extract the installed Gradle version for the POSIX helper edge-case suite.'
  [ -n "$powershell_version" ] || fail 'unable to extract the installed Gradle version for the PowerShell helper edge-case suite.'
  prepare_cross_version_replay_source "$posix_base_project" "$replay_source_project" "$TWO_SEGMENT_GRADLE_VERSION"
  [ "$(hash_file "$posix_base_project/gradle/wrapper/gradle-wrapper.jar")" != "$(hash_file "$replay_source_project/gradle/wrapper/gradle-wrapper.jar")" ] ||
    fail 'cross-version replay source must have a wrapper-JAR digest distinct from the requested-version fixture.'

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-corrupted-jar-cached-metadata"
  exercise_helper_recovery_with_cached_metadata "$scenario_root/posix-corrupted-jar-cached-metadata" "$posix_version" posix

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-corrupted-jar-missing-metadata"
  exercise_helper_recovery_scenario "$scenario_root/posix-corrupted-jar-missing-metadata" "$posix_version" posix

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-invalid-distribution-url"
  exercise_helper_invalid_distribution_failure "$scenario_root/posix-invalid-distribution-url" posix

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-malformed-sha256"
  exercise_helper_malformed_metadata_recovery "$scenario_root/posix-malformed-sha256" "$posix_version" posix sha256

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-malformed-asc"
  exercise_helper_malformed_metadata_recovery "$scenario_root/posix-malformed-asc" "$posix_version" posix asc

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-oversized-sha256-download"
  exercise_helper_oversized_download_failure "$scenario_root/posix-oversized-sha256-download" "$posix_version" posix sha256

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-oversized-asc-download"
  exercise_helper_oversized_download_failure "$scenario_root/posix-oversized-asc-download" "$posix_version" posix asc

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-oversized-wrapper-jar-download"
  exercise_helper_oversized_download_failure "$scenario_root/posix-oversized-wrapper-jar-download" "$posix_version" posix jar

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-symlinked-sha256"
  exercise_helper_symlink_rejection "$scenario_root/posix-symlinked-sha256" "$posix_version" posix sha256

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-symlinked-init-script"
  exercise_helper_symlink_rejection "$scenario_root/posix-symlinked-init-script" "$posix_version" posix init-script

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-missing-properties"
  exercise_helper_missing_properties_failure "$scenario_root/posix-missing-properties" posix

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-missing-distribution-url"
  exercise_helper_missing_distribution_url_failure "$scenario_root/posix-missing-distribution-url" posix

  for failure_kind in missing duplicate malformed; do
    copy_project_fixture "$posix_base_project" "$scenario_root/posix-wrapper-pin-$failure_kind"
    exercise_helper_wrapper_pin_validation_failure "$scenario_root/posix-wrapper-pin-$failure_kind" posix "$failure_kind"
  done

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-cached-cross-version-replay"
  exercise_helper_cached_cross_version_replay_rejection "$scenario_root/posix-cached-cross-version-replay" "$replay_source_project" posix

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-downloaded-cross-version-replay"
  exercise_helper_downloaded_cross_version_replay_rejection "$scenario_root/posix-downloaded-cross-version-replay" "$replay_source_project" posix

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-two-segment-version"
  exercise_helper_two_segment_version_support "$scenario_root/posix-two-segment-version" posix "$TWO_SEGMENT_GRADLE_VERSION"

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-init-script-dedup"
  exercise_posix_helper_init_script_deduplication "$scenario_root/posix-init-script-dedup"

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-corrupted-jar-cached-metadata"
  exercise_helper_recovery_with_cached_metadata "$scenario_root/powershell-corrupted-jar-cached-metadata" "$powershell_version" powershell

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-corrupted-jar-missing-metadata"
  exercise_helper_recovery_scenario "$scenario_root/powershell-corrupted-jar-missing-metadata" "$powershell_version" powershell

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-invalid-distribution-url"
  exercise_helper_invalid_distribution_failure "$scenario_root/powershell-invalid-distribution-url" powershell

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-malformed-sha256"
  exercise_helper_malformed_metadata_recovery "$scenario_root/powershell-malformed-sha256" "$powershell_version" powershell sha256

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-malformed-asc"
  exercise_helper_malformed_metadata_recovery "$scenario_root/powershell-malformed-asc" "$powershell_version" powershell asc

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-oversized-sha256-download"
  exercise_helper_oversized_download_failure "$scenario_root/powershell-oversized-sha256-download" "$powershell_version" powershell sha256

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-oversized-asc-download"
  exercise_helper_oversized_download_failure "$scenario_root/powershell-oversized-asc-download" "$powershell_version" powershell asc

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-oversized-wrapper-jar-download"
  exercise_helper_oversized_download_failure "$scenario_root/powershell-oversized-wrapper-jar-download" "$powershell_version" powershell jar

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-symlinked-sha256"
  exercise_helper_symlink_rejection "$scenario_root/powershell-symlinked-sha256" "$powershell_version" powershell sha256

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-symlinked-init-script"
  exercise_helper_symlink_rejection "$scenario_root/powershell-symlinked-init-script" "$powershell_version" powershell init-script

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-download-timeout"
  exercise_powershell_helper_download_timeout_failure "$scenario_root/powershell-download-timeout" "$powershell_version"

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-missing-properties"
  exercise_helper_missing_properties_failure "$scenario_root/powershell-missing-properties" powershell

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-missing-distribution-url"
  exercise_helper_missing_distribution_url_failure "$scenario_root/powershell-missing-distribution-url" powershell

  for failure_kind in missing duplicate malformed; do
    copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-wrapper-pin-$failure_kind"
    exercise_helper_wrapper_pin_validation_failure "$scenario_root/powershell-wrapper-pin-$failure_kind" powershell "$failure_kind"
  done

  copy_project_fixture "$posix_base_project" "$scenario_root/powershell-cached-cross-version-replay"
  exercise_helper_cached_cross_version_replay_rejection "$scenario_root/powershell-cached-cross-version-replay" "$replay_source_project" powershell

  copy_project_fixture "$posix_base_project" "$scenario_root/powershell-downloaded-cross-version-replay"
  exercise_helper_downloaded_cross_version_replay_rejection "$scenario_root/powershell-downloaded-cross-version-replay" "$replay_source_project" powershell

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-two-segment-version"
  exercise_helper_two_segment_version_support "$scenario_root/powershell-two-segment-version" powershell "$TWO_SEGMENT_GRADLE_VERSION"

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell helper with spaces"
  exercise_powershell_helper_init_script_output "$scenario_root/powershell helper with spaces"
}
