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

# Fixture builders and mutable test-environment helpers for the integration
# suite. tests/integration.sh sources this after integration-common.sh.

# Create oversized metadata or JAR fixtures deterministically so download-limit
# tests can target exact byte thresholds.
write_file_with_size() {
  file_path=$1
  size_bytes=$2
  prefix_text=${3:-}
  python3 - <<'PY' "$file_path" "$size_bytes" "$prefix_text"
from pathlib import Path
import sys

path = Path(sys.argv[1])
size_bytes = int(sys.argv[2])
prefix = sys.argv[3].encode('utf-8')
if len(prefix) > size_bytes:
    raise SystemExit(1)
path.write_bytes(prefix + (b'a' * (size_bytes - len(prefix))))
PY
}

# Generate an isolated throwaway GPG identity so bootstrap tests can exercise
# signature verification without depending on any developer machine keyring.
create_bootstrap_signing_fixture() {
  signing_root=$1
  BOOTSTRAP_TEST_GPG_HOME="$signing_root/gpg-home"
  BOOTSTRAP_TEST_PUBLIC_KEY_PATH="$signing_root/trusted-bootstrap-key.asc"

  mkdir -p "$BOOTSTRAP_TEST_GPG_HOME"
  gpg --batch --homedir "$BOOTSTRAP_TEST_GPG_HOME" --pinentry-mode loopback --passphrase '' --quick-gen-key 'Buildish Bootstrap Integration Test <bootstrap@example.invalid>' rsa3072 sign 0 >/dev/null 2>&1 ||
    fail 'unable to generate the bootstrap integration signing key.'

  BOOTSTRAP_TEST_SIGNER_FINGERPRINT=$(gpg --batch --homedir "$BOOTSTRAP_TEST_GPG_HOME" --list-keys --with-colons --fingerprint | awk -F: '$1 == "fpr" { print tolower($10); exit }')
  [ -n "$BOOTSTRAP_TEST_SIGNER_FINGERPRINT" ] || fail 'unable to determine the bootstrap integration signing-key fingerprint.'

  gpg --batch --homedir "$BOOTSTRAP_TEST_GPG_HOME" --armor --export "$BOOTSTRAP_TEST_SIGNER_FINGERPRINT" > "$BOOTSTRAP_TEST_PUBLIC_KEY_PATH" ||
    fail 'unable to export the bootstrap integration public key.'
}

# Render a release-like bootstrap script from the checked-in template so the
# bootstrap tests can validate signed payload flows with local fixtures.
render_bootstrap_release_script() {
  template_path=$1
  output_path=$2
  bootstrap_kind=$3
  base_url=$4
  trusted_fingerprint=$5
  public_key_path=$6

  python3 - <<'PY' "$template_path" "$output_path" "$bootstrap_kind" "$base_url" "$trusted_fingerprint" "$public_key_path" || exit 1
from pathlib import Path
import re
import sys

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
bootstrap_kind = sys.argv[3]
base_url = sys.argv[4]
trusted_fingerprint = sys.argv[5]
public_key = Path(sys.argv[6]).read_text().rstrip('\n')
text = template_path.read_text()

drop_pattern = r'(?ms)^# __BUILDISH_BOOTSTRAP_INSTALL_DROP_START__\n.*?^# __BUILDISH_BOOTSTRAP_INSTALL_DROP_END__\n?'
text, drop_count = re.subn(drop_pattern, '', text, count=1)
if drop_count != 1:
    raise SystemExit(1)

if bootstrap_kind == 'posix':
    replacements = {
        r"^BASE_URL=.*$": f"BASE_URL='{base_url}'",
        r"^FINGERPRINT=.*$": f"FINGERPRINT='{trusted_fingerprint}'",
    }
elif bootstrap_kind == 'powershell':
    replacements = {
        r'^\$BaseUrl = .*$': f'$BaseUrl = "{base_url}"',
        r'^\$Fingerprint = .*$': f'$Fingerprint = "{trusted_fingerprint}"',
    }
else:
    raise SystemExit(1)

for pattern, replacement in replacements.items():
    text, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(1)

if '__BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_PUBLIC_KEY__' not in text:
    raise SystemExit(1)
text = text.replace('__BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_PUBLIC_KEY__', public_key)
output_path.write_text(text)
PY

  case "$bootstrap_kind" in
    posix) chmod +x "$output_path" ;;
  esac
}

# Build the signed payload manifest from the exact fixture files so bootstrap
# scenarios can control which entries are present.
write_bootstrap_manifest() {
  server_root=$1
  manifest_path=$2
  shift 2

  : > "$manifest_path"
  for file_name in "$@"; do
    printf '%s  %s\n' "$(hash_file "$server_root/$file_name")" "$file_name" >> "$manifest_path"
  done
}

# Sign the bootstrap manifest with the ephemeral test key so signature checks
# exercise the same trust path as a real release artifact.
sign_bootstrap_manifest() {
  manifest_path=$1
  signature_path=$2

  gpg --batch --homedir "$BOOTSTRAP_TEST_GPG_HOME" --pinentry-mode loopback --passphrase '' --armor --local-user "$BOOTSTRAP_TEST_SIGNER_FINGERPRINT" --output "$signature_path" --detach-sign "$manifest_path" >/dev/null 2>&1 ||
    fail "unable to sign bootstrap payload manifest '$manifest_path'."
}

# Tear down whichever local HTTP server is active so each scenario starts from a
# clean network fixture and long-lived background processes do not leak.
stop_test_http_server() {
  if [ -n "$TEST_HTTP_SERVER_PID" ]; then
    kill "$TEST_HTTP_SERVER_PID" >/dev/null 2>&1 || true
    wait "$TEST_HTTP_SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$TEST_HTTP_SERVER_LOG" "$TEST_HTTP_SERVER_PORT_FILE"
  TEST_HTTP_SERVER_PID=''
  TEST_HTTP_SERVER_PORT=''
  TEST_HTTP_SERVER_LOG=''
  TEST_HTTP_SERVER_PORT_FILE=''
}

# Serve a directory over localhost so download scenarios can fetch deterministic
# local fixtures without reaching external infrastructure.
start_static_http_server() {
  served_dir=$1
  stop_test_http_server
  TEST_HTTP_SERVER_PORT_FILE=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-http-port.XXXXXX")
  TEST_HTTP_SERVER_LOG=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-http-log.XXXXXX")

  python3 - <<'PY' "$served_dir" "$TEST_HTTP_SERVER_PORT_FILE" >"$TEST_HTTP_SERVER_LOG" 2>&1 &
import functools
import http.server
import socketserver
import sys

served_dir = sys.argv[1]
port_file = sys.argv[2]

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=served_dir)
with ReusableTCPServer(("127.0.0.1", 0), handler) as httpd:
    with open(port_file, "w", encoding="utf-8") as handle:
        handle.write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY
  TEST_HTTP_SERVER_PID=$!

  for _ in $(seq 1 100); do
    if [ -s "$TEST_HTTP_SERVER_PORT_FILE" ]; then
      TEST_HTTP_SERVER_PORT=$(cat "$TEST_HTTP_SERVER_PORT_FILE")
      return 0
    fi
    if ! kill -0 "$TEST_HTTP_SERVER_PID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.05
  done

  log_contents=$(cat "$TEST_HTTP_SERVER_LOG" 2>/dev/null || true)
  stop_test_http_server
  fail "unable to start the local HTTP test server. log=$log_contents"
}

# Accept TCP connections and then hang so the PowerShell timeout path can be
# exercised without relying on flaky network conditions.
start_stalling_http_server() {
  stop_test_http_server
  TEST_HTTP_SERVER_PORT_FILE=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-http-port.XXXXXX")
  TEST_HTTP_SERVER_LOG=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-http-log.XXXXXX")

  python3 - <<'PY' "$TEST_HTTP_SERVER_PORT_FILE" >"$TEST_HTTP_SERVER_LOG" 2>&1 &
import socket
import sys
import time

port_file = sys.argv[1]

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(5)
    with open(port_file, "w", encoding="utf-8") as handle:
        handle.write(str(server.getsockname()[1]))
    while True:
        connection, _ = server.accept()
        with connection:
            time.sleep(60)
PY
  TEST_HTTP_SERVER_PID=$!

  for _ in $(seq 1 100); do
    if [ -s "$TEST_HTTP_SERVER_PORT_FILE" ]; then
      TEST_HTTP_SERVER_PORT=$(cat "$TEST_HTTP_SERVER_PORT_FILE")
      return 0
    fi
    if ! kill -0 "$TEST_HTTP_SERVER_PID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.05
  done

  log_contents=$(cat "$TEST_HTTP_SERVER_LOG" 2>/dev/null || true)
  stop_test_http_server
  fail "unable to start the stalling HTTP test server. log=$log_contents"
}

# Assemble a release-like bootstrap payload tree, optionally damage the manifest
# or signature, and expose it over localhost for end-to-end bootstrap tests.
prepare_bootstrap_release_fixture() {
  server_root=$1
  bootstrap_kind=$2
  manifest_mode=$3
  signature_mode=$4

  rm -rf "$server_root"
  mkdir -p "$server_root"

  case "$bootstrap_kind" in
    posix)
      bootstrap_template_path="$TOOL_DIR/bootstrap-install.sh"
      bootstrap_output_path="$server_root/bootstrap-install.sh"
      installer_file='install.sh'
      manifest_name='bootstrap-install-posix.sha256'
      signature_name='bootstrap-install-posix.sha256.asc'
      ;;
    powershell)
      bootstrap_template_path="$TOOL_DIR/bootstrap-install.ps1"
      bootstrap_output_path="$server_root/bootstrap-install.ps1"
      installer_file='install.ps1'
      manifest_name='bootstrap-install-powershell.sha256'
      signature_name='bootstrap-install-powershell.sha256.asc'
      ;;
    *)
      fail "unknown bootstrap kind '$bootstrap_kind'"
      ;;
  esac

  cp "$TOOL_DIR/$installer_file" "$server_root/$installer_file"
  cp "$TOOL_DIR/buildish-no-gradle-wrapper-jar.sh" "$server_root/buildish-no-gradle-wrapper-jar.sh"
  cp "$TOOL_DIR/buildish-no-gradle-wrapper-jar.ps1" "$server_root/buildish-no-gradle-wrapper-jar.ps1"
  cp "$TOOL_DIR/buildish-no-gradle-wrapper-jar.init.gradle.kts" "$server_root/buildish-no-gradle-wrapper-jar.init.gradle.kts"

  case "$manifest_mode" in
    complete)
      manifest_files="$installer_file buildish-no-gradle-wrapper-jar.sh buildish-no-gradle-wrapper-jar.ps1 buildish-no-gradle-wrapper-jar.init.gradle.kts"
      ;;
    missing-helper)
      manifest_files="$installer_file buildish-no-gradle-wrapper-jar.sh buildish-no-gradle-wrapper-jar.init.gradle.kts"
      ;;
    *)
      fail "unknown manifest mode '$manifest_mode'"
      ;;
  esac

  # shellcheck disable=SC2086
  write_bootstrap_manifest "$server_root" "$server_root/$manifest_name" $manifest_files
  sign_bootstrap_manifest "$server_root/$manifest_name" "$server_root/$signature_name"

  case "$signature_mode" in
    valid)
      ;;
    tampered)
      printf '%s\n' '# tampered after signing' >> "$server_root/$manifest_name"
      ;;
    *)
      fail "unknown signature mode '$signature_mode'"
      ;;
  esac

  start_static_http_server "$server_root"
  render_bootstrap_release_script "$bootstrap_template_path" "$bootstrap_output_path" "$bootstrap_kind" "http://127.0.0.1:$TEST_HTTP_SERVER_PORT" "$BOOTSTRAP_TEST_SIGNER_FINGERPRINT" "$BOOTSTRAP_TEST_PUBLIC_KEY_PATH"
}

# Copy a project fixture into an isolated scenario directory so each exercise is
# free to mutate files without contaminating later tests.
copy_project_fixture() {
  source_dir=$1
  target_dir=$2
  rm -rf "$target_dir"
  mkdir -p "$(dirname "$target_dir")"
  cp -R "$source_dir" "$target_dir"
}

# Add the checked-in init script to a project fixture so init-script-focused
# tests can run without first invoking the full installer flow.
copy_init_script_into_project() {
  project_dir=$1
  mkdir -p "$project_dir/gradle"
  cp "$TOOL_DIR/buildish-no-gradle-wrapper-jar.init.gradle.kts" "$(gradle_init_script_path "$project_dir")"
}

# Clone a base project and inject the init script in one step because the
# focused init-script suite repeats that setup many times.
copy_init_script_fixture() {
  source_dir=$1
  target_dir=$2
  copy_project_fixture "$source_dir" "$target_dir"
  copy_init_script_into_project "$target_dir"
}

# Create a fresh Gradle sample project that mirrors a real consumer checkout so
# installer and helper tests can mutate launcher files in realistic fixtures.
gradle_init_fixture() {
  project_dir=$1
  bootstrap_gradle_version=${2:-}
  fixture_gradle_user_home=$(gradle_user_home "$project_dir")
  mkdir -p "$project_dir"
  log "initializing fixture in '$project_dir' (GRADLE_USER_HOME='$fixture_gradle_user_home'${bootstrap_gradle_version:+, bootstrap Gradle='$bootstrap_gradle_version'})"
  if [ -n "$bootstrap_gradle_version" ]; then
    use_sdkman_gradle_version "$bootstrap_gradle_version"
    # Gradle 8.1.x still prompts for the target Java version and whether to use
    # incubating APIs even when the project type and DSL are specified. Feed the
    # stable answers explicitly so the version exercise stays non-interactive.
    printf '17\nno\n' | GRADLE_USER_HOME="$fixture_gradle_user_home" gradle -p "$project_dir" init --dsl groovy --type java-library --project-name sample --package org.example --test-framework junit --no-daemon --console=plain >/dev/null
  else
    GRADLE_USER_HOME="$fixture_gradle_user_home" gradle -p "$project_dir" init --dsl groovy --type java-library --use-defaults --no-daemon >/dev/null
  fi
  [ -f "$project_dir/gradle/wrapper/gradle-wrapper.jar" ] || fail "gradle init did not create gradle-wrapper.jar in '$project_dir'."
  wrapper_jar_sha256=$(hash_file "$project_dir/gradle/wrapper/gradle-wrapper.jar")
  set_wrapper_property \
    "$project_dir/gradle/wrapper/gradle-wrapper.properties" \
    buildishWrapperJarSha256Sum \
    "$wrapper_jar_sha256"
}
