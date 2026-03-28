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

lifecycle_gradle() {
  case $1 in
    8.14.5) printf '%s\n' "$BUILDISH_LIFECYCLE_GRADLE_8_14_5" ;;
    9.6.1) printf '%s\n' "$BUILDISH_LIFECYCLE_GRADLE_9_6_1" ;;
    *) test_fail "unsupported lifecycle Gradle version: $1" ;;
  esac
}

lifecycle_wrapper_jar() {
  case $1 in
    8.14.5) printf '%s\n' "$BUILDISH_LIFECYCLE_JAR_8_14_5" ;;
    9.6.1) printf '%s\n' "$BUILDISH_LIFECYCLE_JAR_9_6_1" ;;
    *) test_fail "unsupported lifecycle Wrapper version: $1" ;;
  esac
}

stop_lifecycle_gradle_daemons() {
  local gradle
  for gradle in "$BUILDISH_LIFECYCLE_GRADLE_8_14_5" "$BUILDISH_LIFECYCLE_GRADLE_9_6_1"; do
    GRADLE_USER_HOME=$BUILDISH_LIFECYCLE_GRADLE_USER_HOME \
      "$gradle" --stop >/dev/null 2>&1 || true
  done
}

lifecycle_consumer_path() {
  printf '%s/lifecycle-installed-%s-target-%s\n' "$BUILDISH_TEST_ROOT" "$1" "$2"
}

run_installed_wrapper() {
  local label=$1 consumer=$2 installed=$3 target=$4 home=$5
  local gradle target_sha
  gradle=$(lifecycle_gradle "$installed")
  target_sha=$(manifest_entry_value targetDistributions "$target" sha256)
  expect_success "$label" 240 env GRADLE_USER_HOME="$home" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    --rerun-tasks :wrapper --gradle-version "$target" --distribution-type bin \
    --gradle-distribution-sha256-sum "$target_sha"
}

assert_consumer_contract() {
  local label=$1 consumer=$2 bootstrap=$3 target=$4
  local expected actual
  expect_success "$label-launchers" 30 python3 \
    "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/launcher-contract.py" \
    check-consumer --manifest "$BUILDISH_TEST_MANIFEST" "$consumer"
  expect_success "$label-invariants" 30 python3 \
    "$BUILDISH_TEST_REPO_ROOT/scripts/check-repository-invariants.py" \
    --consumer "$consumer"
  expected=$(manifest_entry_value wrapperVersions "$bootstrap" wrapperJarSha256)
  actual=$(sha256_file "$consumer/gradle/wrapper/gradle-wrapper.jar")
  assert_equal "$expected" "$actual" "$label Wrapper JAR digest"
  python3 - "$consumer/gradle/wrapper/gradle-wrapper.properties" \
    "$bootstrap" "$target" "$BUILDISH_TEST_MANIFEST" <<'PY'
import json
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
bootstrap = sys.argv[2]
target = sys.argv[3]
manifest = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
text = path.read_text(encoding="iso-8859-1")
wrapper = next(item for item in manifest["wrapperVersions"] if item["version"] == bootstrap)
distribution = next(item for item in manifest["targetDistributions"] if item["version"] == target)
expected = {
    "buildishWrapperJarVersion": bootstrap,
    "buildishWrapperJarSha256Sum": wrapper["wrapperJarSha256"],
    "distributionUrl": distribution["url"].replace(":", "\\:", 1),
    "distributionSha256Sum": distribution["sha256"],
}

for key, value in expected.items():
    matches = re.findall(rf"(?m)^{re.escape(key)}=([^\r\n]*)$", text)
    if matches != [value]:
        raise SystemExit(f"{path}: expected one {key}={value}, found {matches}")
PY
}

assert_generic_consumer_contract() {
  local label=$1 consumer=$2
  expect_success "$label-launchers" 30 python3 \
    "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/launcher-contract.py" \
    check-consumer --manifest "$BUILDISH_TEST_MANIFEST" "$consumer"
  expect_success "$label-invariants" 30 python3 \
    "$BUILDISH_TEST_REPO_ROOT/scripts/check-repository-invariants.py" \
    --consumer "$consumer"
}

consumer_output_identity() {
  local consumer=$1 path
  for path in \
    "$consumer/gradlew" \
    "$consumer/gradlew.bat" \
    "$consumer/gradle/wrapper/gradle-wrapper.properties"; do
    sha256_file "$path"
  done
}

run_existing_wrapper_adoption_case() {
  local version=$1
  local consumer=$BUILDISH_TEST_ROOT/lifecycle-existing-wrapper-$version
  local jar home
  create_consumer "$consumer" "$version" "$version"
  jar=$(lifecycle_wrapper_jar "$version")
  cp "$jar" "$consumer/gradle/wrapper/gradle-wrapper.jar"
  home=$BUILDISH_LIFECYCLE_GRADLE_USER_HOME
  expect_success "lifecycle-existing-$version" 300 bash -c '
    set -eu
    consumer=$1
    gradle_home=$2
    cd "$consumer"
    GRADLE_USER_HOME=$gradle_home exec ./gradlew --daemon \
      --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
      --rerun-tasks :wrapper
  ' _ "$consumer" "$home"
  assert_consumer_contract "lifecycle-existing-$version" "$consumer" "$version" "$version"
}

run_installed_gradle_adoption_case() {
  local installed=$1 target=$2
  local consumer jar before after
  consumer=$(lifecycle_consumer_path "$installed" "$target")
  create_consumer "$consumer" "$installed" "$target"
  case $installed:$target in
    8.14.5:9.6.1)
      rm "$consumer/gradlew.bat"
      ;;
    9.6.1:9.6.1)
      rm "$consumer/gradlew" "$consumer/gradlew.bat"
      ;;
  esac
  jar=$(lifecycle_wrapper_jar "$installed")
  cp "$jar" "$consumer/gradle/wrapper/gradle-wrapper.jar"
  run_installed_wrapper \
    "lifecycle-installed-$installed-$target" "$consumer" "$installed" "$target" \
    "$BUILDISH_LIFECYCLE_GRADLE_USER_HOME"
  assert_consumer_contract \
    "lifecycle-installed-$installed-$target" "$consumer" "$installed" "$target"

  case $installed:$target in
    8.14.5:9.6.1)
      assert_file_absent "$consumer/gradlew.bat"
      ;;
    9.6.1:9.6.1)
      assert_file_exists "$consumer/gradlew"
      assert_file_exists "$consumer/gradlew.bat"
      ;;
  esac

  if [[ $installed != 9.6.1 || $target != 9.6.1 ]]; then
    return
  fi
  before=$(consumer_output_identity "$consumer")
  run_installed_wrapper \
    "lifecycle-idempotent-$installed-$target" "$consumer" "$installed" "$target" \
    "$BUILDISH_LIFECYCLE_GRADLE_USER_HOME"
  after=$(consumer_output_identity "$consumer")
  assert_equal "$before" "$after" "$installed to $target byte idempotence"
}

run_cold_launcher_case() {
  local bootstrap=$1 target=$2
  local consumer payload expected actual wrapper_home
  consumer=$(lifecycle_consumer_path "$bootstrap" "$target")
  payload=$(lifecycle_wrapper_jar "$bootstrap")
  start_http_fixture "$payload"
  substitute_runtime_url "$consumer/gradle/buildish-wrapper-bootstrap.sh" \
    "http://127.0.0.1:$BUILDISH_TEST_HTTP_PORT/jar?source="
  rm "$consumer/gradle/wrapper/gradle-wrapper.jar"
  wrapper_home=$BUILDISH_LIFECYCLE_GRADLE_USER_HOME
  expect_success "lifecycle-cold-$bootstrap-$target" 180 bash -c '
    set -eu
    consumer=$1
    gradle_home=$2
    cd "$consumer"
    GRADLE_USER_HOME=$gradle_home exec ./gradlew --daemon --version
  ' _ "$consumer" "$wrapper_home"
  assert_contains "$BUILDISH_TEST_LAST_STDOUT" "Gradle $target" \
    "$bootstrap to $target cold launcher version"
  assert_http_route_requested_once "$BUILDISH_TEST_HTTP_LOG" /jar
  expected=$(manifest_entry_value wrapperVersions "$bootstrap" wrapperJarSha256)
  actual=$(sha256_file "$consumer/gradle/wrapper/gradle-wrapper.jar")
  assert_equal "$expected" "$actual" "$bootstrap to $target cold Wrapper JAR digest"
  assert_no_wrapper_temporaries "$consumer/gradle/wrapper"
}

write_lifecycle_mutation() {
  local consumer=$1 mutation=$2
  python3 - "$consumer/build.gradle.kts" "$mutation" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
mutation = sys.argv[2]
mutations = {
    "jar-corrupt": r'''
        jarFile.writeBytes("not a Gradle Wrapper JAR".toByteArray(Charsets.UTF_8))
''',
    "checksum-missing": r'''
        val original = propertiesFile.readText(Charsets.ISO_8859_1)
        propertiesFile.writeText(
            original.lineSequence()
                .filterNot { it.startsWith("distributionSha256Sum=") }
                .joinToString("\n", postfix = "\n"),
            Charsets.ISO_8859_1,
        )
''',
    "anchor-missing": r'''
        val original = scriptFile.readText(Charsets.UTF_8)
        val anchor = "APP_HOME=${'$'}( cd -P \"${'$'}{APP_HOME:-./}\" > /dev/null && printf '%s\\n' \"${'$'}PWD\" ) || exit"
        scriptFile.writeText(original.replace(anchor, "# lifecycle fixture removed APP_HOME anchor"), Charsets.UTF_8)
''',
}
try:
    body = mutations[mutation]
except KeyError:
    raise SystemExit(f"unknown lifecycle mutation: {mutation}")
path.write_text(
    "import org.gradle.api.tasks.wrapper.Wrapper\n\n"
    "tasks.named<Wrapper>(\"wrapper\") {\n"
    "    doLast {\n"
    + body
    + "    }\n"
      "}\n",
    encoding="utf-8",
    newline="\n",
)
PY
}

run_transformation_fixture_case() {
  local consumer=$BUILDISH_TEST_ROOT/lifecycle-transformations
  local combined_init=$consumer/gradle/buildish-transform-check.init.gradle.kts
  local gradle
  create_consumer "$consumer" 9.6.1 9.6.1
  create_consumer "$consumer/transformation-fixtures/8.14.5" 8.14.5 8.14.5
  python3 - \
    "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/init-transform-check.gradle.kts" \
    "$combined_init" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
fixture = Path(sys.argv[2]).read_text(encoding="utf-8")
marker = "gradle.lifecycle.afterProject(BuildishAfterProjectAction())\n"
if source.count(marker) != 1 or not source.endswith(marker):
    raise SystemExit("canonical init script has no unique terminal lifecycle registration")
Path(sys.argv[3]).write_text(
    source.removesuffix(marker) + fixture,
    encoding="utf-8",
    newline="\n",
)
PY
  gradle=$(lifecycle_gradle 9.6.1)
  expect_success lifecycle-transformations 180 env \
    GRADLE_USER_HOME="$BUILDISH_LIFECYCLE_GRADLE_USER_HOME" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$combined_init" buildishTransformationCheck
}

assert_no_buildish_publication() {
  local consumer=$1 executing=$2 posix_mutated=${3:-false} windows_mutated=${4:-false}
  if grep -Fq 'BEGIN BUILDISH WRAPPER BOOTSTRAP' \
      "$consumer/gradlew" "$consumer/gradlew.bat"; then
    test_fail 'Buildish launcher block was published after preparation failure'
  fi
  if grep -Eq '^buildishWrapperJar(Version|Sha256Sum)=' \
      "$consumer/gradle/wrapper/gradle-wrapper.properties"; then
    test_fail 'Buildish Wrapper properties were published after preparation failure'
  fi
  if [[ $posix_mutated == false ]]; then
    cmp -s "$consumer/gradlew" \
      "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/launchers/$executing/gradlew" ||
      test_fail 'POSIX launcher changed before failed Buildish publication'
  fi
  if [[ $windows_mutated == false ]]; then
    cmp -s "$consumer/gradlew.bat" \
      "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/launchers/$executing/gradlew.bat" ||
      test_fail 'Windows launcher changed before failed Buildish publication'
  fi
}

run_preparation_failure_case() {
  local mutation=$1 expected_error=$2 posix_mutated=${3:-false} windows_mutated=${4:-false}
  local consumer=$BUILDISH_TEST_ROOT/lifecycle-negative-$mutation
  local jar gradle target_sha
  create_consumer "$consumer" 9.6.1 9.6.1
  jar=$(lifecycle_wrapper_jar 9.6.1)
  cp "$jar" "$consumer/gradle/wrapper/gradle-wrapper.jar"
  write_lifecycle_mutation "$consumer" "$mutation"
  gradle=$(lifecycle_gradle 9.6.1)
  target_sha=$(manifest_entry_value targetDistributions 9.6.1 sha256)
  expect_failure "lifecycle-negative-$mutation" 180 env \
    GRADLE_USER_HOME="$BUILDISH_LIFECYCLE_GRADLE_USER_HOME" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    --rerun-tasks :wrapper --gradle-version 9.6.1 --distribution-type bin \
    --gradle-distribution-sha256-sum "$target_sha"
  assert_contains "$BUILDISH_TEST_LAST_STDERR" "$expected_error" \
    "$mutation focused failure diagnostic"
  assert_no_buildish_publication "$consumer" 9.6.1 "$posix_mutated" "$windows_mutated"
}

run_generated_jar_digest_recording_case() {
  local consumer=$BUILDISH_TEST_ROOT/lifecycle-generated-jar-digest
  local jar gradle target_sha actual recorded
  create_consumer "$consumer" 9.6.1 9.6.1
  jar=$(lifecycle_wrapper_jar 9.6.1)
  cp "$jar" "$consumer/gradle/wrapper/gradle-wrapper.jar"
  write_lifecycle_mutation "$consumer" jar-corrupt
  gradle=$(lifecycle_gradle 9.6.1)
  target_sha=$(manifest_entry_value targetDistributions 9.6.1 sha256)
  expect_success lifecycle-generated-jar-digest 180 env \
    GRADLE_USER_HOME="$BUILDISH_LIFECYCLE_GRADLE_USER_HOME" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    --rerun-tasks :wrapper --gradle-version 9.6.1 --distribution-type bin \
    --gradle-distribution-sha256-sum "$target_sha"
  actual=$(sha256_file "$consumer/gradle/wrapper/gradle-wrapper.jar")
  recorded=$(sed -n 's/^buildishWrapperJarSha256Sum=//p' \
    "$consumer/gradle/wrapper/gradle-wrapper.properties")
  assert_equal "$actual" "$recorded" 'generated Wrapper JAR digest recording'
  assert_generic_consumer_contract lifecycle-generated-jar-digest "$consumer"
}

run_non_matrix_target_checksum_case() {
  local consumer=$BUILDISH_TEST_ROOT/lifecycle-non-matrix-target-checksum
  local jar gradle count
  create_consumer "$consumer" 8.14.5 8.14.5
  rm "$consumer/gradlew"
  jar=$(lifecycle_wrapper_jar 8.14.5)
  cp "$jar" "$consumer/gradle/wrapper/gradle-wrapper.jar"
  gradle=$(lifecycle_gradle 8.14.5)
  expect_success lifecycle-non-matrix-target-checksum 180 env \
    GRADLE_USER_HOME="$BUILDISH_LIFECYCLE_GRADLE_USER_HOME" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    --rerun-tasks :wrapper --gradle-version 7.8.9 --distribution-type bin \
    --no-validate-url \
    --gradle-distribution-sha256-sum \
    0000000000000000000000000000000000000000000000000000000000000000
  count=$(grep -Fxc \
    'distributionSha256Sum=0000000000000000000000000000000000000000000000000000000000000000' \
    "$consumer/gradle/wrapper/gradle-wrapper.properties")
  assert_equal 1 "$count" 'non-matrix target checksum preservation'
  count=$(grep -Fxc \
    'distributionUrl=https\://services.gradle.org/distributions/gradle-7.8.9-bin.zip' \
    "$consumer/gradle/wrapper/gradle-wrapper.properties")
  assert_equal 1 "$count" 'non-matrix target URL generation'
  assert_file_absent "$consumer/gradlew"
  assert_generic_consumer_contract lifecycle-non-matrix-target-checksum "$consumer"
}

run_custom_output_case() {
  local consumer=$BUILDISH_TEST_ROOT/lifecycle-negative-custom-outputs
  local jar gradle target_sha
  create_consumer "$consumer" 9.6.1 9.6.1
  jar=$(lifecycle_wrapper_jar 9.6.1)
  cp "$jar" "$consumer/gradle/wrapper/gradle-wrapper.jar"
  cat >"$consumer/build.gradle.kts" <<'EOF'
import org.gradle.api.tasks.wrapper.Wrapper

tasks.named<Wrapper>("wrapper") {
    scriptFile = layout.projectDirectory.file("custom/gradlew").asFile
    jarFile = layout.projectDirectory.file("custom/gradle-wrapper.jar").asFile
}
EOF
  gradle=$(lifecycle_gradle 9.6.1)
  target_sha=$(manifest_entry_value targetDistributions 9.6.1 sha256)
  expect_failure lifecycle-negative-custom-outputs 180 env \
    GRADLE_USER_HOME="$BUILDISH_LIFECYCLE_GRADLE_USER_HOME" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    --rerun-tasks :wrapper --gradle-version 9.6.1 --distribution-type bin \
    --gradle-distribution-sha256-sum "$target_sha"
  assert_contains "$BUILDISH_TEST_LAST_STDERR" \
    'POSIX launcher must use the canonical project path' \
    'custom Wrapper output diagnostic'
  assert_no_buildish_publication "$consumer" 9.6.1
  assert_file_exists "$consumer/custom/gradlew"
  assert_file_exists "$consumer/custom/gradlew.bat"
  assert_file_exists "$consumer/custom/gradle-wrapper.properties"
  if grep -Fq 'BEGIN BUILDISH WRAPPER BOOTSTRAP' \
      "$consumer/custom/gradlew" "$consumer/custom/gradlew.bat"; then
    test_fail 'Buildish launcher block was published to custom Wrapper outputs'
  fi
  if grep -Eq '^buildishWrapperJar(Version|Sha256Sum)=' \
      "$consumer/custom/gradle-wrapper.properties"; then
    test_fail 'Buildish Wrapper properties were published to custom outputs'
  fi
}

run_scoping_case() {
  local consumer=$BUILDISH_TEST_ROOT/lifecycle-scoping
  local gradle target_sha
  create_consumer "$consumer" 9.6.1 9.6.1
  mkdir -p "$consumer/included" "$consumer/buildSrc"
  cat >"$consumer/settings.gradle.kts" <<'EOF'
rootProject.name = "lifecycle-scoping"
includeBuild("included")
EOF
  cat >"$consumer/build.gradle.kts" <<'EOF'
import org.gradle.api.tasks.wrapper.Wrapper

tasks.register<Wrapper>("extraWrapper")
EOF
  cat >"$consumer/included/settings.gradle.kts" <<'EOF'
rootProject.name = "lifecycle-included"
EOF
  : >"$consumer/included/build.gradle.kts"
  cat >"$consumer/buildSrc/settings.gradle.kts" <<'EOF'
rootProject.name = "lifecycle-buildsrc"
EOF
  cat >"$consumer/buildSrc/build.gradle.kts" <<'EOF'
import org.gradle.api.tasks.wrapper.Wrapper

plugins {
    `java-library`
}

tasks.named<Wrapper>("wrapper") {
    doLast {
        layout.projectDirectory.file("buildsrc-wrapper-ran.marker").asFile.writeText(path)
    }
}
tasks.named("jar") {
    dependsOn("wrapper")
}
EOF
  gradle=$(lifecycle_gradle 9.6.1)
  target_sha=$(manifest_entry_value targetDistributions 9.6.1 sha256)

  expect_success lifecycle-scope-extra 240 env \
    GRADLE_USER_HOME="$BUILDISH_LIFECYCLE_GRADLE_USER_HOME" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    --rerun-tasks extraWrapper --gradle-version 9.6.1 --distribution-type bin \
    --gradle-distribution-sha256-sum "$target_sha"
  assert_no_buildish_publication "$consumer" 9.6.1
  assert_file_exists "$consumer/buildSrc/buildsrc-wrapper-ran.marker"
  if grep -Fq 'BEGIN BUILDISH WRAPPER BOOTSTRAP' \
      "$consumer/buildSrc/gradlew" "$consumer/buildSrc/gradlew.bat"; then
    test_fail 'buildSrc Wrapper task was incorrectly enhanced'
  fi

  expect_success lifecycle-scope-included 240 env \
    GRADLE_USER_HOME="$BUILDISH_LIFECYCLE_GRADLE_USER_HOME" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    --rerun-tasks :included:wrapper --gradle-version 9.6.1 --distribution-type bin \
    --gradle-distribution-sha256-sum "$target_sha"
  if grep -Fq 'BEGIN BUILDISH WRAPPER BOOTSTRAP' \
      "$consumer/included/gradlew" "$consumer/included/gradlew.bat"; then
    test_fail 'included-build Wrapper task was incorrectly enhanced'
  fi

  expect_success lifecycle-scope-root 240 env \
    GRADLE_USER_HOME="$BUILDISH_LIFECYCLE_GRADLE_USER_HOME" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    --rerun-tasks :wrapper --gradle-version 9.6.1 --distribution-type bin \
    --gradle-distribution-sha256-sum "$target_sha"
  assert_consumer_contract lifecycle-scope-root "$consumer" 9.6.1 9.6.1
}

run_gradle_lifecycle_modes_case() {
  local consumer=$BUILDISH_TEST_ROOT/lifecycle-gradle-modes
  local gradle jar target_sha home before after
  create_consumer "$consumer" 9.6.1 9.6.1
  jar=$(lifecycle_wrapper_jar 9.6.1)
  cp "$jar" "$consumer/gradle/wrapper/gradle-wrapper.jar"
  gradle=$(lifecycle_gradle 9.6.1)
  home=$BUILDISH_LIFECYCLE_GRADLE_USER_HOME

  expect_success lifecycle-configuration-cache-first 180 env GRADLE_USER_HOME="$home" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    help --configuration-cache --configuration-cache-problems=fail
  expect_success lifecycle-configuration-cache-reuse 180 env GRADLE_USER_HOME="$home" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    help --configuration-cache --configuration-cache-problems=fail
  assert_contains "$BUILDISH_TEST_LAST_STDOUT" 'Reusing configuration cache.' \
    'ordinary task configuration-cache reuse'

  target_sha=$(manifest_entry_value targetDistributions 9.6.1 sha256)
  home=$BUILDISH_LIFECYCLE_GRADLE_USER_HOME
  expect_success lifecycle-wrapper-configuration-cache-first 240 env \
    GRADLE_USER_HOME="$home" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    --rerun-tasks :wrapper --gradle-version 9.6.1 --distribution-type bin \
    --gradle-distribution-sha256-sum "$target_sha" --configuration-cache \
    --configuration-cache-problems=fail
  expect_success lifecycle-wrapper-configuration-cache-reuse 240 env \
    GRADLE_USER_HOME="$home" \
    "$gradle" --daemon -p "$consumer" \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    --rerun-tasks :wrapper --gradle-version 9.6.1 --distribution-type bin \
    --gradle-distribution-sha256-sum "$target_sha" --configuration-cache \
    --configuration-cache-problems=fail
  assert_contains "$BUILDISH_TEST_LAST_STDOUT" \
    'Reusing configuration cache.' \
    'enhanced Wrapper task configuration-cache reuse'
  assert_not_contains "$BUILDISH_TEST_LAST_STDOUT$BUILDISH_TEST_LAST_STDERR" \
    'not compatible with the configuration cache' \
    'enhanced Wrapper task configuration-cache compatibility'

  before=$(consumer_output_identity "$consumer")
  expect_success lifecycle-isolated-projects 180 env \
    GRADLE_USER_HOME="$BUILDISH_LIFECYCLE_GRADLE_USER_HOME" \
    "$gradle" --daemon -Dorg.gradle.unsafe.isolated-projects=true \
    -p "$consumer" --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" help
  after=$(consumer_output_identity "$consumer")
  assert_equal "$before" "$after" 'ordinary Isolated Projects execution output identity'
}

run_bare_vs_launcher_case() {
  local consumer=$BUILDISH_TEST_ROOT/lifecycle-bare-vs-launcher
  local gradle target_sha home
  create_consumer "$consumer" 8.14.5 8.14.5
  gradle=$(lifecycle_gradle 8.14.5)
  target_sha=$(manifest_entry_value targetDistributions 8.14.5 sha256)
  home=$BUILDISH_LIFECYCLE_GRADLE_USER_HOME

  expect_success lifecycle-bare-gradle-wrapper 180 env GRADLE_USER_HOME="$home" \
    "$gradle" --daemon -p "$consumer" --rerun-tasks :wrapper \
    --gradle-version 8.14.5 --distribution-type bin \
    --gradle-distribution-sha256-sum "$target_sha"
  assert_no_buildish_publication "$consumer" 8.14.5

  run_installed_wrapper lifecycle-explicit-adoption "$consumer" 8.14.5 8.14.5 "$home"
  assert_consumer_contract lifecycle-explicit-adoption "$consumer" 8.14.5 8.14.5

  expect_success lifecycle-launcher-driven-wrapper 240 bash -c '
    set -eu
    consumer=$1
    gradle_home=$2
    cd "$consumer"
    GRADLE_USER_HOME=$gradle_home exec ./gradlew --daemon --rerun-tasks :wrapper
  ' _ "$consumer" "$home"
  assert_consumer_contract lifecycle-launcher-driven-wrapper "$consumer" 8.14.5 8.14.5
}

run_checksum_cache_observations() {
  local populated=$BUILDISH_TEST_ROOT/lifecycle-existing-wrapper-8.14.5
  local archive consumer jar
  python3 - "$populated/gradle/wrapper/gradle-wrapper.properties" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="iso-8859-1")
text, count = re.subn(
    r"(?m)^distributionSha256Sum=[0-9a-f]{64}$",
    "distributionSha256Sum=" + "0" * 64,
    text,
)
if count != 1:
    raise SystemExit(f"populated-cache mutation expected one checksum, found {count}")
path.write_text(text, encoding="iso-8859-1", newline="")
PY
  expect_success lifecycle-populated-cache-trust-observation 120 bash -c '
    set -eu
    consumer=$1
    gradle_home=$2
    cd "$consumer"
    GRADLE_USER_HOME=$gradle_home exec ./gradlew --daemon --version
  ' _ "$populated" "$BUILDISH_LIFECYCLE_GRADLE_USER_HOME"
  assert_contains "$BUILDISH_TEST_LAST_STDOUT" 'Gradle 8.14.5' \
    'populated Wrapper cache trust observation'

  consumer=$BUILDISH_TEST_ROOT/lifecycle-empty-cache-checksum
  create_consumer "$consumer" 8.14.5 8.14.5
  jar=$(lifecycle_wrapper_jar 8.14.5)
  cp "$jar" "$consumer/gradle/wrapper/gradle-wrapper.jar"
  archive=$BUILDISH_TEST_BUILD_ROOT/test-tools/gradle-8.14.5-bin.zip
  assert_file_exists "$archive"
  python3 - "$consumer/gradle/wrapper/gradle-wrapper.properties" "$archive" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="iso-8859-1")
url = Path(sys.argv[2]).resolve().as_uri().replace(":", "\\:", 1)
text, url_count = re.subn(r"(?m)^distributionUrl=.*$", "distributionUrl=" + url, text)
text, digest_count = re.subn(
    r"(?m)^distributionSha256Sum=[0-9a-f]{64}$",
    "distributionSha256Sum=" + "0" * 64,
    text,
)
if (url_count, digest_count) != (1, 1):
    raise SystemExit(f"empty-cache mutation counts: URL={url_count}, digest={digest_count}")
path.write_text(text, encoding="iso-8859-1", newline="")
PY
  expect_failure lifecycle-empty-cache-checksum 180 bash -c '
    set -eu
    consumer=$1
    gradle_home=$2
    cd "$consumer"
    GRADLE_USER_HOME=$gradle_home exec ./gradlew --daemon --version
  ' _ "$consumer" "$BUILDISH_TEST_ROOT/gradle-home-empty-cache-checksum"
  assert_contains "$BUILDISH_TEST_LAST_STDERR" \
    'Verification of Gradle distribution failed' 'empty-cache checksum mismatch diagnostic'
}

run_lifecycle_suite() {
  BUILDISH_TEST_CASE='lifecycle canonical sources'
  require_canonical_sources
  [[ -f $BUILDISH_TEST_REPO_ROOT/tests/fixtures/launcher-contract.py ]] ||
    test_fail 'missing replacement test artifact: tests/fixtures/launcher-contract.py'
  require_command cmp
  require_command curl
  require_command python3
  require_command timeout

  BUILDISH_LIFECYCLE_GRADLE_8_14_5=$(provision_gradle 8.14.5)
  BUILDISH_LIFECYCLE_GRADLE_9_6_1=$(provision_gradle 9.6.1)
  BUILDISH_LIFECYCLE_JAR_8_14_5=$(provision_wrapper_jar 8.14.5)
  BUILDISH_LIFECYCLE_JAR_9_6_1=$(provision_wrapper_jar 9.6.1)
  BUILDISH_LIFECYCLE_GRADLE_USER_HOME=$BUILDISH_TEST_BUILD_ROOT/test-tools/lifecycle-gradle-user-home
  export BUILDISH_LIFECYCLE_GRADLE_USER_HOME
  register_cleanup_function stop_lifecycle_gradle_daemons

  BUILDISH_TEST_CASE='existing Wrapper adoption matrix'
  run_existing_wrapper_adoption_case 8.14.5
  run_existing_wrapper_adoption_case 9.6.1

  BUILDISH_TEST_CASE='installed Gradle transition and idempotence matrix'
  local bootstrap target
  while IFS=$'\t' read -r bootstrap target; do
    run_installed_gradle_adoption_case "$bootstrap" "$target"
  done < <(python3 - "$BUILDISH_TEST_MANIFEST" <<'PY'
import json
import sys
for case in json.load(open(sys.argv[1], encoding="utf-8"))["installedGradleCases"]:
    print(case["installedVersion"], case["targetVersion"], sep="\t")
PY
  )

  BUILDISH_TEST_CASE='cold bootstrap-to-wrapper execution matrix'
  while IFS=$'\t' read -r bootstrap target; do
    run_cold_launcher_case "$bootstrap" "$target"
  done < <(python3 - "$BUILDISH_TEST_MANIFEST" <<'PY'
import json
import sys
for case in json.load(open(sys.argv[1], encoding="utf-8"))["transitions"]:
    if case["bootstrapVersion"] != case["targetVersion"]:
        print(case["bootstrapVersion"], case["targetVersion"], sep="\t")
PY
  )

  BUILDISH_TEST_CASE='init-script preparation failures'
  run_transformation_fixture_case
  run_preparation_failure_case checksum-missing \
    'exactly one distributionSha256Sum definition; found 0'
  run_preparation_failure_case anchor-missing \
    'exactly one POSIX APP_HOME insertion anchor, found 0' true
  run_non_matrix_target_checksum_case
  run_custom_output_case
  run_generated_jar_digest_recording_case

  BUILDISH_TEST_CASE='top-level Wrapper scoping'
  run_scoping_case

  BUILDISH_TEST_CASE='Gradle lifecycle modes'
  run_gradle_lifecycle_modes_case

  BUILDISH_TEST_CASE='bare installed Gradle versus launcher-driven wrapper'
  run_bare_vs_launcher_case

  BUILDISH_TEST_CASE='Gradle Wrapper checksum cache observations'
  run_checksum_cache_observations
}
