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

# Tiny secure bootstrap verifier for the no-gradle-wrapper-jar installer.
#
# Important: the repository copy is a release template. A release step must render
# the hard-coded base URL and pinned signing-key material before users execute it.
# That keeps the final published script static and reviewable without reintroducing
# runtime remote-override knobs.

set -eu

BUILDISH_BOOTSTRAP_INSTALL_TOOL_NAME='buildish-no-gradle-wrapper-jar bootstrap-install'
BUILDISH_BOOTSTRAP_INSTALL_BASE_URL='__BUILDISH_BOOTSTRAP_INSTALL_BASE_URL__'
BUILDISH_BOOTSTRAP_INSTALL_MANIFEST_NAME='bootstrap-install-posix.sha256'
BUILDISH_BOOTSTRAP_INSTALL_SIGNATURE_NAME='bootstrap-install-posix.sha256.asc'
BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_FINGERPRINT='__BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_FINGERPRINT__'
BUILDISH_BOOTSTRAP_INSTALL_MAX_METADATA_BYTES=65536
BUILDISH_BOOTSTRAP_INSTALL_MAX_PAYLOAD_BYTES=262144
BUILDISH_BOOTSTRAP_INSTALL_EXPECTED_FILES='install.sh buildish-no-gradle-wrapper-jar.sh buildish-no-gradle-wrapper-jar.ps1 buildish-no-gradle-wrapper-jar.init.gradle.kts'

buildish_bootstrap_install_fail() {
  echo "${BUILDISH_BOOTSTRAP_INSTALL_TOOL_NAME}: $*" >&2
  exit 1
}

buildish_bootstrap_install_require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    buildish_bootstrap_install_fail "Required command '$1' was not found on PATH."
}

buildish_bootstrap_install_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print tolower($1); exit }'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print tolower($1); exit }'
    return 0
  fi
  buildish_bootstrap_install_fail "Neither 'sha256sum' nor 'shasum' is available for checksum verification."
}

buildish_bootstrap_install_download_to_path() {
  target_path=$1
  download_url=$2
  label=$3

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --output "$target_path" "$download_url" ||
      buildish_bootstrap_install_fail "Unable to download $label from '$download_url'."
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$target_path" "$download_url" ||
      buildish_bootstrap_install_fail "Unable to download $label from '$download_url'."
    return 0
  fi

  buildish_bootstrap_install_fail "Either 'curl' or 'wget' is required to download $label."
}

buildish_bootstrap_install_assert_max_size() {
  path=$1
  max_bytes=$2
  label=$3
  actual_size=$(wc -c < "$path" | tr -d '[:space:]')
  [ "$actual_size" -le "$max_bytes" ] ||
    buildish_bootstrap_install_fail "$label exceeded the maximum allowed size of ${max_bytes} bytes."
}

buildish_bootstrap_install_trusted_public_key() {
  cat <<'EOF'
__BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_PUBLIC_KEY__
EOF
}

buildish_bootstrap_install_assert_rendered() {
  case "$BUILDISH_BOOTSTRAP_INSTALL_BASE_URL $BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_FINGERPRINT $(buildish_bootstrap_install_trusted_public_key)" in
    *'__BUILDISH_BOOTSTRAP_'*)
      buildish_bootstrap_install_fail 'This repository copy is an unrendered release template. Use a release-rendered bootstrap-install.sh or the reviewed local-copy/manual-verification flow.'
      ;;
  esac
}

buildish_bootstrap_install_verify_manifest_signature() {
  manifest_path=$1
  signature_path=$2
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/buildish-bootstrap-install-gpg.XXXXXX") ||
    buildish_bootstrap_install_fail 'Unable to create a temporary GnuPG home.'
  gpg_home="$temp_dir/home"
  trusted_key_path="$temp_dir/trusted-key.asc"

  mkdir "$gpg_home" || {
    rm -rf "$temp_dir"
    buildish_bootstrap_install_fail 'Unable to create the temporary GnuPG home directory.'
  }

  buildish_bootstrap_install_trusted_public_key > "$trusted_key_path"

  fingerprint_output=$(LC_ALL=C LANG=C gpg --homedir "$gpg_home" --batch --no-options --show-keys --with-colons --fingerprint "$trusted_key_path" 2>&1) || {
    rm -rf "$temp_dir"
    buildish_bootstrap_install_fail "Unable to inspect the pinned release signing key: ${fingerprint_output}"
  }

  actual_fingerprint=$(printf '%s\n' "$fingerprint_output" | awk -F: '$1 == "fpr" { print tolower($10); exit }')
  [ "$actual_fingerprint" = "$BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_FINGERPRINT" ] || {
    rm -rf "$temp_dir"
    buildish_bootstrap_install_fail 'Pinned release signing key fingerprint mismatch.'
  }

  import_output=$(LC_ALL=C LANG=C gpg --homedir "$gpg_home" --batch --no-options --import "$trusted_key_path" 2>&1) || {
    rm -rf "$temp_dir"
    buildish_bootstrap_install_fail "Unable to import the pinned release signing key: ${import_output}"
  }

  verify_output=$(LC_ALL=C LANG=C gpg --homedir "$gpg_home" --batch --no-options --no-auto-key-retrieve --verify "$signature_path" "$manifest_path" 2>&1) || {
    rm -rf "$temp_dir"
    buildish_bootstrap_install_fail "Detached signature verification failed for the payload manifest: ${verify_output}"
  }

  rm -rf "$temp_dir"
}

buildish_bootstrap_install_manifest_checksum_for_file() {
  manifest_path=$1
  expected_file_name=$2
  matching_checksum=''
  matching_count=0

  while IFS= read -r manifest_line || [ -n "$manifest_line" ]; do
    [ -n "$manifest_line" ] || continue
    set -- $manifest_line
    [ "$#" -eq 2 ] || buildish_bootstrap_install_fail "Verified payload manifest line was malformed: '$manifest_line'."
    checksum=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    file_name=$2

    printf '%s' "$checksum" | grep -Eq '^[0-9a-f]{64}$' ||
      buildish_bootstrap_install_fail "Verified payload manifest contained an invalid SHA-256 for '$file_name'."

    case " $BUILDISH_BOOTSTRAP_INSTALL_EXPECTED_FILES " in
      *" $file_name "*) ;;
      *) buildish_bootstrap_install_fail "Verified payload manifest contained an unexpected file '$file_name'." ;;
    esac

    if [ "$file_name" = "$expected_file_name" ]; then
      matching_checksum=$checksum
      matching_count=$((matching_count + 1))
    fi
  done < "$manifest_path"

  [ "$matching_count" -eq 1 ] ||
    buildish_bootstrap_install_fail "Verified payload manifest did not contain exactly one checksum entry for '$expected_file_name'."
  printf '%s' "$matching_checksum"
}

buildish_bootstrap_install_download_payload_set() {
  payload_dir=$1
  manifest_path=$2
  signature_path=$3

  for file_name in $BUILDISH_BOOTSTRAP_INSTALL_EXPECTED_FILES; do
    buildish_bootstrap_install_download_to_path \
      "$payload_dir/$file_name" \
      "$BUILDISH_BOOTSTRAP_INSTALL_BASE_URL/$file_name" \
      "payload file '$file_name'"
    buildish_bootstrap_install_assert_max_size \
      "$payload_dir/$file_name" \
      "$BUILDISH_BOOTSTRAP_INSTALL_MAX_PAYLOAD_BYTES" \
      "Payload file '$file_name'"
  done

  buildish_bootstrap_install_download_to_path \
    "$manifest_path" \
    "$BUILDISH_BOOTSTRAP_INSTALL_BASE_URL/$BUILDISH_BOOTSTRAP_INSTALL_MANIFEST_NAME" \
    'payload checksum manifest'
  buildish_bootstrap_install_assert_max_size \
    "$manifest_path" \
    "$BUILDISH_BOOTSTRAP_INSTALL_MAX_METADATA_BYTES" \
    'Payload checksum manifest'

  buildish_bootstrap_install_download_to_path \
    "$signature_path" \
    "$BUILDISH_BOOTSTRAP_INSTALL_BASE_URL/$BUILDISH_BOOTSTRAP_INSTALL_SIGNATURE_NAME" \
    'payload checksum manifest detached signature'
  buildish_bootstrap_install_assert_max_size \
    "$signature_path" \
    "$BUILDISH_BOOTSTRAP_INSTALL_MAX_METADATA_BYTES" \
    'Payload checksum manifest detached signature'
}

buildish_bootstrap_install_assert_verified_payload_set() {
  payload_dir=$1
  manifest_path=$2

  for file_name in $BUILDISH_BOOTSTRAP_INSTALL_EXPECTED_FILES; do
    expected_checksum=$(buildish_bootstrap_install_manifest_checksum_for_file "$manifest_path" "$file_name")
    actual_checksum=$(buildish_bootstrap_install_sha256_file "$payload_dir/$file_name")
    [ "$actual_checksum" = "$expected_checksum" ] ||
      buildish_bootstrap_install_fail "Downloaded payload file '$file_name' did not match the verified SHA-256 checksum."
  done
}

buildish_bootstrap_install_assert_rendered
buildish_bootstrap_install_require_command gpg
buildish_bootstrap_install_require_command mktemp
buildish_bootstrap_install_require_command grep

TARGET_DIR='.'
case $# in
  0) ;;
  1) TARGET_DIR=$1 ;;
  *) buildish_bootstrap_install_fail 'Expected zero or one positional argument: the target project directory.' ;;
esac

bootstrap_temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/buildish-bootstrap-install.XXXXXX") ||
  buildish_bootstrap_install_fail 'Unable to create the temporary bootstrap directory.'
payload_dir="$bootstrap_temp_dir/payload"
manifest_path="$bootstrap_temp_dir/$BUILDISH_BOOTSTRAP_INSTALL_MANIFEST_NAME"
signature_path="$bootstrap_temp_dir/$BUILDISH_BOOTSTRAP_INSTALL_SIGNATURE_NAME"
trap 'rm -rf "$bootstrap_temp_dir"' EXIT HUP INT TERM
mkdir "$payload_dir"

status=0
buildish_bootstrap_install_download_payload_set "$payload_dir" "$manifest_path" "$signature_path"
buildish_bootstrap_install_verify_manifest_signature "$manifest_path" "$signature_path"
buildish_bootstrap_install_assert_verified_payload_set "$payload_dir" "$manifest_path"
if sh "$payload_dir/install.sh" --trusted-source-dir "$payload_dir" "$TARGET_DIR"; then
  :
else
  status=$?
fi

trap - EXIT HUP INT TERM
rm -rf "$bootstrap_temp_dir"
exit "$status"