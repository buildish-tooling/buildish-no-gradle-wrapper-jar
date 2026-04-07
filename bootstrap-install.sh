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
# Important: the repository copy is a release template. A release step must fill in
# the hard-coded base URL and pinned signing-key material before users execute it.
# That keeps the final published script static and reviewable without reintroducing
# runtime remote-override knobs.

set -eu

TOOL='buildish-no-gradle-wrapper-jar bootstrap-install'
BASE_URL='__BUILDISH_BOOTSTRAP_INSTALL_BASE_URL__'
MANIFEST='bootstrap-install-posix.sha256'
SIGNATURE='bootstrap-install-posix.sha256.asc'
FINGERPRINT='__BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_FINGERPRINT__'
MAX_METADATA_BYTES=65536
MAX_PAYLOAD_BYTES=262144
FILES='install.sh buildish-no-gradle-wrapper-jar.sh buildish-no-gradle-wrapper-jar.ps1 buildish-no-gradle-wrapper-jar.init.gradle.kts'

die() {
  echo "$TOOL: $*" >&2
  exit 1
}

# __BUILDISH_BOOTSTRAP_INSTALL_DROP_START__
die 'This checked-in bootstrap-install.sh still contains unreplaced release placeholders. Use a release-generated bootstrap-install.sh or the reviewed local-copy/manual-verification flow.'
# __BUILDISH_BOOTSTRAP_INSTALL_DROP_END__

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print tolower($1); exit }'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print tolower($1); exit }'
    return 0
  fi
  die "Neither 'sha256sum' nor 'shasum' is available for checksum verification."
}

trusted_key() {
  cat <<'EOF'
__BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_PUBLIC_KEY__
EOF
}

cleanup() {
  [ -z "${bootstrap_temp_dir:-}" ] || rm -rf "$bootstrap_temp_dir"
  [ -z "${gpg_root:-}" ] || rm -rf "$gpg_root"
}

verify_signature() {
  manifest_path=$1
  signature_path=$2
  gpg_root=$3
  gpg_home="$gpg_root/home"
  trusted_key_path="$gpg_root/trusted-key.asc"

  mkdir "$gpg_home" || die 'Unable to create the temporary GnuPG home directory.'

  trusted_key > "$trusted_key_path"

  fingerprint_output=$(LC_ALL=C LANG=C gpg --homedir "$gpg_home" --batch --no-options --show-keys --with-colons --fingerprint "$trusted_key_path" 2>&1) || {
    die "Unable to inspect the pinned release signing key: ${fingerprint_output}"
  }

  actual_fingerprint=$(printf '%s\n' "$fingerprint_output" | awk -F: '$1 == "fpr" { print tolower($10); exit }')
  [ "$actual_fingerprint" = "$FINGERPRINT" ] || die 'Pinned release signing key fingerprint mismatch.'

  import_output=$(LC_ALL=C LANG=C gpg --homedir "$gpg_home" --batch --no-options --import "$trusted_key_path" 2>&1) || {
    die "Unable to import the pinned release signing key: ${import_output}"
  }

  verify_output=$(LC_ALL=C LANG=C gpg --homedir "$gpg_home" --batch --no-options --no-auto-key-retrieve --verify "$signature_path" "$manifest_path" 2>&1) || {
    die "Detached signature verification failed for the payload manifest: ${verify_output}"
  }
}

manifest_sha() {
  manifest_path=$1
  wanted_file=$2
  checksum=''
  count=0

  while IFS= read -r manifest_line || [ -n "$manifest_line" ]; do
    [ -n "$manifest_line" ] || continue
    set -- $manifest_line
    [ "$#" -eq 2 ] || die "Verified payload manifest line was malformed: '$manifest_line'."
    line_checksum=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    file_name=$2

    printf '%s' "$line_checksum" | grep -Eq '^[0-9a-f]{64}$' ||
      die "Verified payload manifest contained an invalid SHA-256 for '$file_name'."

    case " $FILES " in
      *" $file_name "*) ;;
      *) die "Verified payload manifest contained an unexpected file '$file_name'." ;;
    esac

    if [ "$file_name" = "$wanted_file" ]; then
      checksum=$line_checksum
      count=$((count + 1))
    fi
  done < "$manifest_path"

  [ "$count" -eq 1 ] || die "Verified payload manifest did not contain exactly one checksum entry for '$wanted_file'."
  printf '%s' "$checksum"
}

command -v gpg >/dev/null 2>&1 || die "Required command 'gpg' was not found on PATH."
command -v mktemp >/dev/null 2>&1 || die "Required command 'mktemp' was not found on PATH."
command -v grep >/dev/null 2>&1 || die "Required command 'grep' was not found on PATH."

TARGET_DIR='.'
case $# in
  0) ;;
  1) TARGET_DIR=$1 ;;
  *) die 'Expected zero or one positional argument: the target project directory.' ;;
esac

bootstrap_temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/buildish-bootstrap-install.XXXXXX") ||
  die 'Unable to create the temporary bootstrap directory.'
gpg_root=''
files_dir="$bootstrap_temp_dir/files"
manifest_path="$bootstrap_temp_dir/$MANIFEST"
signature_path="$bootstrap_temp_dir/$SIGNATURE"
trap cleanup EXIT HUP INT TERM
mkdir "$files_dir"

for file_name in $FILES; do
  target_path="$files_dir/$file_name"
  file_url="$BASE_URL/$file_name"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --output "$target_path" "$file_url" || die "Unable to download file '$file_name' from '$file_url'."
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$target_path" "$file_url" || die "Unable to download file '$file_name' from '$file_url'."
  else
    die "Either 'curl' or 'wget' is required to download file '$file_name'."
  fi

  actual_size=$(wc -c < "$target_path" | tr -d '[:space:]')
  [ "$actual_size" -le "$MAX_PAYLOAD_BYTES" ] ||
    die "File '$file_name' exceeded the maximum allowed size of ${MAX_PAYLOAD_BYTES} bytes."
done

if command -v curl >/dev/null 2>&1; then
  curl -fsSL --output "$manifest_path" "$BASE_URL/$MANIFEST" || die "Unable to download checksum manifest from '$BASE_URL/$MANIFEST'."
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "$manifest_path" "$BASE_URL/$MANIFEST" || die "Unable to download checksum manifest from '$BASE_URL/$MANIFEST'."
else
  die "Either 'curl' or 'wget' is required to download checksum manifest."
fi

actual_size=$(wc -c < "$manifest_path" | tr -d '[:space:]')
[ "$actual_size" -le "$MAX_METADATA_BYTES" ] ||
  die "Checksum manifest exceeded the maximum allowed size of ${MAX_METADATA_BYTES} bytes."

if command -v curl >/dev/null 2>&1; then
  curl -fsSL --output "$signature_path" "$BASE_URL/$SIGNATURE" || die "Unable to download checksum manifest detached signature from '$BASE_URL/$SIGNATURE'."
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "$signature_path" "$BASE_URL/$SIGNATURE" || die "Unable to download checksum manifest detached signature from '$BASE_URL/$SIGNATURE'."
else
  die "Either 'curl' or 'wget' is required to download checksum manifest detached signature."
fi

actual_size=$(wc -c < "$signature_path" | tr -d '[:space:]')
[ "$actual_size" -le "$MAX_METADATA_BYTES" ] ||
  die "Checksum manifest detached signature exceeded the maximum allowed size of ${MAX_METADATA_BYTES} bytes."

gpg_root=$(mktemp -d "${TMPDIR:-/tmp}/buildish-bootstrap-install-gpg.XXXXXX") ||
  die 'Unable to create a temporary GnuPG home.'
verify_signature "$manifest_path" "$signature_path" "$gpg_root"
for file_name in $FILES; do
  expected_checksum=$(manifest_sha "$manifest_path" "$file_name")
  actual_checksum=$(sha256_file "$files_dir/$file_name")
  [ "$actual_checksum" = "$expected_checksum" ] ||
    die "Downloaded file '$file_name' did not match the verified SHA-256 checksum."
done

sh "$files_dir/install.sh" --trusted-source-dir "$files_dir" "$TARGET_DIR"