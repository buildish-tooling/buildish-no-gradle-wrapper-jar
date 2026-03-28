#!/usr/bin/env bash
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

append_wrapper_pair() {
  local consumer=$1 version=$2
  local digest
  digest=$(manifest_entry_value wrapperVersions "$version" wrapperJarSha256)
  cat >>"$consumer/gradle/wrapper/gradle-wrapper.properties" <<EOF
buildishWrapperJarVersion=$version
buildishWrapperJarSha256Sum=$digest
EOF
}

run_sourced_helper() {
  local consumer=$1
  env APP_HOME="$consumer" bash -c '
    set -eu
    set -- probe-argument
    . "$APP_HOME/gradle/buildish-wrapper-bootstrap.sh"
    [ "$1" = "--init-script" ]
    [ "$2" = "$APP_HOME/gradle/buildish-wrapper.init.gradle.kts" ]
    [ "$3" = "probe-argument" ]
  '
}

prepare_runtime_consumer() {
  local name=$1 version=$2 route=$3
  local consumer=$BUILDISH_TEST_ROOT/$name
  create_consumer "$consumer" "$version" "$version"
  append_wrapper_pair "$consumer" "$version"
  substitute_runtime_url \
    "$consumer/gradle/buildish-wrapper-bootstrap.sh" \
    "http://127.0.0.1:$BUILDISH_TEST_HTTP_PORT$route?source="
  printf '%s\n' "$consumer"
}

assert_failed_download_clean() {
  local consumer=$1
  assert_file_absent "$consumer/gradle/wrapper/gradle-wrapper.jar"
  local extras
  extras=$(find "$consumer/gradle/wrapper" -maxdepth 1 -type f \
    ! -name gradle-wrapper.properties -print)
  [[ -z $extras ]] || test_fail "failed download left files behind: $extras"
}

run_invalid_runtime_configuration_case() {
  local name=$1 expected_error=$2 mutation=$3
  local consumer before_count after_count
  consumer=$(prepare_runtime_consumer "runtime-config-$name" 8.14.5 /jar)
  case $mutation in
    missing)
      sed -i '/^buildishWrapperJarSha256Sum=/d' \
        "$consumer/gradle/wrapper/gradle-wrapper.properties"
      ;;
    duplicate)
      printf 'buildishWrapperJarVersion=8.14.5\n' >> \
        "$consumer/gradle/wrapper/gradle-wrapper.properties"
      ;;
    noncanonical)
      sed -i 's/^buildishWrapperJarVersion=/buildishWrapperJarVersion : /' \
        "$consumer/gradle/wrapper/gradle-wrapper.properties"
      ;;
    leading-zero)
      sed -i 's/^buildishWrapperJarVersion=.*/buildishWrapperJarVersion=08.14.5/' \
        "$consumer/gradle/wrapper/gradle-wrapper.properties"
      ;;
    suffix)
      sed -i 's/^buildishWrapperJarVersion=.*/buildishWrapperJarVersion=8.14.5-rc-1/' \
        "$consumer/gradle/wrapper/gradle-wrapper.properties"
      ;;
    path)
      sed -i 's|^buildishWrapperJarVersion=.*|buildishWrapperJarVersion=8.14.5/../../other|' \
        "$consumer/gradle/wrapper/gradle-wrapper.properties"
      ;;
    backslash)
      sed -i 's|^buildishWrapperJarVersion=.*|buildishWrapperJarVersion=8.14.5\\other|' \
        "$consumer/gradle/wrapper/gradle-wrapper.properties"
      ;;
    percent)
      sed -i 's/^buildishWrapperJarVersion=.*/buildishWrapperJarVersion=8.14.5%2fother/' \
        "$consumer/gradle/wrapper/gradle-wrapper.properties"
      ;;
    whitespace)
      sed -i 's/^buildishWrapperJarVersion=.*/buildishWrapperJarVersion=8.14. 5/' \
        "$consumer/gradle/wrapper/gradle-wrapper.properties"
      ;;
    colon)
      sed -i 's/^buildishWrapperJarVersion=.*/buildishWrapperJarVersion=8.14.5:other/' \
        "$consumer/gradle/wrapper/gradle-wrapper.properties"
      ;;
    query)
      sed -i 's/^buildishWrapperJarVersion=.*/buildishWrapperJarVersion=8.14.5?other/' \
        "$consumer/gradle/wrapper/gradle-wrapper.properties"
      ;;
    fragment)
      sed -i 's/^buildishWrapperJarVersion=.*/buildishWrapperJarVersion=8.14.5#other/' \
        "$consumer/gradle/wrapper/gradle-wrapper.properties"
      ;;
    *) test_fail "unknown runtime configuration mutation: $mutation" ;;
  esac
  before_count=$(http_route_request_count "$BUILDISH_TEST_HTTP_LOG" /jar)
  expect_failure "runtime-config-$name" 10 run_sourced_helper "$consumer"
  after_count=$(http_route_request_count "$BUILDISH_TEST_HTTP_LOG" /jar)
  assert_equal "$before_count" "$after_count" "$name must fail before network access"
  assert_equal '' "$BUILDISH_TEST_LAST_STDOUT" "$name configuration failure stdout"
  assert_contains "$BUILDISH_TEST_LAST_STDERR" "$expected_error" \
    "$name configuration diagnostic"
  assert_failed_download_clean "$consumer"
}

run_runtime_suite() {
  BUILDISH_TEST_CASE='runtime canonical sources'
  require_canonical_sources
  require_command curl
  require_command timeout

  local payload consumer actual expected sentinel_dir failing route label expected_error
  payload=$(provision_wrapper_jar 8.14.5)
  start_http_fixture "$payload"
  local correct_port=$BUILDISH_TEST_HTTP_PORT
  local correct_log=$BUILDISH_TEST_HTTP_LOG

  BUILDISH_TEST_CASE='runtime cold verified publication'
  consumer=$(prepare_runtime_consumer 'runtime cold path with spaces' 8.14.5 /jar)
  expect_success runtime-cold 30 run_sourced_helper "$consumer"
  assert_equal '' "$BUILDISH_TEST_LAST_STDOUT" 'cold bootstrap stdout'
  assert_http_route_requested_once "$correct_log" /jar
  actual=$(sha256_file "$consumer/gradle/wrapper/gradle-wrapper.jar")
  expected=$(manifest_entry_value wrapperVersions 8.14.5 wrapperJarSha256)
  assert_equal "$expected" "$actual" 'cold-published Wrapper JAR digest'
  assert_no_wrapper_temporaries "$consumer/gradle/wrapper"

  BUILDISH_TEST_CASE='runtime CRLF properties and property-name comments'
  consumer=$(prepare_runtime_consumer runtime-crlf-comments 8.14.5 /jar)
  python3 - "$consumer/gradle/wrapper/gradle-wrapper.properties" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
if b"\r" in data:
    raise SystemExit("fixture unexpectedly contains CR before CRLF conversion")
comments = (
    b"# buildishWrapperJarVersion is maintained by Buildish\n"
    b"! buildishWrapperJarSha256Sum is reviewed configuration\n"
    b"unrelatedProperty=buildishWrapperJarVersion\n"
)
path.write_bytes((comments + data).replace(b"\n", b"\r\n"))
PY
  expect_success runtime-crlf-comments 30 run_sourced_helper "$consumer"
  assert_equal '' "$BUILDISH_TEST_LAST_STDOUT" 'CRLF/comment bootstrap stdout'
  actual=$(sha256_file "$consumer/gradle/wrapper/gradle-wrapper.jar")
  assert_equal "$expected" "$actual" 'CRLF/comment published Wrapper JAR digest'
  assert_http_route_request_count "$correct_log" /jar 2
  assert_no_wrapper_temporaries "$consumer/gradle/wrapper"

  BUILDISH_TEST_CASE='runtime warm path avoids tools'
  sentinel_dir=$BUILDISH_TEST_ROOT/warm-sentinels
  mkdir -p "$sentinel_dir"
  for tool in curl sha256sum shasum; do
    cat >"$sentinel_dir/$tool" <<'EOF'
#!/bin/sh
echo 'warm-path sentinel was invoked' >&2
exit 97
EOF
    chmod +x "$sentinel_dir/$tool"
  done
  expect_success runtime-warm 10 env PATH="$sentinel_dir:/usr/bin:/bin" \
    APP_HOME="$consumer" bash -c '
      set -eu
      set -- probe-argument
      trap "exit 79" TERM
      trap_before=$(trap -p TERM)
      . "$APP_HOME/gradle/buildish-wrapper-bootstrap.sh"
      [ "$1" = "--init-script" ]
      [ "$(trap -p TERM)" = "$trap_before" ]
      while read -r _ _ function_name; do
        case $function_name in
          buildish_wrapper_bootstrap_*) ;;
          *) echo "unnamespaced helper function: $function_name" >&2; exit 1 ;;
        esac
      done < <(declare -F)
    '

  BUILDISH_TEST_CASE='runtime invalid configuration fails before network'
  run_invalid_runtime_configuration_case missing \
    'expected exactly one canonical Wrapper JAR version and digest' missing
  run_invalid_runtime_configuration_case duplicate \
    'expected exactly one canonical Wrapper JAR version and digest' duplicate
  run_invalid_runtime_configuration_case noncanonical \
    'expected exactly one canonical Wrapper JAR version and digest' noncanonical
  run_invalid_runtime_configuration_case leading-zero \
    'Wrapper JAR version must be a canonical three-component stable version' leading-zero
  run_invalid_runtime_configuration_case suffix \
    'Wrapper JAR version must be a canonical three-component stable version' suffix
  run_invalid_runtime_configuration_case path \
    'Wrapper JAR version must be a canonical three-component stable version' path
  for mutation in backslash percent whitespace colon query fragment; do
    run_invalid_runtime_configuration_case "$mutation" \
      'Wrapper JAR version must be a canonical three-component stable version' \
      "$mutation"
  done

  BUILDISH_TEST_CASE='runtime valid non-matrix version uses the derived fixed source'
  consumer=$(prepare_runtime_consumer runtime-non-matrix-version 8.14.5 /jar)
  sed -i 's/^buildishWrapperJarVersion=.*/buildishWrapperJarVersion=7.8.9/' \
    "$consumer/gradle/wrapper/gradle-wrapper.properties"
  local before_non_matrix after_non_matrix
  before_non_matrix=$(http_route_request_count "$correct_log" /jar)
  expect_success runtime-non-matrix-version 30 run_sourced_helper "$consumer"
  after_non_matrix=$(http_route_request_count "$correct_log" /jar)
  assert_equal "$((before_non_matrix + 1))" "$after_non_matrix" \
    'non-matrix version derived-source request count'
  assert_http_request_path_once "$correct_log" \
    '/jar?source=v7.8.9/gradle/wrapper/gradle-wrapper.jar'
  actual=$(sha256_file "$consumer/gradle/wrapper/gradle-wrapper.jar")
  assert_equal "$expected" "$actual" 'non-matrix version digest-authorized publication'

  BUILDISH_TEST_CASE='runtime digest mismatch'
  local bad_payload=$BUILDISH_TEST_ROOT/wrong-wrapper.jar
  printf 'not a Wrapper JAR\n' >"$bad_payload"
  start_http_fixture "$bad_payload"
  local bad_log=$BUILDISH_TEST_HTTP_LOG
  failing=$(prepare_runtime_consumer runtime-digest-mismatch 8.14.5 /jar)
  expect_failure runtime-digest-mismatch 30 run_sourced_helper "$failing"
  assert_equal '' "$BUILDISH_TEST_LAST_STDOUT" 'digest-mismatch stdout'
  assert_contains "$BUILDISH_TEST_LAST_STDERR" \
    'downloaded Wrapper JAR digest mismatch: expected ' \
    'digest-mismatch diagnostic'
  assert_contains "$BUILDISH_TEST_LAST_STDERR" \
    ', found ' 'digest-mismatch actual-digest diagnostic'
  assert_http_route_requested_once "$bad_log" /jar
  assert_failed_download_clean "$failing"
  BUILDISH_TEST_HTTP_PORT=$correct_port
  BUILDISH_TEST_HTTP_LOG=$correct_log

  while IFS=$'\t' read -r route expected_error; do
    label=${route//\//-}
    BUILDISH_TEST_CASE="runtime failure $route"
    failing=$(prepare_runtime_consumer "runtime-$label" 8.14.5 "$route")
    expect_failure "runtime$label" 30 run_sourced_helper "$failing"
    assert_equal '' "$BUILDISH_TEST_LAST_STDOUT" "$route failure stdout"
    assert_contains "$BUILDISH_TEST_LAST_STDERR" "$expected_error" \
      "$route focused failure diagnostic"
    assert_contains "$BUILDISH_TEST_LAST_STDERR" 'Wrapper JAR download failed' \
      "$route bootstrap failure diagnostic"
    assert_http_route_requested_once "$correct_log" "$route"
    assert_failed_download_clean "$failing"
  done <<'EOF'
/status/503	503
/stall	imed out
/oversize/accurate	Maximum file size exceeded
/oversize/missing	maximum allowed file size
/oversize/misleading	maximum allowed file size
EOF

  BUILDISH_TEST_CASE='runtime concurrent same-pin publication'
  local concurrent=$BUILDISH_TEST_ROOT/runtime-concurrent
  create_consumer "$concurrent" 8.14.5 8.14.5
  append_wrapper_pair "$concurrent" 8.14.5
  substitute_runtime_url "$concurrent/gradle/buildish-wrapper-bootstrap.sh" \
    "http://127.0.0.1:$BUILDISH_TEST_HTTP_PORT/jar/barrier?source="
  set +e
  expect_success runtime-concurrent-first 30 run_sourced_helper "$concurrent" &
  local first=$!
  register_cleanup_pid "$first"
  expect_success runtime-concurrent-second 30 run_sourced_helper "$concurrent" &
  local second=$!
  register_cleanup_pid "$second"
  local first_status second_status
  if wait "$first"; then first_status=0; else first_status=$?; fi
  unregister_cleanup_pid "$first"
  if wait "$second"; then second_status=0; else second_status=$?; fi
  unregister_cleanup_pid "$second"
  set -e
  assert_equal 0 "$first_status" 'first concurrent bootstrap exit'
  assert_equal 0 "$second_status" 'second concurrent bootstrap exit'
  actual=$(sha256_file "$concurrent/gradle/wrapper/gradle-wrapper.jar")
  assert_equal "$expected" "$actual" 'concurrent final Wrapper JAR digest'
  assert_http_route_request_count "$correct_log" /jar/barrier 2
  assert_no_wrapper_temporaries "$concurrent/gradle/wrapper"

  BUILDISH_TEST_CASE='runtime 9.6.1 cold verified publication'
  payload=$(provision_wrapper_jar 9.6.1)
  start_http_fixture "$payload"
  local version_961_log=$BUILDISH_TEST_HTTP_LOG
  consumer=$(prepare_runtime_consumer runtime-cold-9.6.1 9.6.1 /jar)
  expect_success runtime-cold-9.6.1 30 run_sourced_helper "$consumer"
  assert_equal '' "$BUILDISH_TEST_LAST_STDOUT" '9.6.1 cold bootstrap stdout'
  actual=$(sha256_file "$consumer/gradle/wrapper/gradle-wrapper.jar")
  expected=$(manifest_entry_value wrapperVersions 9.6.1 wrapperJarSha256)
  assert_equal "$expected" "$actual" '9.6.1 cold-published Wrapper JAR digest'
  assert_http_route_requested_once "$version_961_log" /jar
  assert_no_wrapper_temporaries "$consumer/gradle/wrapper"
}
