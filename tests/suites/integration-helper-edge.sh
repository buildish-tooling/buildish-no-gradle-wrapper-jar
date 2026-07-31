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

# Cached checksum validation must tolerate harmless formatting differences
# without rewriting a project file on every launcher invocation.
exercise_helper_cached_checksum_read_only() {
  project_dir=$1
  version=$2
  helper_kind=$3
  checksum_path=$project_dir/gradle/wrapper/gradle-wrapper-$version.sha256
  checksum_snapshot=$project_dir/cached-checksum.before
  checksum=$(tr -d '\r\n' < "$checksum_path" | tr '[:lower:]' '[:upper:]')

  log "exercising $helper_kind helper read-only cached-checksum validation in '$project_dir'"
  printf '%s\r\n' "$checksum" > "$checksum_path"
  cp "$checksum_path" "$checksum_snapshot"

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_succeeded "$helper_kind helper rejected a valid non-canonical cached checksum."
  cmp -s "$checksum_snapshot" "$checksum_path" ||
    fail "$helper_kind helper rewrote the cached checksum during a warm validation."
}

# Newly downloaded checksums are normalized while still temporary so only the
# canonical lowercase/LF form is atomically published into the project cache.
exercise_helper_downloaded_checksum_normalization() {
  project_dir=$1
  version=$2
  helper_kind=$3
  wrapper_dir=$project_dir/gradle/wrapper
  checksum_path=$wrapper_dir/gradle-wrapper-$version.sha256
  signature_path=$wrapper_dir/gradle-wrapper-$version.asc
  jar_path=$wrapper_dir/gradle-wrapper.jar
  server_root=$project_dir/checksum-normalization-server
  expected_checksum=$(tr -d '\r\n' < "$checksum_path" | tr '[:upper:]' '[:lower:]')
  expected_checksum_path=$project_dir/checksum.expected

  log "exercising $helper_kind helper downloaded-checksum normalization in '$project_dir'"
  mkdir -p "$server_root"
  printf '%s\r\n' "$(printf '%s' "$expected_checksum" | tr '[:lower:]' '[:upper:]')" > "$server_root/wrapper.sha256"
  cp "$signature_path" "$server_root/wrapper.asc"
  cp "$jar_path" "$server_root/gradle-wrapper.jar"
  rm -f "$checksum_path" "$signature_path" "$jar_path"
  printf '%s\n' "$expected_checksum" > "$expected_checksum_path"

  start_static_http_server "$server_root"
  configure_helper_download_urls "$project_dir" "$helper_kind" "http://127.0.0.1:$TEST_HTTP_SERVER_PORT"
  "run_${helper_kind}_helper_direct" "$project_dir"
  stop_test_http_server

  assert_last_command_succeeded "$helper_kind helper rejected a valid non-canonical downloaded checksum."
  cmp -s "$expected_checksum_path" "$checksum_path" ||
    fail "$helper_kind helper did not publish the downloaded checksum in canonical lowercase/LF form."
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
      assert_last_output_contains "A GnuPG command ('gpg.exe' preferred, otherwise 'gpg') is required" 'PowerShell helper missing-GPG failure did not identify the unavailable command.'
      ;;
    *)
      fail "unknown helper kind '$helper_kind'"
      ;;
  esac

  diff -r "$snapshot_dir" "$project_dir" >/dev/null || fail "$helper_kind helper changed the project while failing closed without GPG."
}

# Structurally valid but incorrect sidecars used to persist forever. Serve the
# original pair, corrupt one cached file without breaking its shallow validator,
# and require exactly one paired refresh followed by successful verification.
exercise_helper_valid_shape_metadata_refresh() {
  project_dir=$1
  version=$2
  helper_kind=$3
  metadata_kind=$4
  wrapper_dir="$project_dir/gradle/wrapper"
  sha_path="$wrapper_dir/gradle-wrapper-$version.sha256"
  asc_path="$wrapper_dir/gradle-wrapper-$version.asc"
  server_root="$project_dir.metadata-refresh-server"

  mkdir -p "$server_root"
  cp "$sha_path" "$server_root/wrapper.sha256"
  cp "$asc_path" "$server_root/wrapper.asc"
  cp "$wrapper_dir/gradle-wrapper.jar" "$server_root/gradle-wrapper.jar"

  case $metadata_kind in
    sha256)
      log "exercising $helper_kind helper valid-shape wrong-checksum refresh in '$project_dir'"
      printf '%064d\n' 0 > "$sha_path"
      ;;
    asc)
      log "exercising $helper_kind helper cryptographically invalid armored-signature refresh in '$project_dir'"
      printf '%s\n' '-----BEGIN PGP SIGNATURE-----' '' 'invalid-signature-body' '-----END PGP SIGNATURE-----' > "$asc_path"
      ;;
    *)
      fail "unknown metadata refresh kind '$metadata_kind'"
      ;;
  esac

  start_static_http_server "$server_root"
  configure_helper_download_urls "$project_dir" "$helper_kind" "http://127.0.0.1:$TEST_HTTP_SERVER_PORT"
  "run_${helper_kind}_helper_direct" "$project_dir"
  sha_request_count=$(grep -Fc 'GET /wrapper.sha256 ' "$TEST_HTTP_SERVER_LOG" || true)
  asc_request_count=$(grep -Fc 'GET /wrapper.asc ' "$TEST_HTTP_SERVER_LOG" || true)
  stop_test_http_server

  assert_last_command_succeeded "$helper_kind helper did not recover from valid-shape corrupt $metadata_kind metadata."
  [ "$sha_request_count" -eq 1 ] && [ "$asc_request_count" -eq 1 ] ||
    fail "$helper_kind helper metadata recovery was not one bounded paired refresh (sha256 requests=$sha_request_count, signature requests=$asc_request_count)."
  assert_metadata_for_version "$project_dir" "$version"
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
    expected_output="--init-script \"$init_script_path\""
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

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-cached-checksum-read-only"
  exercise_helper_cached_checksum_read_only "$scenario_root/posix-cached-checksum-read-only" "$posix_version" posix

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-downloaded-checksum-normalization"
  exercise_helper_downloaded_checksum_normalization "$scenario_root/posix-downloaded-checksum-normalization" "$posix_version" posix

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

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-download-timeout"
  exercise_posix_helper_download_timeout_failure "$scenario_root/posix-download-timeout" "$posix_version"

  for invalid_timeout in 0 not-a-number; do
    copy_project_fixture "$posix_base_project" "$scenario_root/posix-invalid-timeout-$invalid_timeout"
    exercise_helper_invalid_timeout_configuration_failure "$scenario_root/posix-invalid-timeout-$invalid_timeout" posix "$invalid_timeout"
  done

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-missing-gpg"
  exercise_helper_missing_gpg_failure "$scenario_root/posix-missing-gpg" posix

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

  for metadata_kind in sha256 asc; do
    copy_project_fixture "$posix_base_project" "$scenario_root/posix-metadata-refresh-$metadata_kind"
    exercise_helper_valid_shape_metadata_refresh "$scenario_root/posix-metadata-refresh-$metadata_kind" "$posix_version" posix "$metadata_kind"
  done

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-init-script-dedup"
  exercise_posix_helper_init_script_deduplication "$scenario_root/posix-init-script-dedup"

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-corrupted-jar-cached-metadata"
  exercise_helper_recovery_with_cached_metadata "$scenario_root/powershell-corrupted-jar-cached-metadata" "$powershell_version" powershell

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-cached-checksum-read-only"
  exercise_helper_cached_checksum_read_only "$scenario_root/powershell-cached-checksum-read-only" "$powershell_version" powershell

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-downloaded-checksum-normalization"
  exercise_helper_downloaded_checksum_normalization "$scenario_root/powershell-downloaded-checksum-normalization" "$powershell_version" powershell

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-recovery-stream-protocol"
  exercise_powershell_helper_recovery_stream_protocol "$scenario_root/powershell-recovery-stream-protocol" "$powershell_version"

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

  for invalid_timeout in 0 not-a-number; do
    copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-invalid-timeout-$invalid_timeout"
    exercise_helper_invalid_timeout_configuration_failure "$scenario_root/powershell-invalid-timeout-$invalid_timeout" powershell "$invalid_timeout"
  done

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-missing-gpg"
  exercise_helper_missing_gpg_failure "$scenario_root/powershell-missing-gpg" powershell

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-missing-properties"
  exercise_powershell_helper_failure_stream_protocol "$scenario_root/powershell-missing-properties"

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

  for metadata_kind in sha256 asc; do
    copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-metadata-refresh-$metadata_kind"
    exercise_helper_valid_shape_metadata_refresh "$scenario_root/powershell-metadata-refresh-$metadata_kind" "$powershell_version" powershell "$metadata_kind"
  done

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell helper with spaces"
  exercise_powershell_helper_init_script_output "$scenario_root/powershell helper with spaces"

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell&helper^(meta)%pct!bang"
  exercise_powershell_helper_init_script_output "$scenario_root/powershell&helper^(meta)%pct!bang"
}
