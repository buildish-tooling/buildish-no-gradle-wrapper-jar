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

# Runtime contract:
# - gradlew sources this file after resolving APP_HOME;
# - every invocation receives the project-local init script argument;
# - an existing Wrapper JAR is trusted and selects the tool-free warm path; and
# - a cold invocation accepts only canonical committed configuration, derives a
#   fixed upstream URL, bounds the response, and publishes only matching bytes.
#
# The helper is sourced rather than executed, so it must preserve the launcher's
# shell state except for the intentional positional-argument insertion.
set -- --init-script "$APP_HOME/gradle/buildish-wrapper.init.gradle.kts" "$@"

# Existing local state is trusted. In particular, the warm path must not start
# network or checksum tools.
if [ -f "$APP_HOME/gradle/wrapper/gradle-wrapper.jar" ]; then
  return 0
fi

# Keep cold-path state, traps, and option changes out of the calling launcher.
(
  buildish_wrapper_bootstrap_properties=$APP_HOME/gradle/wrapper/gradle-wrapper.properties
  buildish_wrapper_bootstrap_jar=$APP_HOME/gradle/wrapper/gradle-wrapper.jar
  buildish_wrapper_bootstrap_temp=

  buildish_wrapper_bootstrap_fail() {
    printf 'buildish wrapper bootstrap: %s\n' "$*" >&2
    exit 1
  }

  trap '
    buildish_wrapper_bootstrap_status=$?
    trap - 0 HUP INT TERM
    if [ -n "$buildish_wrapper_bootstrap_temp" ]; then
      rm -f "$buildish_wrapper_bootstrap_temp"
    fi
    exit "$buildish_wrapper_bootstrap_status"
  ' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  [ -f "$buildish_wrapper_bootstrap_properties" ] ||
    buildish_wrapper_bootstrap_fail "missing properties file: $buildish_wrapper_bootstrap_properties"

  # Parse only the two Buildish-owned physical property forms. Java properties
  # aliases, continuation syntax, duplicates, and ambiguous definitions fail
  # before curl or a checksum tool can run.
  buildish_wrapper_bootstrap_version=
  buildish_wrapper_bootstrap_digest=
  buildish_wrapper_bootstrap_version_count=0
  buildish_wrapper_bootstrap_digest_count=0
  buildish_wrapper_bootstrap_noncanonical=0
  buildish_wrapper_bootstrap_cr=$(printf '\r')
  buildish_wrapper_bootstrap_tab=$(printf '\t')
  buildish_wrapper_bootstrap_form_feed=$(printf '\f')
  while IFS= read -r buildish_wrapper_bootstrap_line ||
    [ -n "$buildish_wrapper_bootstrap_line" ]; do
    case $buildish_wrapper_bootstrap_line in
      *"$buildish_wrapper_bootstrap_cr")
        buildish_wrapper_bootstrap_line=${buildish_wrapper_bootstrap_line%"$buildish_wrapper_bootstrap_cr"}
        ;;
    esac
    case $buildish_wrapper_bootstrap_line in
      buildishWrapperJarVersion=*)
        buildish_wrapper_bootstrap_version_count=$((buildish_wrapper_bootstrap_version_count + 1))
        buildish_wrapper_bootstrap_version=${buildish_wrapper_bootstrap_line#buildishWrapperJarVersion=}
        ;;
      buildishWrapperJarSha256Sum=*)
        buildish_wrapper_bootstrap_digest_count=$((buildish_wrapper_bootstrap_digest_count + 1))
        buildish_wrapper_bootstrap_digest=${buildish_wrapper_bootstrap_line#buildishWrapperJarSha256Sum=}
        ;;
      *)
        buildish_wrapper_bootstrap_candidate=$buildish_wrapper_bootstrap_line
        while :; do
          case $buildish_wrapper_bootstrap_candidate in
            ' '* | "$buildish_wrapper_bootstrap_tab"* | "$buildish_wrapper_bootstrap_form_feed"*)
              buildish_wrapper_bootstrap_candidate=${buildish_wrapper_bootstrap_candidate#?}
              ;;
            *) break ;;
          esac
        done
        case $buildish_wrapper_bootstrap_candidate in
          \#* | \!*) ;;
          buildishWrapperJarVersion | buildishWrapperJarVersion:* | \
            buildishWrapperJarVersion\\* | 'buildishWrapperJarVersion '* | \
            "buildishWrapperJarVersion$buildish_wrapper_bootstrap_tab"* | \
            "buildishWrapperJarVersion$buildish_wrapper_bootstrap_form_feed"* | \
            buildishWrapperJarSha256Sum | buildishWrapperJarSha256Sum:* | \
            buildishWrapperJarSha256Sum\\* | 'buildishWrapperJarSha256Sum '* | \
            "buildishWrapperJarSha256Sum$buildish_wrapper_bootstrap_tab"* | \
            "buildishWrapperJarSha256Sum$buildish_wrapper_bootstrap_form_feed"*)
            buildish_wrapper_bootstrap_noncanonical=$((buildish_wrapper_bootstrap_noncanonical + 1))
            ;;
        esac
        ;;
    esac
  done <"$buildish_wrapper_bootstrap_properties"

  if [ "$buildish_wrapper_bootstrap_version_count" -ne 1 ] ||
    [ "$buildish_wrapper_bootstrap_digest_count" -ne 1 ] ||
    [ "$buildish_wrapper_bootstrap_noncanonical" -ne 0 ]; then
    buildish_wrapper_bootstrap_fail \
      'expected exactly one canonical Wrapper JAR version and digest'
  fi

  case $buildish_wrapper_bootstrap_version in
    '' | .* | *. | *..* | *[!0-9.]*)
      buildish_wrapper_bootstrap_fail \
        'Wrapper JAR version must be a canonical three-component stable version'
      ;;
  esac
  buildish_wrapper_bootstrap_old_ifs=$IFS
  IFS=.
  set -- $buildish_wrapper_bootstrap_version
  IFS=$buildish_wrapper_bootstrap_old_ifs
  [ "$#" -eq 3 ] ||
    buildish_wrapper_bootstrap_fail \
      'Wrapper JAR version must be a canonical three-component stable version'
  for buildish_wrapper_bootstrap_component do
    case $buildish_wrapper_bootstrap_component in
      0 | [1-9] | [1-9][0-9]*) ;;
      *)
        buildish_wrapper_bootstrap_fail \
          'Wrapper JAR version must be a canonical three-component stable version'
        ;;
    esac
  done
  case $buildish_wrapper_bootstrap_digest in
    *[!0-9a-f]*)
      buildish_wrapper_bootstrap_fail \
        'Wrapper JAR digest must be 64 lowercase hexadecimal characters'
      ;;
  esac
  [ "${#buildish_wrapper_bootstrap_digest}" -eq 64 ] ||
    buildish_wrapper_bootstrap_fail \
      'Wrapper JAR digest must be 64 lowercase hexadecimal characters'

  buildish_wrapper_bootstrap_source=https://raw.githubusercontent.com/gradle/gradle/v${buildish_wrapper_bootstrap_version}/gradle/wrapper/gradle-wrapper.jar

  command -v curl >/dev/null 2>&1 ||
    buildish_wrapper_bootstrap_fail 'curl is required for a cold start'
  if command -v sha256sum >/dev/null 2>&1; then
    set -- sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    set -- shasum -a 256
  else
    buildish_wrapper_bootstrap_fail 'sha256sum or shasum is required for a cold start'
  fi

  umask 077
  # Create the sibling temporary without following or replacing an existing
  # path. Publication occurs only after the complete response passes SHA-256.
  buildish_wrapper_bootstrap_attempt=0
  while [ "$buildish_wrapper_bootstrap_attempt" -lt 100 ]; do
    buildish_wrapper_bootstrap_temp=$buildish_wrapper_bootstrap_jar.tmp.$$.$buildish_wrapper_bootstrap_attempt
    if (set -C; : >"$buildish_wrapper_bootstrap_temp") 2>/dev/null; then
      break
    fi
    buildish_wrapper_bootstrap_temp=
    buildish_wrapper_bootstrap_attempt=$((buildish_wrapper_bootstrap_attempt + 1))
  done
  [ -n "$buildish_wrapper_bootstrap_temp" ] ||
    buildish_wrapper_bootstrap_fail \
      "cannot create a unique temporary file beside $buildish_wrapper_bootstrap_jar"

  if ! curl --fail --location --silent --show-error \
    --connect-timeout 5 --max-time 15 --max-filesize 10485760 \
    --output "$buildish_wrapper_bootstrap_temp" "$buildish_wrapper_bootstrap_source"; then
    buildish_wrapper_bootstrap_fail 'Wrapper JAR download failed'
  fi

  if ! buildish_wrapper_bootstrap_size=$(wc -c <"$buildish_wrapper_bootstrap_temp"); then
    buildish_wrapper_bootstrap_fail 'cannot determine downloaded Wrapper JAR size'
  fi
  case $buildish_wrapper_bootstrap_size in
    '' | *[!0-9]*)
      buildish_wrapper_bootstrap_fail 'downloaded Wrapper JAR size is invalid'
      ;;
  esac
  if [ "$buildish_wrapper_bootstrap_size" -gt 10485760 ]; then
    buildish_wrapper_bootstrap_fail 'downloaded Wrapper JAR exceeds 10 MiB'
  fi

  if ! buildish_wrapper_bootstrap_hash_output=$("$@" "$buildish_wrapper_bootstrap_temp"); then
    buildish_wrapper_bootstrap_fail 'cannot hash the downloaded Wrapper JAR'
  fi
  buildish_wrapper_bootstrap_actual_digest=${buildish_wrapper_bootstrap_hash_output%% *}
  if [ "$buildish_wrapper_bootstrap_actual_digest" != "$buildish_wrapper_bootstrap_digest" ]; then
    buildish_wrapper_bootstrap_fail \
      "downloaded Wrapper JAR digest mismatch: expected $buildish_wrapper_bootstrap_digest, found $buildish_wrapper_bootstrap_actual_digest"
  fi

  if ! mv -f "$buildish_wrapper_bootstrap_temp" "$buildish_wrapper_bootstrap_jar"; then
    buildish_wrapper_bootstrap_fail 'cannot publish the verified Wrapper JAR'
  fi
  buildish_wrapper_bootstrap_temp=
)
