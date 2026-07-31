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

# Helper artifact integrity, recovery, and metadata scenarios.

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

# Run the symmetric integrity matrix for one helper implementation. replay_base
# is explicit because PowerShell replay tests intentionally use the POSIX fixture.
run_helper_integrity_for_kind() {
  local scenario_root=$1
  local base_project=$2
  local version=$3
  local helper_kind=$4
  local replay_base_project=$5
  local replay_source_project=$6
  local metadata_kind
  local download_kind
  local scenario_kind
  local target_kind

  copy_project_fixture "$base_project" "$scenario_root/$helper_kind-corrupted-jar-cached-metadata"
  exercise_helper_recovery_with_cached_metadata "$scenario_root/$helper_kind-corrupted-jar-cached-metadata" "$version" "$helper_kind"

  copy_project_fixture "$base_project" "$scenario_root/$helper_kind-cached-checksum-read-only"
  exercise_helper_cached_checksum_read_only "$scenario_root/$helper_kind-cached-checksum-read-only" "$version" "$helper_kind"

  copy_project_fixture "$base_project" "$scenario_root/$helper_kind-downloaded-checksum-normalization"
  exercise_helper_downloaded_checksum_normalization "$scenario_root/$helper_kind-downloaded-checksum-normalization" "$version" "$helper_kind"

  copy_project_fixture "$base_project" "$scenario_root/$helper_kind-corrupted-jar-missing-metadata"
  exercise_helper_recovery_scenario "$scenario_root/$helper_kind-corrupted-jar-missing-metadata" "$version" "$helper_kind"

  for metadata_kind in sha256 asc; do
    copy_project_fixture "$base_project" "$scenario_root/$helper_kind-malformed-$metadata_kind"
    exercise_helper_malformed_metadata_recovery "$scenario_root/$helper_kind-malformed-$metadata_kind" "$version" "$helper_kind" "$metadata_kind"
  done

  for download_kind in sha256 asc jar; do
    case $download_kind in
      jar) scenario_kind=wrapper-jar ;;
      *) scenario_kind=$download_kind ;;
    esac
    copy_project_fixture "$base_project" "$scenario_root/$helper_kind-oversized-$scenario_kind-download"
    exercise_helper_oversized_download_failure "$scenario_root/$helper_kind-oversized-$scenario_kind-download" "$version" "$helper_kind" "$download_kind"
  done

  for target_kind in sha256 init-script; do
    copy_project_fixture "$base_project" "$scenario_root/$helper_kind-symlinked-$target_kind"
    exercise_helper_symlink_rejection "$scenario_root/$helper_kind-symlinked-$target_kind" "$version" "$helper_kind" "$target_kind"
  done

  copy_project_fixture "$replay_base_project" "$scenario_root/$helper_kind-cached-cross-version-replay"
  exercise_helper_cached_cross_version_replay_rejection "$scenario_root/$helper_kind-cached-cross-version-replay" "$replay_source_project" "$helper_kind"

  copy_project_fixture "$replay_base_project" "$scenario_root/$helper_kind-downloaded-cross-version-replay"
  exercise_helper_downloaded_cross_version_replay_rejection "$scenario_root/$helper_kind-downloaded-cross-version-replay" "$replay_source_project" "$helper_kind"

  for metadata_kind in sha256 asc; do
    copy_project_fixture "$base_project" "$scenario_root/$helper_kind-metadata-refresh-$metadata_kind"
    exercise_helper_valid_shape_metadata_refresh "$scenario_root/$helper_kind-metadata-refresh-$metadata_kind" "$version" "$helper_kind" "$metadata_kind"
  done
}

run_helper_integrity_suite() {
  local scenario_root=$1
  local posix_base_project=$2
  local powershell_base_project=$3
  local posix_version=$4
  local powershell_version=$5
  local replay_source_project=$scenario_root/replay-source

  prepare_cross_version_replay_source "$posix_base_project" "$replay_source_project" "$TWO_SEGMENT_GRADLE_VERSION"
  [ "$(hash_file "$posix_base_project/gradle/wrapper/gradle-wrapper.jar")" != "$(hash_file "$replay_source_project/gradle/wrapper/gradle-wrapper.jar")" ] ||
    fail 'cross-version replay source must have a wrapper-JAR digest distinct from the requested-version fixture.'

  run_helper_integrity_for_kind "$scenario_root" "$posix_base_project" "$posix_version" posix "$posix_base_project" "$replay_source_project"
  run_helper_integrity_for_kind "$scenario_root" "$powershell_base_project" "$powershell_version" powershell "$posix_base_project" "$replay_source_project"
}
