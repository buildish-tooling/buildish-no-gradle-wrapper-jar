#!/bin/sh
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

set -eu

TOOL='buildish-no-gradle-wrapper-jar unsafe-dev-install'
DEFAULT_BASE_URL='https://raw.githubusercontent.com/buildish-tooling/buildish/main/tools/buildish-no-gradle-wrapper-jar'
BASE_URL=${BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL:-$DEFAULT_BASE_URL}
FILES='install.sh buildish-no-gradle-wrapper-jar.sh buildish-no-gradle-wrapper-jar.ps1 buildish-no-gradle-wrapper-jar.init.gradle.kts'

die() {
  echo "$TOOL: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: unsafe-dev-install.sh --yes-i-know-this-is-unsafe [target-project-directory]

Download and execute unverified helper files from the current development
branch. This shortcut is unsafe and is not suitable for CI or environments
with secrets.

Options:
  --yes-i-know-this-is-unsafe  Required acknowledgement of the execution risk.
  -h, --help                   Show this help and exit without downloading.
EOF
}

ci_marker() {
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

# The only acceptable reason to run this script is explicit, conscious trust in
# the current development branch contents. Make that acknowledgment mandatory.
case ${1:-} in
  -h|--help)
    usage
    exit 0
    ;;
esac

[ "$#" -ge 1 ] ||
  die "Refusing to run without --yes-i-know-this-is-unsafe. This script downloads and executes unverified content from the current development branch and is not suitable for CI, automation, or secret-bearing environments."

[ "$1" = '--yes-i-know-this-is-unsafe' ] ||
  die "Refusing to run without --yes-i-know-this-is-unsafe. This script downloads and executes unverified content from the current development branch and is not suitable for CI, automation, or secret-bearing environments."

case $# in
  1) TARGET_DIR='.' ;;
  2) TARGET_DIR=$2 ;;
  *) die 'Expected the unsafe acknowledgement flag followed by zero or one positional argument: the target project directory.' ;;
esac

CI_MARKER=$(ci_marker || true)
[ -z "$CI_MARKER" ] ||
  die "Refusing to run because the CI marker '$CI_MARKER' is set. This script is not suitable for CI environments, automation, or secret-bearing environments."

echo "$TOOL: WARNING: This script downloads and executes unverified content from the current development branch." >&2
echo "$TOOL: WARNING: Use it only when you intentionally trust the current branch contents." >&2
echo "$TOOL: WARNING: It is not suitable for CI, automation, or environments with secrets." >&2

command -v curl >/dev/null 2>&1 || die "Required command 'curl' was not found on PATH."
command -v mktemp >/dev/null 2>&1 || die "Required command 'mktemp' was not found on PATH."

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-unsafe-dev-install.XXXXXX") ||
  die 'Unable to create a temporary directory for the downloaded installer payloads.'
trap 'rm -rf "$temp_dir"' EXIT HUP INT TERM

for file_name in $FILES; do
  target_path="$temp_dir/$file_name"
  file_url="$BASE_URL/$file_name"
  if ! curl --fail --location --silent --show-error --output "$target_path" "$file_url"; then
    rm -f "$target_path"
    die "Unable to download '$file_name' from '$file_url'."
  fi
done

sh "$temp_dir/install.sh" --trusted-source-dir "$temp_dir" "$TARGET_DIR"
