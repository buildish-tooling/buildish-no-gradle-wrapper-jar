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
  project_checksum=$(sed -n 's/^buildishWrapperJarSha256Sum=//p' "$project_dir/gradle/wrapper/gradle-wrapper.properties")
  actual_checksum=$(hash_file "$jar_path")
  [ "$project_checksum" = "$expected_checksum" ] || fail "project wrapper JAR pin mismatch for version '$version'."
  [ "$expected_checksum" = "$actual_checksum" ] || fail "wrapper checksum mismatch for version '$version'."
  first_signature_line=$(sed -n '1p' "$asc_path")
  [ "$first_signature_line" = '-----BEGIN PGP SIGNATURE-----' ] || fail "wrapper detached signature file for version '$version' is malformed."
}
