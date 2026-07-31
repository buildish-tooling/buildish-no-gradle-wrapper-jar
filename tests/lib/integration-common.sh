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

# Assert against the separately captured stderr view without weakening the
# exact stdout protocol checks performed by the caller.
assert_last_stderr_contains() {
  expected_text=$1
  failure_message=$2
  printf '%s' "$CAPTURED_STDERR_NORMALIZED" | grep -Fq "$expected_text" ||
    fail "$failure_message (normalized-stderr=$CAPTURED_STDERR_NORMALIZED, raw-stderr=$CAPTURED_STDERR)"
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

# Initialize SDKMAN only for explicit historical-version exercises. Ordinary
# checks honor the caller's PATH and never execute user startup logic.
source_sdkman_environment() {
  if command -v sdk >/dev/null 2>&1; then
    return 0
  fi
  [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] || fail 'SDKMAN init script was not found for the requested version exercise.'
  set +u
  . "$HOME/.sdkman/bin/sdkman-init.sh"
  set -u
  command -v sdk >/dev/null 2>&1 || fail 'SDKMAN is not available after sourcing its init script.'
}

# Pin the Gradle version used for fixture bootstrap when a scenario needs an
# older launcher shape than the default environment provides.
use_sdkman_gradle_version() {
  version=$1
  source_sdkman_environment
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
  source_sdkman_environment
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
  require_command gradle
  require_command git
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

# Fetch the official Wrapper JAR checksum for a test-selected Gradle version.
# Production code does not use this helper: committed project pins remain a
# reviewed configuration input rather than an automatically trusted response.
fetch_gradle_wrapper_checksum() {
  gradle_version=$1
  checksum=$(curl --fail --location --silent --show-error \
    "https://services.gradle.org/distributions/gradle-$gradle_version-wrapper.jar.sha256" | tr -d '\r\n') ||
    fail "unable to fetch the Gradle $gradle_version Wrapper JAR checksum for integration setup."
  printf '%s' "$checksum" | grep -E '^[0-9a-f]{64}$' >/dev/null 2>&1 ||
    fail "Gradle $gradle_version returned a malformed Wrapper JAR checksum during integration setup."
  printf '%s\n' "$checksum"
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
