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

# Shared shell helpers for the integration suite. tests/integration.sh sources
# this file before any fixture or scenario file so the rest of the suite can use
# one consistent capture/assertion and process-launch layer.

# Fail fast with a consistent prefix so CI logs clearly attribute the failure to
# this integration suite.
fail() {
  echo "integration-test: $*" >&2
  exit 1
}

# Emit suite progress messages with the same prefix used by failures so normal
# progress and fatal output stay easy to correlate in CI logs.
log() {
  echo "integration-test: $*"
}

# Collapse PowerShell's presentation-only "Line |" render blocks into plain
# text so substring assertions can match the semantic message on every platform.
normalize_output_file_for_assertions() {
  output_file=$1
  python3 - <<'PY' "$output_file"
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_bytes().decode('utf-8', errors='replace')
text = text.replace('\r\n', '\n').replace('\r', '\n')
lines = text.split('\n')
normalized_lines = []
powershell_message_fragments = []
inside_powershell_render_block = False
ansi_escape_pattern = re.compile(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|[@-Z\\-_])')


def strip_terminal_escape_sequences(value: str) -> str:
    return ansi_escape_pattern.sub('', value)


def flush_powershell_message_fragments() -> None:
    global inside_powershell_render_block
    if powershell_message_fragments:
        normalized_lines.append(' '.join(powershell_message_fragments))
        powershell_message_fragments.clear()
    inside_powershell_render_block = False


for line in lines:
    display_line = strip_terminal_escape_sequences(line)

    if display_line.strip() == 'Line |':
        flush_powershell_message_fragments()
        inside_powershell_render_block = True
        continue

    if inside_powershell_render_block:
        if re.match(r'^\s*[0-9]+\s+\|\s', display_line):
            continue

        match = re.match(r'^\s*\|\s?(.*)$', display_line)
        if match is not None:
            fragment = match.group(1).strip()
            if fragment and re.fullmatch(r'~+', fragment) is None:
                powershell_message_fragments.append(fragment)
            continue

        flush_powershell_message_fragments()

    normalized_lines.append(display_line)

flush_powershell_message_fragments()
print('\n'.join(normalized_lines), end='')
PY
}

# Store both the raw process output and the normalized assertion view so tests
# can keep exact-output checks without reintroducing PowerShell-specific hacks.
store_captured_output_from_file() {
  output_file=$1
  CAPTURED_OUTPUT=$(cat "$output_file")
  # Keep a second, assertion-focused view that removes PowerShell's presentation
  # wrapper while leaving Linux/plain output untouched.
  CAPTURED_OUTPUT_NORMALIZED=$(normalize_output_file_for_assertions "$output_file")
}

# Run a command, capture its combined output, and preserve the exit status so
# later assertions can reason about both success/failure and emitted text.
run_and_capture() {
  output_file=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-test.XXXXXX")
  set +e
  "$@" >"$output_file" 2>&1
  CAPTURED_STATUS=$?
  set -e
  store_captured_output_from_file "$output_file"
  rm -f "$output_file"
}

# Assert that the previously captured command succeeded while printing the raw
# output for debugging when the expectation is violated.
assert_last_command_succeeded() {
  [ "$CAPTURED_STATUS" -eq 0 ] || fail "$1 (exit status=$CAPTURED_STATUS, output=$CAPTURED_OUTPUT)"
}

# Assert that the previously captured command failed so negative-path tests can
# express the expected control flow explicitly.
assert_last_command_failed() {
  [ "$CAPTURED_STATUS" -ne 0 ] || fail "$1"
}

# Assert against the normalized output view so PowerShell's formatting layer
# does not force every caller to special-case wrapped stderr.
assert_last_output_contains() {
  expected_text=$1
  failure_message=$2
  printf '%s' "$CAPTURED_OUTPUT_NORMALIZED" | grep -Fq "$expected_text" || fail "$failure_message (normalized-output=$CAPTURED_OUTPUT_NORMALIZED, raw-output=$CAPTURED_OUTPUT)"
}

# Assert that normalized output omits a fragment while still reporting both the
# normalized and raw views when a failure needs investigation.
assert_last_output_not_contains() {
  unexpected_text=$1
  failure_message=$2
  if printf '%s' "$CAPTURED_OUTPUT_NORMALIZED" | grep -Fq "$unexpected_text"; then
    fail "$failure_message (normalized-output=$CAPTURED_OUTPUT_NORMALIZED, raw-output=$CAPTURED_OUTPUT)"
  fi
}

# Assert on the raw output when a test cares about exact quoting or line shape
# rather than semantic substrings.
assert_last_output_equals() {
  expected_text=$1
  failure_message=$2
  [ "$CAPTURED_OUTPUT" = "$expected_text" ] || fail "$failure_message (output=$CAPTURED_OUTPUT)"
}

# Check the stable timeout fragments that should survive platform-specific
# formatting differences in the surrounding error text.
assert_last_output_mentions_timeout() {
  timeout_seconds=$1
  failure_message=$2
  assert_last_output_contains 'timed out' "$failure_message"
  assert_last_output_contains "after $timeout_seconds seconds" "$failure_message"
}

# Count raw output lines exactly for launcher-argument tests where normalization
# would hide the shape the test is intentionally inspecting.
assert_last_output_exact_line_count() {
  expected_line=$1
  expected_count=$2
  failure_message=$3
  CAPTURED_OUTPUT_FOR_PY=$CAPTURED_OUTPUT python3 - <<'PY' "$expected_line" "$expected_count" || fail "$failure_message (output=$CAPTURED_OUTPUT)"
import os
import sys

expected_line = sys.argv[1]
expected_count = int(sys.argv[2])
lines = os.environ['CAPTURED_OUTPUT_FOR_PY'].splitlines()
actual_count = sum(1 for line in lines if line == expected_line)
raise SystemExit(0 if actual_count == expected_count else 1)
PY
}

# Source SDKMAN lazily so the suite can find Gradle in clean CI environments as
# well as in developer shells that already initialized SDKMAN.
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

# Pin the Gradle version used for fixture bootstrap when a scenario needs an
# older launcher shape than the default environment provides.
use_sdkman_gradle_version() {
  version=$1
  source_sdkman_gradle
  command -v sdk >/dev/null 2>&1 || fail 'SDKMAN is required to select the bootstrap Gradle version for the version exercise.'
  set +u
  sdk use gradle "$version" >/dev/null
  set -u
  command -v gradle >/dev/null 2>&1 || fail "gradle is not available on PATH after selecting SDKMAN Gradle version '$version'."
}

# Choose a Java 17 runtime for the version exercise because older Gradle 8.1.x
# fixtures need that floor to bootstrap reliably in CI.
select_sdkman_java_version_for_version_exercise() {
  [ -d "$HOME/.sdkman/candidates/java" ] || fail 'SDKMAN Java candidates directory was not found for the version exercise.'
  java_version=$(find "$HOME/.sdkman/candidates/java" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep '^17\.' | sort -V | tail -n 1)
  [ -n "$java_version" ] || fail 'The version exercise requires an installed SDKMAN Java 17.x runtime to run Gradle 8.1.x safely.'
  printf '%s' "$java_version"
}

# Switch the active Java runtime through SDKMAN so version-list exercises use a
# known-compatible JDK instead of whatever the outer shell selected.
use_sdkman_java_version() {
  version=$1
  source_sdkman_gradle
  command -v sdk >/dev/null 2>&1 || fail 'SDKMAN is required to select the Java runtime for the version exercise.'
  set +u
  sdk use java "$version" >/dev/null
  set -u
  command -v java >/dev/null 2>&1 || fail "java is not available on PATH after selecting SDKMAN Java version '$version'."
}

# Fail early when an external tool is missing so later test failures do not hide
# a simple environment problem.
require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is not available on PATH."
}

# Verify the common toolchain once before starting the expensive integration
# flow and ensure the shared build directory exists.
require_base_commands() {
  source_sdkman_gradle
  require_command gradle
  require_command gpg
  require_command python3
  command -v sha256sum >/dev/null 2>&1 || require_command shasum
  mkdir -p "$BUILD_DIR"
}

# Turn arbitrary labels into filesystem-safe path fragments so per-version logs
# and temp directories stay portable.
sanitize_for_path() {
  printf '%s' "$1" | tr '/:' '__' | tr -c 'A-Za-z0-9._-' '_'
}

# Compute SHA-256 with whichever checksum tool is available so the suite works
# on both GNU/Linux and macOS-style developer environments.
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Read the wrapper version from gradle-wrapper.properties so follow-up checks can
# assert against the exact metadata files a scenario should create.
extract_gradle_version() {
  sed -n 's/^distributionUrl=.*gradle-\([0-9.][0-9.]*\)-[a-z]*\.zip$/\1/p' "$1/gradle/wrapper/gradle-wrapper.properties"
}

# Keep each fixture on its own Gradle user home so caches and daemons cannot
# leak state between scenarios.
gradle_user_home() {
  printf '%s-gradle-user-home' "$1"
}

# Centralize the injected init-script path so launcher and init-script tests do
# not duplicate the repository-specific location.
gradle_init_script_path() {
  printf '%s/gradle/buildish-no-gradle-wrapper-jar.init.gradle.kts' "$1"
}

# Assert that all installed helper artifacts are present before a scenario moves
# on to launcher or wrapper-behavior checks.
assert_helper_files() {
  project_dir=$1
  test -f "$project_dir/gradle/buildish-no-gradle-wrapper-jar.sh" || fail 'missing POSIX helper file.'
  test -f "$project_dir/gradle/buildish-no-gradle-wrapper-jar.ps1" || fail 'missing PowerShell helper file.'
  test -f "$project_dir/gradle/buildish-no-gradle-wrapper-jar.init.gradle.kts" || fail 'missing Gradle init script.'
}

# Assert that a failing installer left no helper artifacts behind so negative
# paths prove they fail closed.
assert_helper_files_absent() {
  project_dir=$1
  [ ! -e "$project_dir/gradle/buildish-no-gradle-wrapper-jar.sh" ] || fail 'unexpected POSIX helper file was installed.'
  [ ! -e "$project_dir/gradle/buildish-no-gradle-wrapper-jar.ps1" ] || fail 'unexpected PowerShell helper file was installed.'
  [ ! -e "$project_dir/gradle/buildish-no-gradle-wrapper-jar.init.gradle.kts" ] || fail 'unexpected Gradle init script was installed.'
}

# Check for an exact line match so launcher patch tests stay insensitive to the
# surrounding file content.
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

# Count exact line occurrences to catch duplicate launcher patches rather than
# just their presence.
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

# Wrap the exact-line-count helper with a failure message tailored to the caller
# so duplicate-patch diagnostics stay readable.
assert_file_exact_line_count() {
  file_path=$1
  expected_line=$2
  expected_count=$3
  failure_message=$4
  file_has_exact_line_count "$file_path" "$expected_line" "$expected_count" || fail "$failure_message"
}

# Check whether a file contains a text fragment while normalizing CRLF so batch
# launcher assertions work the same on every host OS.
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

# Assert newline style and trailing-newline behavior so launcher patching does
# not silently rewrite file shape in edge-case fixtures.
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

# Replace or append a wrapper property so edge-case scenarios can steer helper
# behavior without depending on brittle shell text mangling.
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

# Delete a wrapper property to drive negative-path tests that depend on a value
# being truly absent rather than set to an empty string.
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

# Repoint helper download URLs at the local test server so recovery, timeout,
# and oversized-download scenarios never hit the public network.
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

# Assert the key launcher patch anchors so installer and init-script tests can
# verify behavior without diffing whole launcher files.
assert_launcher_patches() {
  project_dir=$1
  file_has_exact_line "$project_dir/gradlew" '. "${APP_HOME}/gradle/buildish-no-gradle-wrapper-jar.sh"' || fail 'gradlew was not patched with the helper include.'
  file_has_exact_line "$project_dir/gradlew.bat" 'set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=%*' || fail 'gradlew.bat was not patched with the helper block.'
  file_contains_text "$project_dir/gradlew.bat" '%BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS% %*' || fail 'gradlew.bat final Java invocation was not patched.'
}

# Verify that installer flows also update .gitignore, because cached metadata is
# part of the supported workflow and should not become accidental commits.
assert_gitignore_updates() {
  project_dir=$1
  grep -Fqx '# Added by buildish-no-gradle-wrapper-jar' "$project_dir/.gitignore" || fail '.gitignore helper comment was not added.'
  grep -Fqx 'gradle/wrapper/gradle-wrapper-*.sha256' "$project_dir/.gitignore" || fail '.gitignore sha256 ignore was not added.'
  grep -Fqx 'gradle/wrapper/gradle-wrapper-*.asc' "$project_dir/.gitignore" || fail '.gitignore asc ignore was not added.'
}

# Verify that the wrapper JAR and its cached integrity metadata all line up for
# a specific Gradle version after helper recovery or installer runs.
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

# Run the PowerShell helper with a shortened HTTP timeout so the timeout path is
# testable without waiting on production-sized retry windows.
run_powershell_helper_direct_with_timeout() {
  project_dir=$1
  timeout_seconds=$2
  original_args=${3:-}
  helper_path="$project_dir/gradle/buildish-no-gradle-wrapper-jar.ps1"
  log "running PowerShell helper directly in '$project_dir' with timeout ${timeout_seconds}s"
  run_and_capture env APP_HOME="$project_dir" BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS="$original_args" BUILDISH_NO_GRADLE_WRAPPER_JAR_HTTP_TIMEOUT_SECONDS="$timeout_seconds" pwsh -NoLogo -NoProfile -File "$helper_path"
}

# Check the installer warning emitted when the project does not define
# distributionSha256Sum, which remains an intentional but visible gap.
assert_installer_distribution_sha_warning_output() {
  context_label=$1
  assert_last_output_contains 'does not define distributionSha256Sum' "$context_label did not emit the missing distributionSha256Sum installer warning."
}

# Check the init-script warning surface for missing distributionSha256Sum so the
# wrapper-update flow stays explicit about the integrity limitation.
assert_init_distribution_sha_warning_output() {
  context_label=$1
  assert_last_output_contains 'Buildish helper warning:' "$context_label did not emit the Buildish warning banner for missing distributionSha256Sum."
  assert_last_output_contains 'distributionSha256Sum' "$context_label did not mention distributionSha256Sum in its warning output."
}

# Detect whether the current shell already looks like CI so locally safe smoke
# tests do not accidentally run the unsafe-dev happy path inside automation.
current_environment_looks_like_ci() {
  for marker in CI GITHUB_ACTIONS GITLAB_CI JENKINS_URL JENKINS_HOME BUILDKITE TEAMCITY_VERSION CIRCLECI TRAVIS TF_BUILD BITBUCKET_BUILD_NUMBER APPVEYOR DRONE SYSTEM_COLLECTIONURI; do
    eval "value=\${$marker-}"
    case "$marker:$value" in
      CI:''|CI:0|CI:false|CI:FALSE|CI:no|CI:NO) continue ;;
    esac
    if [ -n "$value" ]; then
      return 0
    fi
  done

  return 1
}