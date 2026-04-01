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

# This script serves two roles:
#   * the default integration suite used by `make test`
#   * a reusable "version list exercise" that can probe many Gradle wrapper
#     versions via `./gradlew wrapper --gradle-version ...`
#
# The default suite still covers both installers. The version-list exercise is
# intentionally POSIX-centric because its purpose is to discover which generated
# launcher shapes and wrapper versions this helper can support; each probe still
# verifies both `gradlew` and generated `gradlew.bat` patching.

TOOL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$TOOL_DIR/build/tests
UPDATED_GRADLE_VERSION=${UPDATED_GRADLE_VERSION:-8.14}
TWO_SEGMENT_GRADLE_VERSION=${TWO_SEGMENT_GRADLE_VERSION:-8.3}
HELPER_MAX_METADATA_BYTES=65536
HELPER_MAX_JAR_BYTES=10485760
INSTALLER_MAX_TOOL_FILE_BYTES=262144

fail() {
  echo "integration-test: $*" >&2
  exit 1
}

log() {
  echo "integration-test: $*"
}

CAPTURED_OUTPUT=''
CAPTURED_STATUS=0
TEST_HTTP_SERVER_PID=''
TEST_HTTP_SERVER_PORT=''
TEST_HTTP_SERVER_LOG=''
TEST_HTTP_SERVER_PORT_FILE=''

run_and_capture() {
  output_file=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-test.XXXXXX")
  set +e
  "$@" >"$output_file" 2>&1
  CAPTURED_STATUS=$?
  set -e
  CAPTURED_OUTPUT=$(cat "$output_file")
  rm -f "$output_file"
}

assert_last_command_succeeded() {
  [ "$CAPTURED_STATUS" -eq 0 ] || fail "$1 (exit status=$CAPTURED_STATUS, output=$CAPTURED_OUTPUT)"
}

assert_last_command_failed() {
  [ "$CAPTURED_STATUS" -ne 0 ] || fail "$1"
}

assert_last_output_contains() {
  expected_text=$1
  failure_message=$2
  printf '%s' "$CAPTURED_OUTPUT" | grep -Fq "$expected_text" || fail "$failure_message (output=$CAPTURED_OUTPUT)"
}

assert_last_output_contains_collapsed_whitespace() {
  expected_text=$1
  failure_message=$2
  normalized_expected=$(printf '%s' "$expected_text" | tr '\n\r|' '   ' | tr -s '[:space:]' ' ')
  normalized_output=$(printf '%s' "$CAPTURED_OUTPUT" | tr '\n\r|' '   ' | tr -s '[:space:]' ' ')
  printf '%s' "$normalized_output" | grep -Fq "$normalized_expected" || fail "$failure_message (output=$CAPTURED_OUTPUT)"
}

assert_last_output_not_contains() {
  unexpected_text=$1
  failure_message=$2
  if printf '%s' "$CAPTURED_OUTPUT" | grep -Fq "$unexpected_text"; then
    fail "$failure_message (output=$CAPTURED_OUTPUT)"
  fi
}

assert_last_output_equals() {
  expected_text=$1
  failure_message=$2
  [ "$CAPTURED_OUTPUT" = "$expected_text" ] || fail "$failure_message (output=$CAPTURED_OUTPUT)"
}

assert_last_output_exact_line_count() {
  expected_line=$1
  expected_count=$2
  failure_message=$3
  CAPTURED_OUTPUT_FOR_PY=$CAPTURED_OUTPUT python3 - <<'PY' "$expected_line" "$expected_count" || fail "$failure_message (output=$CAPTURED_OUTPUT)"
import sys
import os

expected_line = sys.argv[1]
expected_count = int(sys.argv[2])
lines = os.environ['CAPTURED_OUTPUT_FOR_PY'].splitlines()
actual_count = sum(1 for line in lines if line == expected_line)
raise SystemExit(0 if actual_count == expected_count else 1)
PY
}

source_sdkman_gradle() {
  if [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && ! command -v sdk >/dev/null 2>&1; then
    set +u
    . "$HOME/.sdkman/bin/sdkman-init.sh"
    set -u
  fi
  if command -v gradle >/dev/null 2>&1; then
    return 0
  fi
  [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] || fail "gradle is not on PATH and SDKMAN init script was not found."
  command -v gradle >/dev/null 2>&1 || fail 'gradle is still not available on PATH after sourcing SDKMAN.'
}

use_sdkman_gradle_version() {
  version=$1
  source_sdkman_gradle
  command -v sdk >/dev/null 2>&1 || fail 'SDKMAN is required to select the bootstrap Gradle version for the version exercise.'
  set +u
  sdk use gradle "$version" >/dev/null
  set -u
  command -v gradle >/dev/null 2>&1 || fail "gradle is not available on PATH after selecting SDKMAN Gradle version '$version'."
}

select_sdkman_java_version_for_version_exercise() {
  [ -d "$HOME/.sdkman/candidates/java" ] || fail 'SDKMAN Java candidates directory was not found for the version exercise.'
  java_version=$(find "$HOME/.sdkman/candidates/java" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep '^17\.' | sort -V | tail -n 1)
  [ -n "$java_version" ] || fail 'The version exercise requires an installed SDKMAN Java 17.x runtime to run Gradle 8.1.x safely.'
  printf '%s' "$java_version"
}

use_sdkman_java_version() {
  version=$1
  source_sdkman_gradle
  command -v sdk >/dev/null 2>&1 || fail 'SDKMAN is required to select the Java runtime for the version exercise.'
  set +u
  sdk use java "$version" >/dev/null
  set -u
  command -v java >/dev/null 2>&1 || fail "java is not available on PATH after selecting SDKMAN Java version '$version'."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is not available on PATH."
}

require_base_commands() {
  source_sdkman_gradle
  require_command gradle
  require_command gpg
  require_command python3
  command -v sha256sum >/dev/null 2>&1 || require_command shasum
  mkdir -p "$BUILD_DIR"
}

sanitize_for_path() {
  printf '%s' "$1" | tr '/:' '__' | tr -c 'A-Za-z0-9._-' '_'
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

extract_gradle_version() {
  sed -n 's/^distributionUrl=.*gradle-\([0-9.][0-9.]*\)-[a-z]*\.zip$/\1/p' "$1/gradle/wrapper/gradle-wrapper.properties"
}

gradle_user_home() {
  printf '%s-gradle-user-home' "$1"
}

gradle_init_script_path() {
  printf '%s/gradle/buildish-no-gradle-wrapper-jar.init.gradle.kts' "$1"
}

write_file_with_size() {
  file_path=$1
  size_bytes=$2
  prefix_text=${3:-}
  python3 - <<'PY' "$file_path" "$size_bytes" "$prefix_text"
from pathlib import Path
import sys

path = Path(sys.argv[1])
size_bytes = int(sys.argv[2])
prefix = sys.argv[3].encode('utf-8')
if len(prefix) > size_bytes:
    raise SystemExit(1)
path.write_bytes(prefix + (b'a' * (size_bytes - len(prefix))))
PY
}

stop_static_http_server() {
  if [ -n "$TEST_HTTP_SERVER_PID" ]; then
    kill "$TEST_HTTP_SERVER_PID" >/dev/null 2>&1 || true
    wait "$TEST_HTTP_SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$TEST_HTTP_SERVER_LOG" "$TEST_HTTP_SERVER_PORT_FILE"
  TEST_HTTP_SERVER_PID=''
  TEST_HTTP_SERVER_PORT=''
  TEST_HTTP_SERVER_LOG=''
  TEST_HTTP_SERVER_PORT_FILE=''
}

start_static_http_server() {
  served_dir=$1
  stop_static_http_server
  TEST_HTTP_SERVER_PORT_FILE=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-http-port.XXXXXX")
  TEST_HTTP_SERVER_LOG=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-http-log.XXXXXX")

  python3 - <<'PY' "$served_dir" "$TEST_HTTP_SERVER_PORT_FILE" >"$TEST_HTTP_SERVER_LOG" 2>&1 &
import functools
import http.server
import socketserver
import sys

served_dir = sys.argv[1]
port_file = sys.argv[2]

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=served_dir)
with ReusableTCPServer(("127.0.0.1", 0), handler) as httpd:
    with open(port_file, "w", encoding="utf-8") as handle:
        handle.write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY
  TEST_HTTP_SERVER_PID=$!

  for _ in $(seq 1 100); do
    if [ -s "$TEST_HTTP_SERVER_PORT_FILE" ]; then
      TEST_HTTP_SERVER_PORT=$(cat "$TEST_HTTP_SERVER_PORT_FILE")
      return 0
    fi
    if ! kill -0 "$TEST_HTTP_SERVER_PID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.05
  done

  log_contents=$(cat "$TEST_HTTP_SERVER_LOG" 2>/dev/null || true)
  stop_static_http_server
  fail "unable to start the local HTTP test server. log=$log_contents"
}

copy_project_fixture() {
  source_dir=$1
  target_dir=$2
  rm -rf "$target_dir"
  mkdir -p "$(dirname "$target_dir")"
  cp -R "$source_dir" "$target_dir"
}

copy_init_script_into_project() {
  project_dir=$1
  mkdir -p "$project_dir/gradle"
  cp "$TOOL_DIR/buildish-no-gradle-wrapper-jar.init.gradle.kts" "$(gradle_init_script_path "$project_dir")"
}

copy_init_script_fixture() {
  source_dir=$1
  target_dir=$2
  copy_project_fixture "$source_dir" "$target_dir"
  copy_init_script_into_project "$target_dir"
}

gradle_init_fixture() {
  project_dir=$1
  bootstrap_gradle_version=${2:-}
  fixture_gradle_user_home=$(gradle_user_home "$project_dir")
  mkdir -p "$project_dir"
  log "initializing fixture in '$project_dir' (GRADLE_USER_HOME='$fixture_gradle_user_home'${bootstrap_gradle_version:+, bootstrap Gradle='$bootstrap_gradle_version'})"
  if [ -n "$bootstrap_gradle_version" ]; then
    use_sdkman_gradle_version "$bootstrap_gradle_version"
    # Gradle 8.1.x still prompts for the target Java version and whether to use
    # incubating APIs even when the project type and DSL are specified. Feed the
    # stable answers explicitly so the version exercise stays non-interactive.
    printf '17\nno\n' | GRADLE_USER_HOME="$fixture_gradle_user_home" gradle -p "$project_dir" init --dsl groovy --type java-library --project-name sample --package org.example --test-framework junit --no-daemon --console=plain >/dev/null
  else
    GRADLE_USER_HOME="$fixture_gradle_user_home" gradle -p "$project_dir" init --dsl groovy --type java-library --use-defaults --no-daemon >/dev/null
  fi
  [ -f "$project_dir/gradle/wrapper/gradle-wrapper.jar" ] || fail "gradle init did not create gradle-wrapper.jar in '$project_dir'."
}

assert_helper_files() {
  project_dir=$1
  test -f "$project_dir/gradle/buildish-no-gradle-wrapper-jar.sh" || fail 'missing POSIX helper file.'
  test -f "$project_dir/gradle/buildish-no-gradle-wrapper-jar.ps1" || fail 'missing PowerShell helper file.'
  test -f "$project_dir/gradle/buildish-no-gradle-wrapper-jar.init.gradle.kts" || fail 'missing Gradle init script.'
}

file_has_exact_line() {
  file_path=$1
  expected_line=$2
  python3 - <<'PY' "$file_path" "$expected_line"
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
raise SystemExit(0 if sys.argv[2] in lines else 1)
PY
}

file_has_exact_line_count() {
  file_path=$1
  expected_line=$2
  expected_count=$3
  python3 - <<'PY' "$file_path" "$expected_line" "$expected_count"
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text().splitlines()
expected_line = sys.argv[2]
expected_count = int(sys.argv[3])
actual_count = sum(1 for line in lines if line == expected_line)
raise SystemExit(0 if actual_count == expected_count else 1)
PY
}

assert_file_exact_line_count() {
  file_path=$1
  expected_line=$2
  expected_count=$3
  failure_message=$4
  file_has_exact_line_count "$file_path" "$expected_line" "$expected_count" || fail "$failure_message"
}

file_contains_text() {
  file_path=$1
  expected_text=$2
  python3 - <<'PY' "$file_path" "$expected_text"
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text().replace('\r\n', '\n')
raise SystemExit(0 if sys.argv[2] in text else 1)
PY
}

assert_file_newline_shape() {
  file_path=$1
  expected_style=$2
  expected_trailing_newline=$3
  failure_message=$4
  python3 - <<'PY' "$file_path" "$expected_style" "$expected_trailing_newline" || fail "$failure_message"
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
expected_style = sys.argv[2]
expected_trailing_newline = sys.argv[3]

if expected_style == 'lf':
    style_ok = b'\r\n' not in data and b'\n' in data
    trailing_ok = data.endswith(b'\n') if expected_trailing_newline == 'yes' else not data.endswith(b'\n')
elif expected_style == 'crlf':
    style_ok = b'\r\n' in data and b'\n' not in data.replace(b'\r\n', b'')
    trailing_ok = data.endswith(b'\r\n') if expected_trailing_newline == 'yes' else not data.endswith(b'\r\n')
else:
    raise SystemExit(1)

raise SystemExit(0 if style_ok and trailing_ok else 1)
PY
}

set_wrapper_property() {
  file_path=$1
  property_name=$2
  property_value=$3
  python3 - <<'PY' "$file_path" "$property_name" "$property_value"
from pathlib import Path
import sys

path = Path(sys.argv[1])
name = sys.argv[2]
value = sys.argv[3]
lines = path.read_text().splitlines()
updated = []
replaced = False
for line in lines:
    if line.startswith(f"{name}="):
        updated.append(f"{name}={value}")
        replaced = True
    else:
        updated.append(line)
if not replaced:
    updated.append(f"{name}={value}")
path.write_text("\n".join(updated) + "\n")
PY
}

remove_wrapper_property() {
  file_path=$1
  property_name=$2
  python3 - <<'PY' "$file_path" "$property_name"
from pathlib import Path
import sys

path = Path(sys.argv[1])
name = sys.argv[2]
lines = [line for line in path.read_text().splitlines() if not line.startswith(f"{name}=")]
path.write_text("\n".join(lines) + "\n")
PY
}

configure_helper_download_urls() {
  project_dir=$1
  helper_kind=$2
  base_url=$3

  case "$helper_kind" in
    posix)
      python3 - <<'PY' "$project_dir/gradle/buildish-no-gradle-wrapper-jar.sh" "$base_url"
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
base_url = sys.argv[2]
text = path.read_text()
replacements = {
    r'^BUILDISH_HELPER_SHA256_URL=.*$': f"BUILDISH_HELPER_SHA256_URL='{base_url}/wrapper.sha256'",
    r'^BUILDISH_HELPER_SIGNATURE_URL=.*$': f"BUILDISH_HELPER_SIGNATURE_URL='{base_url}/wrapper.asc'",
    r'^BUILDISH_HELPER_JAR_URL=.*$': f"BUILDISH_HELPER_JAR_URL='{base_url}/gradle-wrapper.jar'",
}
for pattern, replacement in replacements.items():
    text, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(1)
path.write_text(text)
PY
      ;;
    powershell)
      python3 - <<'PY' "$project_dir/gradle/buildish-no-gradle-wrapper-jar.ps1" "$base_url"
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
base_url = sys.argv[2]
text = path.read_text()
replacements = {
    r'^\s*\$GradleWrapperSha256Url = .*$': f'  $GradleWrapperSha256Url = "{base_url}/wrapper.sha256"',
    r'^\s*\$GradleWrapperSignatureUrl = .*$': f'  $GradleWrapperSignatureUrl = "{base_url}/wrapper.asc"',
    r'^\s*\$GradleWrapperJarUrl = .*$': f'  $GradleWrapperJarUrl = "{base_url}/gradle-wrapper.jar"',
}
for pattern, replacement in replacements.items():
    text, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(1)
path.write_text(text)
PY
      ;;
    *)
      fail "unknown helper kind '$helper_kind'"
      ;;
  esac
}

assert_launcher_patches() {
  project_dir=$1
  file_has_exact_line "$project_dir/gradlew" '. "${APP_HOME}/gradle/buildish-no-gradle-wrapper-jar.sh"' || fail 'gradlew was not patched with the helper include.'
  file_has_exact_line "$project_dir/gradlew.bat" 'set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=%*' || fail 'gradlew.bat was not patched with the helper block.'
  file_contains_text "$project_dir/gradlew.bat" '%BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS% %*' || fail 'gradlew.bat final Java invocation was not patched.'
}

assert_gitignore_updates() {
  project_dir=$1
  grep -Fqx '# Added by buildish-no-gradle-wrapper-jar' "$project_dir/.gitignore" || fail '.gitignore helper comment was not added.'
  grep -Fqx 'gradle/wrapper/gradle-wrapper-*.sha256' "$project_dir/.gitignore" || fail '.gitignore sha256 ignore was not added.'
  grep -Fqx 'gradle/wrapper/gradle-wrapper-*.asc' "$project_dir/.gitignore" || fail '.gitignore asc ignore was not added.'
}

assert_metadata_for_version() {
  project_dir=$1
  version=$2
  jar_path="$project_dir/gradle/wrapper/gradle-wrapper.jar"
  sha_path="$project_dir/gradle/wrapper/gradle-wrapper-$version.sha256"
  asc_path="$project_dir/gradle/wrapper/gradle-wrapper-$version.asc"
  [ -f "$jar_path" ] || fail "wrapper jar is missing for version '$version'."
  [ -f "$sha_path" ] || fail "wrapper checksum file is missing for version '$version'."
  [ -f "$asc_path" ] || fail "wrapper detached signature is missing for version '$version'."
  expected_checksum=$(tr -d '\r\n' < "$sha_path")
  actual_checksum=$(hash_file "$jar_path")
  [ "$expected_checksum" = "$actual_checksum" ] || fail "wrapper checksum mismatch for version '$version'."
  first_signature_line=$(sed -n '1p' "$asc_path")
  [ "$first_signature_line" = '-----BEGIN PGP SIGNATURE-----' ] || fail "wrapper detached signature file for version '$version' is malformed."
}

run_wrapper() {
  project_dir=$1
  shift
  log "running ./gradlew $* in '$project_dir' (GRADLE_USER_HOME='$(gradle_user_home "$project_dir")')"
  (cd "$project_dir" && GRADLE_USER_HOME=$(gradle_user_home "$project_dir") ./gradlew --no-daemon "$@" >/dev/null)
}

run_wrapper_capture() {
  project_dir=$1
  shift
  output_file=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-test.XXXXXX")
  log "running ./gradlew $* in '$project_dir' (GRADLE_USER_HOME='$(gradle_user_home "$project_dir")')"
  set +e
  (cd "$project_dir" && GRADLE_USER_HOME=$(gradle_user_home "$project_dir") ./gradlew --no-daemon "$@") >"$output_file" 2>&1
  CAPTURED_STATUS=$?
  set -e
  CAPTURED_OUTPUT=$(cat "$output_file")
  rm -f "$output_file"
}

run_gradle_with_init_script_capture() {
  project_dir=$1
  shift
  output_file=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-test.XXXXXX")
  log "running gradle $* with init script in '$project_dir' (GRADLE_USER_HOME='$(gradle_user_home "$project_dir")')"
  set +e
  (cd "$project_dir" && GRADLE_USER_HOME=$(gradle_user_home "$project_dir") gradle -p "$project_dir" --no-daemon --console=plain --init-script "$(gradle_init_script_path "$project_dir")" "$@") >"$output_file" 2>&1
  CAPTURED_STATUS=$?
  set -e
  CAPTURED_OUTPUT=$(cat "$output_file")
  rm -f "$output_file"
}

run_posix_installer_capture() {
  project_dir=$1
  log "installing POSIX helper into '$project_dir'"
  run_and_capture env BUILDISH_NO_GRADLE_WRAPPER_JAR_SOURCE_DIR="$TOOL_DIR" sh "$TOOL_DIR/install.sh" "$project_dir"
}

run_powershell_installer_capture() {
  project_dir=$1
  log "installing PowerShell helper into '$project_dir'"
  run_and_capture env BUILDISH_NO_GRADLE_WRAPPER_JAR_SOURCE_DIR="$TOOL_DIR" pwsh -NoLogo -NoProfile -File "$TOOL_DIR/install.ps1" "$project_dir"
}

run_posix_installer_capture_with_base_url() {
  project_dir=$1
  base_url=$2
  log "installing POSIX helper into '$project_dir' from '$base_url'"
  run_and_capture env BUILDISH_NO_GRADLE_WRAPPER_JAR_BASE_URL="$base_url" sh "$TOOL_DIR/install.sh" "$project_dir"
}

run_powershell_installer_capture_with_base_url() {
  project_dir=$1
  base_url=$2
  log "installing PowerShell helper into '$project_dir' from '$base_url'"
  run_and_capture env BUILDISH_NO_GRADLE_WRAPPER_JAR_BASE_URL="$base_url" pwsh -NoLogo -NoProfile -File "$TOOL_DIR/install.ps1" "$project_dir"
}

run_posix_helper_direct() {
  project_dir=$1
  helper_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.sh"
  log "running POSIX helper directly in '$project_dir'"
  run_and_capture env APP_HOME="$project_dir" sh -c 'helper_path=$1; set --; . "$helper_path"' sh "$helper_path"
}

run_posix_helper_direct_capture_args() {
  project_dir=$1
  shift
  helper_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.sh"
  log "running POSIX helper directly in '$project_dir' with args: $*"
  run_and_capture env APP_HOME="$project_dir" sh -c 'helper_path=$1; shift; set -- "$@"; . "$helper_path"; for arg do printf "%s\n" "$arg"; done' sh "$helper_path" "$@"
}

run_powershell_helper_direct() {
  project_dir=$1
  original_args=${2:-}
  helper_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.ps1"
  log "running PowerShell helper directly in '$project_dir'"
  run_and_capture env APP_HOME="$project_dir" BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS="$original_args" pwsh -NoLogo -NoProfile -File "$helper_path"
}

assert_installer_distribution_sha_warning_output() {
  context_label=$1
  assert_last_output_contains 'does not define distributionSha256Sum' "$context_label did not emit the missing distributionSha256Sum installer warning."
}

assert_init_distribution_sha_warning_output() {
  context_label=$1
  assert_last_output_contains 'Buildish helper warning:' "$context_label did not emit the Buildish warning banner for missing distributionSha256Sum."
  assert_last_output_contains 'distributionSha256Sum' "$context_label did not mention distributionSha256Sum in its warning output."
}

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
  stop_static_http_server

  assert_last_command_failed "$helper_kind helper unexpectedly accepted an oversized $download_kind download."
  assert_last_output_contains 'maximum allowed size' "$helper_kind helper failure output did not mention the maximum allowed size for the oversized $download_kind download."
  [ ! -e "$target_path" ] || fail "$helper_kind helper should not publish an oversized $download_kind file into '$target_path'."
}

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

exercise_installer_missing_properties_failure() {
  project_dir=$1
  installer_kind=$2

  log "exercising $installer_kind installer missing-properties failure in '$project_dir'"
  gradle_init_fixture "$project_dir"
  rm -f "$project_dir/gradle/wrapper/gradle-wrapper.properties"

  "run_${installer_kind}_installer_capture" "$project_dir"
  assert_last_command_failed "$installer_kind installer unexpectedly succeeded without gradle-wrapper.properties."

  assert_last_output_contains 'Gradle wrapper properties file' "$installer_kind installer failure output did not mention the missing gradle-wrapper.properties file."
  assert_last_output_contains 'was not found' "$installer_kind installer failure output did not mention that gradle-wrapper.properties was missing."
}

exercise_installer_oversized_tool_download_failure() {
  project_dir=$1
  installer_kind=$2
  server_root="$project_dir/installer-download-server"
  oversized_file_name='buildish-no-gradle-wrapper-jar.sh'
  target_path="$project_dir/gradle/$oversized_file_name"

  log "exercising $installer_kind installer oversized bootstrap download failure in '$project_dir'"
  gradle_init_fixture "$project_dir"
  rm -rf "$server_root"
  mkdir -p "$server_root"
  cp "$TOOL_DIR/buildish-no-gradle-wrapper-jar.sh" "$server_root/buildish-no-gradle-wrapper-jar.sh"
  cp "$TOOL_DIR/buildish-no-gradle-wrapper-jar.ps1" "$server_root/buildish-no-gradle-wrapper-jar.ps1"
  cp "$TOOL_DIR/buildish-no-gradle-wrapper-jar.init.gradle.kts" "$server_root/buildish-no-gradle-wrapper-jar.init.gradle.kts"
  write_file_with_size "$server_root/$oversized_file_name" $((INSTALLER_MAX_TOOL_FILE_BYTES + 1)) ''

  start_static_http_server "$server_root"
  "run_${installer_kind}_installer_capture_with_base_url" "$project_dir" "http://127.0.0.1:$TEST_HTTP_SERVER_PORT"
  stop_static_http_server

  assert_last_command_failed "$installer_kind installer unexpectedly accepted an oversized bootstrap helper download."
  assert_last_output_contains 'maximum allowed size' "$installer_kind installer failure output did not mention the maximum allowed size for the oversized bootstrap download."
  [ ! -e "$target_path" ] || fail "$installer_kind installer should not publish an oversized helper file into '$target_path'."
}

exercise_helper_missing_properties_failure() {
  project_dir=$1
  helper_kind=$2

  log "exercising $helper_kind helper missing-properties failure in '$project_dir'"
  rm -f "$project_dir/gradle/wrapper/gradle-wrapper.properties"

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_failed "$helper_kind helper unexpectedly succeeded without gradle-wrapper.properties."
  assert_last_output_contains 'Gradle wrapper properties file' "$helper_kind helper failure output did not mention the missing gradle-wrapper.properties file."
  assert_last_output_contains 'was not' "$helper_kind helper failure output did not mention that gradle-wrapper.properties was missing."
  assert_last_output_contains 'gradle-wrapper.properties' "$helper_kind helper failure output did not mention the missing gradle-wrapper.properties path."
}

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

exercise_helper_two_segment_version_support() {
  project_dir=$1
  helper_kind=$2
  target_version=$3
  properties_path="$project_dir/gradle/wrapper/gradle-wrapper.properties"
  jar_path="$project_dir/gradle/wrapper/gradle-wrapper.jar"

  log "exercising $helper_kind helper two-segment Gradle version support in '$project_dir' for Gradle '$target_version'"
  set_wrapper_property "$properties_path" distributionUrl "https\://services.gradle.org/distributions/gradle-$target_version-bin.zip"
  rm -f "$jar_path" "$project_dir/gradle/wrapper/gradle-wrapper-$target_version.sha256" "$project_dir/gradle/wrapper/gradle-wrapper-$target_version.asc"

  "run_${helper_kind}_helper_direct" "$project_dir"
  assert_last_command_succeeded "$helper_kind helper did not support the two-segment Gradle version '$target_version'."
  assert_metadata_for_version "$project_dir" "$target_version"
}

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

exercise_init_script_warning_suppression() {
  project_dir=$1

  log "exercising init-script distributionSha256Sum warning suppression in '$project_dir'"
  cat >> "$project_dir/build.gradle" <<'EOF'

tasks.named('wrapper') {
  distributionSha256Sum = 'a' * 64
}
EOF

  run_gradle_with_init_script_capture "$project_dir" wrapper
  assert_last_command_succeeded 'Init script unexpectedly failed when distributionSha256Sum was present.'
  assert_last_output_not_contains 'Buildish helper warning:' 'Init script emitted the missing distributionSha256Sum warning even though the checksum was present.'
  assert_launcher_patches "$project_dir"
}

exercise_init_script_idempotence() {
  project_dir=$1
  gradlew_path="$project_dir/gradlew"
  gradlew_bat_path="$project_dir/gradlew.bat"

  log "exercising init-script idempotence in '$project_dir'"
  cat >> "$project_dir/build.gradle" <<'EOF'

tasks.named('wrapper') {
  doLast {
    scriptFile.setText([
      'APP_HOME=$( cd -P "${APP_HOME:-./}" > /dev/null && printf \'%s\\n\' "$PWD" ) || exit',
      '. "${APP_HOME}/gradle/buildish-no-gradle-wrapper-jar.sh"',
    ].join('\n'), 'UTF-8')
    batchScript.setText([
      'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi',
      'set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=%*',
      'set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=',
      'for /f "delims=" %%a in (\'powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%APP_HOME%\\gradle\\buildish-no-gradle-wrapper-jar.ps1"\') do @set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=%%a',
      'set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=',
      'if errorlevel 1 goto fail',
      '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" %BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS% %*',
    ].join('\r\n'), 'UTF-8')
  }
}

gradle.taskGraph.whenReady {
  def wrapperTask = tasks.named('wrapper').get()
  def customAction = wrapperTask.actions.remove(wrapperTask.actions.size() - 1)
  wrapperTask.actions.add(wrapperTask.actions.size() - 1, customAction)
}
EOF

  run_gradle_with_init_script_capture "$project_dir" wrapper
  assert_last_command_succeeded 'Init script unexpectedly duplicated an already patched launcher.'
  assert_file_exact_line_count "$gradlew_path" '. "${APP_HOME}/gradle/buildish-no-gradle-wrapper-jar.sh"' 1 'Init script duplicated the POSIX helper include in an already patched gradlew.'
  assert_file_exact_line_count "$gradlew_bat_path" 'set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=%*' 1 'Init script duplicated the batch helper block in an already patched gradlew.bat.'
  assert_file_exact_line_count "$gradlew_bat_path" '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -jar "%APP_HOME%\gradle\wrapper\gradle-wrapper.jar" %BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS% %*' 1 'Init script duplicated the patched batch Java invocation line.'
}

exercise_init_script_newline_preservation() {
  project_dir=$1
  gradlew_path="$project_dir/gradlew"
  gradlew_bat_path="$project_dir/gradlew.bat"

  log "exercising init-script newline preservation and no-trailing-newline patching in '$project_dir'"
  cat >> "$project_dir/build.gradle" <<'EOF'

tasks.named('wrapper') {
  doLast {
    scriptFile.setText('APP_HOME=$( cd -P "${APP_HOME:-./}" > /dev/null && printf \'%s\\n\' "$PWD" ) || exit', 'UTF-8')
    batchScript.setText([
      'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi',
      '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" %*',
    ].join('\r\n'), 'UTF-8')
  }
}

gradle.taskGraph.whenReady {
  def wrapperTask = tasks.named('wrapper').get()
  def customAction = wrapperTask.actions.remove(wrapperTask.actions.size() - 1)
  wrapperTask.actions.add(wrapperTask.actions.size() - 1, customAction)
}
EOF

  run_gradle_with_init_script_capture "$project_dir" wrapper
  assert_last_command_succeeded 'Init script failed to patch launcher files that lacked a trailing newline.'
  assert_launcher_patches "$project_dir"
  assert_file_newline_shape "$gradlew_path" lf no 'Init script did not preserve LF newline style without adding a trailing newline to gradlew.'
  assert_file_newline_shape "$gradlew_bat_path" crlf no 'Init script did not preserve CRLF newline style without adding a trailing newline to gradlew.bat.'
}

exercise_init_script_gradlew_anchor_failure() {
  project_dir=$1

  log "exercising init-script unsupported gradlew anchor failure in '$project_dir'"
  cat >> "$project_dir/build.gradle" <<'EOF'

tasks.named('wrapper') {
  doLast {
    scriptFile.setText('unsupported-gradlew-anchor', 'UTF-8')
    batchScript.setText([
      'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi',
      '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" %*',
    ].join('\r\n'), 'UTF-8')
  }
}

gradle.taskGraph.whenReady {
  def wrapperTask = tasks.named('wrapper').get()
  def customAction = wrapperTask.actions.remove(wrapperTask.actions.size() - 1)
  wrapperTask.actions.add(wrapperTask.actions.size() - 1, customAction)
}
EOF

  run_gradle_with_init_script_capture "$project_dir" wrapper
  assert_last_command_failed 'Init script unexpectedly accepted an unsupported gradlew anchor.'
  assert_last_output_contains 'Unable to find the expected insertion point in gradlew' 'Init script failure output did not mention the unsupported gradlew anchor.'
}

exercise_init_script_gradlew_bat_replacement_failure() {
  project_dir=$1

  log "exercising init-script unsupported gradlew.bat execute-line failure in '$project_dir'"
  cat >> "$project_dir/build.gradle" <<'EOF'

tasks.named('wrapper') {
  doLast {
    scriptFile.setText('APP_HOME=$( cd -P "${APP_HOME:-./}" > /dev/null && printf \'%s\\n\' "$PWD" ) || exit', 'UTF-8')
    batchScript.setText([
      'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi',
      'unsupported-gradlew-bat-execute-line',
    ].join('\r\n'), 'UTF-8')
  }
}

gradle.taskGraph.whenReady {
  def wrapperTask = tasks.named('wrapper').get()
  def customAction = wrapperTask.actions.remove(wrapperTask.actions.size() - 1)
  wrapperTask.actions.add(wrapperTask.actions.size() - 1, customAction)
}
EOF

  run_gradle_with_init_script_capture "$project_dir" wrapper
  assert_last_command_failed 'Init script unexpectedly accepted an unsupported gradlew.bat execute line.'
  assert_last_output_contains 'Unable to find the expected replacement point in gradlew.bat' 'Init script failure output did not mention the unsupported gradlew.bat execute line.'
}

run_init_script_focused_suite() {
  test_root=$1
  base_project="$test_root/init-script-base"
  scenario_root="$test_root/init-script-focused"

  log "starting focused init-script suite (base_project='$base_project')"
  gradle_init_fixture "$base_project"

  copy_init_script_fixture "$base_project" "$scenario_root/warning-suppression"
  exercise_init_script_warning_suppression "$scenario_root/warning-suppression"

  copy_init_script_fixture "$base_project" "$scenario_root/idempotence"
  exercise_init_script_idempotence "$scenario_root/idempotence"

  copy_init_script_fixture "$base_project" "$scenario_root/newline-preservation"
  exercise_init_script_newline_preservation "$scenario_root/newline-preservation"

  copy_init_script_fixture "$base_project" "$scenario_root/unsupported-gradlew-anchor"
  exercise_init_script_gradlew_anchor_failure "$scenario_root/unsupported-gradlew-anchor"

  copy_init_script_fixture "$base_project" "$scenario_root/unsupported-gradlew-bat-replacement"
  exercise_init_script_gradlew_bat_replacement_failure "$scenario_root/unsupported-gradlew-bat-replacement"
}

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

run_helper_edge_case_suite() {
  test_root=$1
  posix_base_project=$2
  powershell_base_project=$3
  scenario_root="$test_root/helper-edge-cases"
  posix_version=$(extract_gradle_version "$posix_base_project")
  powershell_version=$(extract_gradle_version "$powershell_base_project")

  [ -n "$posix_version" ] || fail 'unable to extract the installed Gradle version for the POSIX helper edge-case suite.'
  [ -n "$powershell_version" ] || fail 'unable to extract the installed Gradle version for the PowerShell helper edge-case suite.'

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

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-missing-properties"
  exercise_helper_missing_properties_failure "$scenario_root/posix-missing-properties" posix

  copy_project_fixture "$posix_base_project" "$scenario_root/posix-missing-distribution-url"
  exercise_helper_missing_distribution_url_failure "$scenario_root/posix-missing-distribution-url" posix

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

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-missing-properties"
  exercise_helper_missing_properties_failure "$scenario_root/powershell-missing-properties" powershell

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-missing-distribution-url"
  exercise_helper_missing_distribution_url_failure "$scenario_root/powershell-missing-distribution-url" powershell

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell-two-segment-version"
  exercise_helper_two_segment_version_support "$scenario_root/powershell-two-segment-version" powershell "$TWO_SEGMENT_GRADLE_VERSION"

  copy_project_fixture "$powershell_base_project" "$scenario_root/powershell helper with spaces"
  exercise_powershell_helper_init_script_output "$scenario_root/powershell helper with spaces"
}

run_default_integration_suite() {
  require_base_commands
  require_command pwsh
  test_root=$(mktemp -d "$BUILD_DIR/integration.XXXXXX")
  trap 'stop_static_http_server; rm -rf "$test_root"' EXIT HUP INT TERM

  log "starting default integration suite (test_root='$test_root')"
  exercise_wrapper_update_to_version "$test_root/posix-installer" '' "$UPDATED_GRADLE_VERSION"
  run_powershell_installer_flow "$test_root/powershell-installer"
  run_helper_edge_case_suite "$test_root" "$test_root/posix-installer" "$test_root/powershell-installer"
  run_init_script_focused_suite "$test_root"
  exercise_installer_oversized_tool_download_failure "$test_root/posix-installer-oversized-bootstrap" posix
  exercise_installer_oversized_tool_download_failure "$test_root/powershell-installer-oversized-bootstrap" powershell
  exercise_installer_missing_properties_failure "$test_root/posix-installer-missing-properties" posix
  exercise_installer_missing_properties_failure "$test_root/powershell-installer-missing-properties" powershell
  log 'all helper-tool integration checks passed.'
}

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

run_version_list_exercise() {
  [ "$#" -gt 0 ] || fail 'version-list requires one or more explicit Gradle versions.'
  mkdir -p "$BUILD_DIR/version-list"

  bootstrap_gradle_version=$1

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