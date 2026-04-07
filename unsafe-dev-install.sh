#!/bin/sh
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

BUILDISH_UNSAFE_DEV_TOOL_NAME='buildish-no-gradle-wrapper-jar unsafe-dev-install'
BUILDISH_UNSAFE_DEV_DEFAULT_BASE_URL='https://raw.githubusercontent.com/apache/buildish/main/tools/buildish-no-gradle-wrapper-jar'
BUILDISH_UNSAFE_DEV_BASE_URL=${BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL:-$BUILDISH_UNSAFE_DEV_DEFAULT_BASE_URL}
BUILDISH_UNSAFE_DEV_ACKNOWLEDGED=0

buildish_unsafe_dev_fail() {
  echo "$BUILDISH_UNSAFE_DEV_TOOL_NAME: $*" >&2
  exit 1
}

buildish_unsafe_dev_warn() {
  echo "$BUILDISH_UNSAFE_DEV_TOOL_NAME: WARNING: $*" >&2
}

buildish_unsafe_dev_require_command() {
  command -v "$1" >/dev/null 2>&1 || buildish_unsafe_dev_fail "Required command '$1' was not found on PATH."
}

buildish_unsafe_dev_detect_ci_marker() {
  for marker in CI GITHUB_ACTIONS GITLAB_CI JENKINS_URL JENKINS_HOME BUILDKITE TEAMCITY_VERSION CIRCLECI TRAVIS TF_BUILD BITBUCKET_BUILD_NUMBER APPVEYOR DRONE SYSTEM_COLLECTIONURI; do
    eval "value=\${$marker-}"
    case "$marker:$value" in
      CI:''|CI:0|CI:false|CI:FALSE|CI:no|CI:NO) continue ;;
    esac
    if [ -n "$value" ]; then
      printf '%s' "$marker"
      return 0
    fi
  done

  return 1
}

buildish_unsafe_dev_download_to() {
  target_path=$1
  file_name=$2

  if ! curl --fail --location --silent --show-error --output "$target_path" "$BUILDISH_UNSAFE_DEV_BASE_URL/$file_name"; then
    rm -f "$target_path"
    buildish_unsafe_dev_fail "Unable to download '$file_name' from '$BUILDISH_UNSAFE_DEV_BASE_URL/$file_name'."
  fi
}

# The only acceptable reason to run this script is explicit, conscious trust in
# the current development branch contents. Make that acknowledgment mandatory.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes-i-know-this-is-unsafe)
      BUILDISH_UNSAFE_DEV_ACKNOWLEDGED=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      buildish_unsafe_dev_fail "Unknown option '$1'."
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -le 1 ] || buildish_unsafe_dev_fail 'Expected zero or one positional argument: the target project directory.'
TARGET_DIR=${1:-.}

[ "$BUILDISH_UNSAFE_DEV_ACKNOWLEDGED" -eq 1 ] ||
  buildish_unsafe_dev_fail "Refusing to run without --yes-i-know-this-is-unsafe. This script downloads and executes unverified content from the current development branch and is not suitable for CI, automation, or secret-bearing environments."

CI_MARKER=$(buildish_unsafe_dev_detect_ci_marker || true)
[ -z "$CI_MARKER" ] ||
  buildish_unsafe_dev_fail "Refusing to run because the CI marker '$CI_MARKER' is set. This script is not suitable for CI environments, automation, or secret-bearing environments."

buildish_unsafe_dev_warn 'This script downloads and executes unverified content from the current development branch.'
buildish_unsafe_dev_warn 'Use it only when you intentionally trust the current branch contents.'
buildish_unsafe_dev_warn 'It is not suitable for CI, automation, or environments with secrets.'

buildish_unsafe_dev_require_command curl
buildish_unsafe_dev_require_command mktemp
buildish_unsafe_dev_require_command sh

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-unsafe-dev-install.XXXXXX") ||
  buildish_unsafe_dev_fail 'Unable to create a temporary directory for the downloaded installer payloads.'
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

for file_name in install.sh buildish-no-gradle-wrapper-jar.sh buildish-no-gradle-wrapper-jar.ps1 buildish-no-gradle-wrapper-jar.init.gradle.kts; do
  buildish_unsafe_dev_download_to "$TEMP_DIR/$file_name" "$file_name"
done

sh "$TEMP_DIR/install.sh" --trusted-source-dir "$TEMP_DIR" "$TARGET_DIR"