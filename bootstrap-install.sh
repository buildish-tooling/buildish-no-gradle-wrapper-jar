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

# Tiny secure bootstrap verifier for the no-gradle-wrapper-jar installer.
#
# Important: the repository copy is a release template. A release step must fill in
# the hard-coded base URL, manifest digest, and pinned signing-key material before users execute it.
# That keeps the final published script static and reviewable without reintroducing
# runtime remote-override knobs.

set -eu

TOOL='buildish-no-gradle-wrapper-jar bootstrap-install'
BASE_URL='__BUILDISH_BOOTSTRAP_INSTALL_BASE_URL__'
MANIFEST='bootstrap-install-posix.sha256'
SIGNATURE='bootstrap-install-posix.sha256.asc'
EXPECTED_MANIFEST_SHA256='__BUILDISH_BOOTSTRAP_INSTALL_MANIFEST_SHA256__'
FINGERPRINT='__BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_FINGERPRINT__'
MAX_METADATA_BYTES=65536
MAX_PAYLOAD_BYTES=262144
HTTP_TIMEOUT_SECONDS=${BUILDISH_BOOTSTRAP_INSTALL_HTTP_TIMEOUT_SECONDS:-60}
FILES='install.sh buildish-no-gradle-wrapper-jar.sh buildish-no-gradle-wrapper-jar.ps1 buildish-no-gradle-wrapper-jar.init.gradle.kts'

die() {
  echo "$TOOL: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bootstrap-install.sh [target-project-directory]

Download and verify a release-pinned installer payload, then install it into a
Gradle project. The checked-in file is a fail-closed release template; only a
release-rendered copy can perform installation.

Options:
  -h, --help  Show this help and exit without downloading.
EOF
}

case ${1:-} in
  -h|--help)
    usage
    exit 0
    ;;
esac

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
  [ -z "${download_pid:-}" ] || kill "$download_pid" >/dev/null 2>&1 || true
  [ -z "${watchdog_pid:-}" ] || kill "$watchdog_pid" >/dev/null 2>&1 || true
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

# Stream at most one 4096-byte block beyond the declared limit. The extra block
# distinguishes an exact-boundary response from an oversized response even when
# the server omits Content-Length. Closing the FIFO then stops the downloader.
download() {
  target_path=$1
  download_url=$2
  resource_label=$3
  max_size_bytes=$4
  fifo_path="${target_path}.fifo"
  stderr_path="${target_path}.stderr"
  timeout_marker_path="${target_path}.timeout"
  download_status=0
  reader_status=0
  watchdog_pid=''

  rm -f "$target_path" "$fifo_path" "$stderr_path" "$timeout_marker_path"
  mkfifo "$fifo_path" || die "Unable to create a bounded download pipe for ${resource_label}."

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL \
      --connect-timeout "$HTTP_TIMEOUT_SECONDS" \
      --max-time "$HTTP_TIMEOUT_SECONDS" \
      --max-filesize "$max_size_bytes" \
      "$download_url" > "$fifo_path" 2> "$stderr_path" &
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O - "$download_url" > "$fifo_path" 2> "$stderr_path" &
  else
    rm -f "$fifo_path"
    die "Either 'curl' or 'wget' is required to download ${resource_label}."
  fi
  download_pid=$!

  if ! command -v curl >/dev/null 2>&1; then
    (
      sleep "$HTTP_TIMEOUT_SECONDS"
      : > "$timeout_marker_path"
      kill "$download_pid" >/dev/null 2>&1 || true
    ) &
    watchdog_pid=$!
  fi

  block_count=$((max_size_bytes / 4096 + 1))
  dd if="$fifo_path" of="$target_path" bs=4096 count="$block_count" 2>/dev/null || reader_status=$?
  rm -f "$fifo_path"
  wait "$download_pid" || download_status=$?
  download_pid=''
  if [ -n "$watchdog_pid" ]; then
    kill "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" >/dev/null 2>&1 || true
    watchdog_pid=''
  fi

  download_output=$(cat "$stderr_path" 2>/dev/null || true)
  actual_size=$(wc -c < "$target_path" | tr -d '[:space:]')
  rm -f "$stderr_path"

  if [ "$actual_size" -gt "$max_size_bytes" ] || [ "$download_status" -eq 63 ] || printf '%s' "$download_output" | grep -Fq 'Maximum file size exceeded'; then
    rm -f "$target_path" "$timeout_marker_path"
    die "${resource_label} exceeded the maximum allowed size of ${max_size_bytes} bytes."
  fi
  if [ -f "$timeout_marker_path" ] || [ "$download_status" -eq 28 ]; then
    rm -f "$target_path" "$timeout_marker_path"
    die "Downloading ${resource_label} from '${download_url}' timed out after ${HTTP_TIMEOUT_SECONDS} seconds."
  fi
  rm -f "$timeout_marker_path"
  if [ "$reader_status" -ne 0 ] || [ "$download_status" -ne 0 ]; then
    [ -n "$download_output" ] && printf '%s\n' "$download_output" >&2
    rm -f "$target_path"
    die "Unable to download ${resource_label} from '${download_url}'."
  fi
}

command -v gpg >/dev/null 2>&1 || die "Required command 'gpg' was not found on PATH."
command -v mktemp >/dev/null 2>&1 || die "Required command 'mktemp' was not found on PATH."
command -v grep >/dev/null 2>&1 || die "Required command 'grep' was not found on PATH."
command -v mkfifo >/dev/null 2>&1 || die "Required command 'mkfifo' was not found on PATH."
command -v dd >/dev/null 2>&1 || die "Required command 'dd' was not found on PATH."
printf '%s' "$EXPECTED_MANIFEST_SHA256" | grep -Eq '^[0-9a-f]{64}$' ||
  die 'Pinned release manifest SHA-256 must be exactly 64 lowercase hexadecimal characters.'
case $HTTP_TIMEOUT_SECONDS in
  ''|*[!0-9]*) die 'BUILDISH_BOOTSTRAP_INSTALL_HTTP_TIMEOUT_SECONDS must be a positive integer.' ;;
esac
case $HTTP_TIMEOUT_SECONDS in
  *[1-9]*) ;;
  *) die 'BUILDISH_BOOTSTRAP_INSTALL_HTTP_TIMEOUT_SECONDS must be a positive integer.' ;;
esac

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
  download "$target_path" "$file_url" "File '$file_name'" "$MAX_PAYLOAD_BYTES"
done

download "$manifest_path" "$BASE_URL/$MANIFEST" 'Checksum manifest' "$MAX_METADATA_BYTES"
actual_manifest_sha256=$(sha256_file "$manifest_path")
[ "$actual_manifest_sha256" = "$EXPECTED_MANIFEST_SHA256" ] ||
  die 'Checksum manifest did not match the release-pinned SHA-256.'

download "$signature_path" "$BASE_URL/$SIGNATURE" 'Checksum manifest detached signature' "$MAX_METADATA_BYTES"

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
