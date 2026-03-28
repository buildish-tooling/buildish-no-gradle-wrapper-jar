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

set -euo pipefail

invariant_checker() {
  printf '%s/scripts/check-repository-invariants.py\n' "$BUILDISH_TEST_REPO_ROOT"
}

write_fixture_source() {
  local path=$1 kind=$2
  case $kind in
    posix)
      cat >"$path" <<'EOF'
#!/bin/sh
# Copyright 2026 The Buildish Authors
# Licensed under the Apache License, Version 2.0 (the "License");
set -- --init-script "$APP_HOME/gradle/buildish-wrapper.init.gradle.kts" "$@"
source=https://raw.githubusercontent.com/gradle/gradle/v${version}/gradle/wrapper/gradle-wrapper.jar
EOF
      chmod 755 "$path"
      ;;
    powershell)
      cat >"$path" <<'EOF'
# Copyright 2026 The Buildish Authors
# Licensed under the Apache License, Version 2.0 (the "License");
$RawSourcePrefix = 'https://raw.githubusercontent.com/gradle/gradle/'
$downloadUrl = $RawSourcePrefix + 'v' + $version + '/gradle/wrapper/gradle-wrapper.jar'
EOF
      ;;
    init)
      cat >"$path" <<'EOF'
// Copyright 2026 The Buildish Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// Fixture init source intentionally contains no tested-version table.
EOF
      ;;
    *)
      test_fail "unknown fixture source kind: $kind"
      ;;
  esac
}

create_valid_invariant_repository() {
  local root=$1
  mkdir -p "$root/scripts" "$root/tests/fixtures"
  cp "$BUILDISH_TEST_REPO_ROOT/.gitattributes" "$root/.gitattributes"
  cp "$(invariant_checker)" "$root/scripts/check-repository-invariants.py"
  cp "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/launcher-contract.py" \
    "$root/tests/fixtures/launcher-contract.py"
  cp "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/compatibility-manifest.json" \
    "$root/tests/fixtures/compatibility-manifest.json"
  cp -Rp "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/launchers" \
    "$root/tests/fixtures/launchers"
  if [[ -f $BUILDISH_TEST_REPO_ROOT/tests/fixtures/renovate/config.json ]]; then
    mkdir -p "$root/tests/fixtures/renovate"
    cp "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/renovate/config.json" \
      "$root/tests/fixtures/renovate/config.json"
  fi
  write_fixture_source "$root/buildish-wrapper-bootstrap.sh" posix
  write_fixture_source "$root/buildish-wrapper-bootstrap.ps1" powershell
  write_fixture_source "$root/buildish-wrapper.init.gradle.kts" init
  git -C "$root" init -q
  git -C "$root" add .
}

patch_fixture_launchers() {
  local consumer=$1
  python3 - "$consumer/gradlew" "$consumer/gradlew.bat" <<'PY'
from pathlib import Path
import sys

posix = Path(sys.argv[1])
windows = Path(sys.argv[2])

posix_anchor = 'APP_HOME=$( cd -P "${APP_HOME:-./}" > /dev/null && printf \'%s\\n\' "$PWD" ) || exit'
posix_block = (
    '\n\n# BEGIN BUILDISH WRAPPER BOOTSTRAP\n'
    '. "$APP_HOME/gradle/buildish-wrapper-bootstrap.sh" || exit $?\n'
    '# END BUILDISH WRAPPER BOOTSTRAP'
)
text = posix.read_text(encoding="utf-8")
if text.count(posix_anchor) != 1:
    raise SystemExit("fixture POSIX anchor count changed")
posix.write_text(text.replace(posix_anchor, posix_anchor + posix_block), encoding="utf-8", newline="\n")

windows_anchor = 'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi'
windows_block = (
    '\r\n\r\n@rem BEGIN BUILDISH WRAPPER BOOTSTRAP\r\n'
    'if exist "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" goto buildishWrapperReady\r\n'
    'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass '
    '-File "%APP_HOME%\\gradle\\buildish-wrapper-bootstrap.ps1"\r\n'
    'if errorlevel 1 exit /b %ERRORLEVEL%\r\n'
    ':buildishWrapperReady\r\n'
    '@rem END BUILDISH WRAPPER BOOTSTRAP'
)
data = windows.read_bytes()
text = data.decode("utf-8")
if text.count(windows_anchor) != 1:
    raise SystemExit("fixture Windows anchor count changed")
text = text.replace(windows_anchor, windows_anchor + windows_block)
lines = text.splitlines(keepends=True)
matches = [
    index for index, line in enumerate(lines)
    if "%JAVA_EXE%" in line and "\\gradle\\wrapper\\gradle-wrapper.jar" in line and "%*" in line
]
if len(matches) != 1:
    raise SystemExit("fixture Windows Java anchor count changed")
index = matches[0]
lines[index] = lines[index].replace(
    " %*", ' --init-script "%APP_HOME%\\gradle\\buildish-wrapper.init.gradle.kts" %*', 1
)
windows.write_bytes("".join(lines).encode("utf-8"))
PY
}

create_valid_invariant_consumer() {
  local root=$1 fixture_repo=$2
  mkdir -p "$root/gradle/wrapper"
  printf '*.bat -text\n' >"$root/.gitattributes"
  cp -p "$fixture_repo/tests/fixtures/launchers/8.14.5/gradlew" "$root/gradlew"
  cp -p "$fixture_repo/tests/fixtures/launchers/8.14.5/gradlew.bat" "$root/gradlew.bat"
  cp "$fixture_repo/buildish-wrapper-bootstrap.sh" "$root/gradle/"
  cp "$fixture_repo/buildish-wrapper-bootstrap.ps1" "$root/gradle/"
  cp "$fixture_repo/buildish-wrapper.init.gradle.kts" "$root/gradle/"
  patch_fixture_launchers "$root"
  cat >"$root/gradle/wrapper/gradle-wrapper.properties" <<'EOF'
distributionUrl=https\://services.gradle.org/distributions/gradle-8.14.5-bin.zip
distributionSha256Sum=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854
buildishWrapperJarVersion=8.14.5
buildishWrapperJarSha256Sum=7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172
EOF
  cat >"$root/.gitignore" <<'EOF'
/gradle/wrapper/gradle-wrapper.jar
/.gradlew-buildish-update-*.bat
EOF
  cat >"$root/.gitattributes" <<'EOF'
/gradlew text eol=lf
/gradlew.bat -text
/gradle/buildish-wrapper-bootstrap.sh text eol=lf
/gradle/buildish-wrapper-bootstrap.ps1 text eol=lf
/gradle/buildish-wrapper.init.gradle.kts text eol=lf
EOF
  git -C "$root" init -q
  git -C "$root" add .
}

copy_invariant_case() {
  local source=$1 destination=$2
  cp -a "$source" "$destination"
  register_cleanup_path "$destination"
}

expect_invariant_diagnostic() {
  local label=$1 mode=$2 root=$3 expected=$4
  expect_failure "$label" 20 python3 "$(invariant_checker)" "$mode" "$root"
  assert_contains "$BUILDISH_TEST_LAST_STDERR" "$expected" "$label diagnostic"
}

run_invariants_suite() {
  BUILDISH_TEST_CASE=invariants
  require_command python3
  require_command git
  require_command timeout

  local base_repo=$BUILDISH_TEST_ROOT/invariant-valid-repository
  local base_consumer=$BUILDISH_TEST_ROOT/invariant-valid-consumer
  mkdir -p "$base_repo" "$base_consumer"
  register_cleanup_path "$base_repo"
  register_cleanup_path "$base_consumer"
  create_valid_invariant_repository "$base_repo"
  create_valid_invariant_consumer "$base_consumer" "$base_repo"

  expect_success invariant-valid-manifest 20 \
    python3 "$base_repo/scripts/check-repository-invariants.py" --manifest
  expect_success invariant-valid-repository 20 \
    python3 "$(invariant_checker)" --repository "$base_repo"
  expect_success invariant-valid-consumer 20 \
    python3 "$(invariant_checker)" --consumer "$base_consumer"

  local posix_consumer=$BUILDISH_TEST_ROOT/invariant-posix-only-consumer
  copy_invariant_case "$base_consumer" "$posix_consumer"
  rm "$posix_consumer/gradlew.bat" \
    "$posix_consumer/gradle/buildish-wrapper-bootstrap.ps1"
  expect_success invariant-posix-only-consumer 20 \
    python3 "$(invariant_checker)" --consumer "$posix_consumer"

  local windows_consumer=$BUILDISH_TEST_ROOT/invariant-windows-only-consumer
  copy_invariant_case "$base_consumer" "$windows_consumer"
  rm "$windows_consumer/gradlew" \
    "$windows_consumer/gradle/buildish-wrapper-bootstrap.sh"
  expect_success invariant-windows-only-consumer 20 \
    python3 "$(invariant_checker)" --consumer "$windows_consumer"

  git -C "$base_consumer" -c user.name=Buildish \
    -c user.email=buildish@example.invalid commit -q -m 'Invariant checkout fixture'
  local autocrlf_checkout=$BUILDISH_TEST_ROOT/invariant-autocrlf-checkout
  register_cleanup_path "$autocrlf_checkout"
  git -c core.autocrlf=true clone -q --no-local "$base_consumer" "$autocrlf_checkout"
  python3 - "$base_consumer" "$autocrlf_checkout" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
checkout = Path(sys.argv[2])
lf_paths = (
    "gradlew",
    "gradle/buildish-wrapper-bootstrap.sh",
    "gradle/buildish-wrapper-bootstrap.ps1",
    "gradle/buildish-wrapper.init.gradle.kts",
)
for relative in lf_paths:
    data = (checkout / relative).read_bytes()
    if b"\r" in data:
        raise SystemExit(f"autocrlf checkout changed canonical LF bytes: {relative}")
batch = "gradlew.bat"
if (checkout / batch).read_bytes() != (source / batch).read_bytes():
    raise SystemExit("autocrlf checkout changed canonical batch bytes")
PY

  local case_root

  case_root=$BUILDISH_TEST_ROOT/invariant-malformed-matrix-reference
  copy_invariant_case "$base_repo" "$case_root"
  python3 - "$case_root/tests/fixtures/compatibility-manifest.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["transitions"][0]["bootstrapVersion"] = []
path.write_text(json.dumps(manifest), encoding="utf-8", newline="\n")
PY
  expect_invariant_diagnostic malformed-matrix-reference --repository "$case_root" \
    'must reference a tested Wrapper version'

  case_root=$BUILDISH_TEST_ROOT/invariant-tracked-jar
  copy_invariant_case "$base_consumer" "$case_root"
  printf 'not a real JAR\n' >"$case_root/gradle/wrapper/gradle-wrapper.jar"
  git -C "$case_root" add -f gradle/wrapper/gradle-wrapper.jar
  expect_invariant_diagnostic tracked-jar --consumer "$case_root" \
    'invariant-check: gradle/wrapper/gradle-wrapper.jar: ignored Wrapper JAR must not be tracked'

  case_root=$BUILDISH_TEST_ROOT/invariant-missing-source
  copy_invariant_case "$base_repo" "$case_root"
  rm "$case_root/buildish-wrapper-bootstrap.sh"
  expect_invariant_diagnostic missing-canonical-source --repository "$case_root" \
    'invariant-check: buildish-wrapper-bootstrap.sh: required file is missing'

  case_root=$BUILDISH_TEST_ROOT/invariant-missing-source-attribute
  copy_invariant_case "$base_repo" "$case_root"
  sed -i '\|^/buildish-wrapper-bootstrap\.sh text eol=lf$|d' "$case_root/.gitattributes"
  expect_invariant_diagnostic missing-source-attribute --repository "$case_root" \
    "invariant-check: .gitattributes: expected one canonical checkout rule '/buildish-wrapper-bootstrap.sh text eol=lf', found 0"

  case_root=$BUILDISH_TEST_ROOT/invariant-overridden-source-attribute
  copy_invariant_case "$base_repo" "$case_root"
  printf '*.sh text eol=crlf\n' >>"$case_root/.gitattributes"
  expect_invariant_diagnostic overridden-source-attribute --repository "$case_root" \
    "effective eol for 'buildish-wrapper-bootstrap.sh' must be 'lf', found 'crlf'"

  case_root=$BUILDISH_TEST_ROOT/invariant-missing-marker
  copy_invariant_case "$base_consumer" "$case_root"
  sed -i '/^# BEGIN BUILDISH WRAPPER BOOTSTRAP$/d' "$case_root/gradlew"
  expect_invariant_diagnostic missing-marker --consumer "$case_root" \
    "expected one line '# BEGIN BUILDISH WRAPPER BOOTSTRAP', found 0"

  case_root=$BUILDISH_TEST_ROOT/invariant-duplicate-marker
  copy_invariant_case "$base_consumer" "$case_root"
  printf '# BEGIN BUILDISH WRAPPER BOOTSTRAP\n' >>"$case_root/gradlew"
  expect_invariant_diagnostic duplicate-marker --consumer "$case_root" \
    "expected one line '# BEGIN BUILDISH WRAPPER BOOTSTRAP', found 2"

  case_root=$BUILDISH_TEST_ROOT/invariant-missing-property
  copy_invariant_case "$base_consumer" "$case_root"
  sed -i '/^buildishWrapperJarSha256Sum=/d' \
    "$case_root/gradle/wrapper/gradle-wrapper.properties"
  expect_invariant_diagnostic missing-property --consumer "$case_root" \
    'expected one canonical buildishWrapperJarSha256Sum, found 0'

  case_root=$BUILDISH_TEST_ROOT/invariant-duplicate-property
  copy_invariant_case "$base_consumer" "$case_root"
  printf 'buildishWrapperJarVersion=8.14.5\n' >> \
    "$case_root/gradle/wrapper/gradle-wrapper.properties"
  expect_invariant_diagnostic duplicate-property --consumer "$case_root" \
    'expected one canonical buildishWrapperJarVersion, found 2'

  case_root=$BUILDISH_TEST_ROOT/invariant-noncanonical-property
  copy_invariant_case "$base_consumer" "$case_root"
  sed -i \
    's/^buildishWrapperJarVersion=.*/buildishWrapperJarVersion : 8.14.5/' \
    "$case_root/gradle/wrapper/gradle-wrapper.properties"
  expect_invariant_diagnostic noncanonical-property --consumer "$case_root" \
    'found 1 noncanonical buildishWrapperJarVersion definition(s)'

  case_root=$BUILDISH_TEST_ROOT/invariant-continued-property
  copy_invariant_case "$base_consumer" "$case_root"
  python3 - "$case_root/gradle/wrapper/gradle-wrapper.properties" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="iso-8859-1")
text = text.replace(
    "buildishWrapperJarVersion=8.14.5\n",
    "buildishWrapperJarVer\\\nsion=8.14.5\n",
)
path.write_text(text, encoding="iso-8859-1", newline="\n")
PY
  expect_invariant_diagnostic continued-property --consumer "$case_root" \
    'found 1 noncanonical buildishWrapperJarVersion definition(s)'

  case_root=$BUILDISH_TEST_ROOT/invariant-escaped-property
  copy_invariant_case "$base_consumer" "$case_root"
  sed -i \
    's/^buildishWrapperJarVersion=/buildishWrapperJarVersio\\u006e=/' \
    "$case_root/gradle/wrapper/gradle-wrapper.properties"
  expect_invariant_diagnostic escaped-property --consumer "$case_root" \
    'found 1 noncanonical buildishWrapperJarVersion definition(s)'

  local escaped_key escaped_value
  while IFS=$'\t' read -r escaped_key escaped_value; do
    case_root=$BUILDISH_TEST_ROOT/invariant-ordinary-escaped-$escaped_key
    copy_invariant_case "$base_consumer" "$case_root"
    printf '\\%s=%s\n' "$escaped_key" "$escaped_value" >> \
      "$case_root/gradle/wrapper/gradle-wrapper.properties"
    expect_invariant_diagnostic "ordinary-escaped-$escaped_key" \
      --consumer "$case_root" \
      "found 1 noncanonical $escaped_key definition(s)"
  done <<'EOF'
buildishWrapperJarVersion	8.14.5
buildishWrapperJarSha256Sum	7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172
distributionUrl	https\://services.gradle.org/distributions/gradle-8.14.5-bin.zip
distributionSha256Sum	6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854
EOF

  case_root=$BUILDISH_TEST_ROOT/invariant-non-matrix-pair
  copy_invariant_case "$base_consumer" "$case_root"
  sed -i \
    -e 's/^buildishWrapperJarVersion=.*/buildishWrapperJarVersion=7.8.9/' \
    -e 's/^buildishWrapperJarSha256Sum=.*/buildishWrapperJarSha256Sum=1111111111111111111111111111111111111111111111111111111111111111/' \
    -e 's|^distributionUrl=.*|distributionUrl=https\\://services.gradle.org/distributions/gradle-6.7.8-bin.zip|' \
    -e 's/^distributionSha256Sum=.*/distributionSha256Sum=2222222222222222222222222222222222222222222222222222222222222222/' \
    "$case_root/gradle/wrapper/gradle-wrapper.properties"
  expect_success non-matrix-pair 20 python3 "$(invariant_checker)" --consumer "$case_root"

  case_root=$BUILDISH_TEST_ROOT/invariant-leading-zero-version
  copy_invariant_case "$base_consumer" "$case_root"
  sed -i 's/^buildishWrapperJarVersion=.*/buildishWrapperJarVersion=08.14.5/' \
    "$case_root/gradle/wrapper/gradle-wrapper.properties"
  expect_invariant_diagnostic leading-zero-version --consumer "$case_root" \
    'expected one canonical buildishWrapperJarVersion, found 0'

  case_root=$BUILDISH_TEST_ROOT/invariant-bad-ignore
  copy_invariant_case "$base_consumer" "$case_root"
  sed -i 's|^/gradle/wrapper/gradle-wrapper.jar$|gradle/wrapper/gradle-wrapper.jar|' \
    "$case_root/.gitignore"
  expect_invariant_diagnostic bad-ignore-scope --consumer "$case_root" \
    "expected one exact root-scoped rule '/gradle/wrapper/gradle-wrapper.jar', found 0"

  case_root=$BUILDISH_TEST_ROOT/invariant-missing-consumer-attribute
  copy_invariant_case "$base_consumer" "$case_root"
  sed -i '\|^/gradlew text eol=lf$|d' "$case_root/.gitattributes"
  expect_invariant_diagnostic missing-consumer-attribute --consumer "$case_root" \
    "expected one canonical checkout rule '/gradlew text eol=lf', found 0"

  case_root=$BUILDISH_TEST_ROOT/invariant-overridden-consumer-attribute
  copy_invariant_case "$base_consumer" "$case_root"
  printf '*.sh text eol=crlf\n' >>"$case_root/.gitattributes"
  expect_invariant_diagnostic overridden-consumer-attribute --consumer "$case_root" \
    "effective eol for 'gradle/buildish-wrapper-bootstrap.sh' must be 'lf', found 'crlf'"

  case_root=$BUILDISH_TEST_ROOT/invariant-direct-launcher
  copy_invariant_case "$base_consumer" "$case_root"
  cp -p "$base_repo/tests/fixtures/launchers/8.14.5/gradlew" "$case_root/gradlew"
  expect_invariant_diagnostic direct-launcher-replacement --consumer "$case_root" \
    'POSIX bootstrap block is not immediately after APP_HOME resolution'

  case_root=$BUILDISH_TEST_ROOT/invariant-stale-reference
  copy_invariant_case "$base_repo" "$case_root"
  printf 'obsolete bootstrap-install.sh reference\n' >"$case_root/active-notes.txt"
  git -C "$case_root" add active-notes.txt
  expect_invariant_diagnostic stale-removed-basename --repository "$case_root" \
    'invariant-check: active-notes.txt: contains removed active reference: bootstrap-install.sh'

  case_root=$BUILDISH_TEST_ROOT/invariant-unknown-manifest-key
  copy_invariant_case "$base_repo" "$case_root"
  python3 - "$case_root/tests/fixtures/compatibility-manifest.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["unexpected"] = True
path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
PY
  expect_invariant_diagnostic unknown-manifest-key --repository "$case_root" \
    'invariant-check: /unexpected: unexpected key'

  case_root=$BUILDISH_TEST_ROOT/invariant-traversal
  copy_invariant_case "$base_repo" "$case_root"
  python3 - "$case_root/tests/fixtures/compatibility-manifest.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["wrapperVersions"][0]["launchers"]["posix"]["path"] = "../outside/gradlew"
path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
PY
  expect_invariant_diagnostic fixture-path-traversal --repository "$case_root" \
    'path must be normalized and repository-relative'

  case_root=$BUILDISH_TEST_ROOT/invariant-symlink-escape
  copy_invariant_case "$base_repo" "$case_root"
  local escaped_fixture=$BUILDISH_TEST_ROOT/invariant-escaped-launcher-fixture
  mv "$case_root/tests/fixtures/launchers/8.14.5" "$escaped_fixture"
  register_cleanup_path "$escaped_fixture"
  ln -s "$escaped_fixture" "$case_root/tests/fixtures/launchers/8.14.5"
  expect_invariant_diagnostic fixture-symlink-escape --repository "$case_root" \
    'path escapes the repository root'

  test_log 'invariant self-tests passed'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  BUILDISH_TEST_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  BUILDISH_TEST_BUILD_ROOT=$BUILDISH_TEST_REPO_ROOT/build
  mkdir -p "$BUILDISH_TEST_BUILD_ROOT/tests"
  BUILDISH_TEST_ROOT=$(mktemp -d "$BUILDISH_TEST_BUILD_ROOT/tests/invariants.XXXXXX")
  # shellcheck source=../lib/integration-common.sh
  source "$BUILDISH_TEST_REPO_ROOT/tests/lib/integration-common.sh"
  register_cleanup_path "$BUILDISH_TEST_ROOT"
  trap cleanup_registered_resources EXIT HUP INT TERM
  run_invariants_suite
fi
