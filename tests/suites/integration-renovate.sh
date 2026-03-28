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

run_renovate_suite() {
  BUILDISH_TEST_CASE=renovate
  require_canonical_sources
  require_command git
  require_command node
  require_command npm
  require_command python3
  require_command timeout

  local consumer=$BUILDISH_TEST_ROOT/renovate-consumer
  local work_consumer=${consumer}.renovate-work
  local renovate_cache=${consumer}.renovate-cache
  local gradle_user_home=$BUILDISH_TEST_ROOT/renovate-gradle-home
  local gradle_bin wrapper_jar target_sha result_json
  mkdir -p "$consumer" "$gradle_user_home"
  register_cleanup_path "$consumer"
  register_cleanup_path "$work_consumer"
  register_cleanup_path "$renovate_cache"
  register_cleanup_path "$gradle_user_home"
  create_consumer "$consumer" 8.14.5 8.14.5

  gradle_bin=$(provision_gradle 8.14.5)
  target_sha=$(manifest_entry_value targetDistributions 8.14.5 sha256)
  expect_success renovate-adoption 240 env GRADLE_USER_HOME="$gradle_user_home" \
    "$gradle_bin" --no-daemon \
    --init-script "$consumer/gradle/buildish-wrapper.init.gradle.kts" \
    --rerun-tasks -p "$consumer" :wrapper \
    --gradle-version 8.14.5 --distribution-type bin \
    --gradle-distribution-sha256-sum "$target_sha"

  wrapper_jar=$consumer/gradle/wrapper/gradle-wrapper.jar
  assert_file_exists "$wrapper_jar"
  expect_success renovate-precondition-invariants 20 \
    python3 "$BUILDISH_TEST_REPO_ROOT/scripts/check-repository-invariants.py" \
      --consumer "$consumer"

  git -C "$consumer" init -q -b main
  git -C "$consumer" config core.autocrlf false
  git -C "$consumer" add .
  git -C "$consumer" -c user.name=Buildish -c user.email=buildish@example.invalid \
    commit -q -m 'Renovate fixture baseline'
  if git -C "$consumer" ls-files --error-unmatch gradle/wrapper/gradle-wrapper.jar \
      >/dev/null 2>&1; then
    test_fail 'ignored Wrapper JAR was tracked in the Renovate source fixture'
  fi

  mkdir -p "$BUILDISH_TEST_BUILD_ROOT/npm-cache"
  expect_success renovate-artifact-update 600 \
    env npm_config_cache="$BUILDISH_TEST_BUILD_ROOT/npm-cache" \
    npm exec --yes --package=renovate@44.7.0 -- \
      node "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/renovate/run-artifact-update.mjs" \
      "$consumer"
  result_json=$BUILDISH_TEST_LAST_STDOUT
  python3 - "$result_json" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
expected = ["gradle/wrapper/gradle-wrapper.properties", "gradlew", "gradlew.bat"]
if result != {"artifacts": expected, "errors": []}:
    raise SystemExit(f"unexpected Renovate artifact result: {result!r}")
PY

  expect_success renovate-result-invariants 20 \
    python3 "$BUILDISH_TEST_REPO_ROOT/scripts/check-repository-invariants.py" \
      --consumer "$work_consumer"
  if git -C "$work_consumer" ls-files --error-unmatch \
      gradle/wrapper/gradle-wrapper.jar >/dev/null 2>&1; then
    test_fail 'ignored Wrapper JAR was returned or tracked by Renovate'
  fi

  cp -p "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/launchers/9.6.1/gradlew" \
    "$work_consumer/gradlew"
  cp -p "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/launchers/9.6.1/gradlew.bat" \
    "$work_consumer/gradlew.bat"
  expect_failure renovate-direct-replacement-control 20 \
    python3 "$BUILDISH_TEST_REPO_ROOT/scripts/check-repository-invariants.py" \
      --consumer "$work_consumer"
  assert_contains "$BUILDISH_TEST_LAST_STDERR" \
    'bootstrap block is not immediately after APP_HOME resolution' \
    'direct launcher replacement control'

  test_log 'Renovate artifact-update contract passed'
}
