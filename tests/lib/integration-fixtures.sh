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

BUILDISH_TEST_MANIFEST=$BUILDISH_TEST_REPO_ROOT/tests/fixtures/compatibility-manifest.json
BUILDISH_TEST_RAW_PREFIX='https://raw.githubusercontent.com/gradle/gradle/'
BUILDISH_TEST_HTTP_PID=''
BUILDISH_TEST_HTTP_PORT=''

manifest_value() {
  python3 - "$BUILDISH_TEST_MANIFEST" "$@" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
for token in sys.argv[2:]:
    if token.isdigit():
        value = value[int(token)]
    else:
        value = value[token]
if isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
PY
}

manifest_entry_value() {
  local collection=$1 version=$2 key=$3
  python3 - "$BUILDISH_TEST_MANIFEST" "$collection" "$version" "$key" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in data[sys.argv[2]]:
    if entry["version"] == sys.argv[3]:
        print(entry[sys.argv[4]])
        break
else:
    raise SystemExit(f"missing manifest entry: {sys.argv[2]} {sys.argv[3]}")
PY
}

require_canonical_sources() {
  local source
  for source in buildish-wrapper-bootstrap.sh buildish-wrapper-bootstrap.ps1 buildish-wrapper.init.gradle.kts; do
    [[ -f $BUILDISH_TEST_REPO_ROOT/$source ]] || {
      test_fail "missing canonical replacement artifact: $source"
      return 1
    }
  done
}

copy_canonical_sources() {
  local consumer=$1
  require_canonical_sources
  mkdir -p "$consumer/gradle"
  cp "$BUILDISH_TEST_REPO_ROOT/buildish-wrapper-bootstrap.sh" "$consumer/gradle/"
  cp "$BUILDISH_TEST_REPO_ROOT/buildish-wrapper-bootstrap.ps1" "$consumer/gradle/"
  cp "$BUILDISH_TEST_REPO_ROOT/buildish-wrapper.init.gradle.kts" "$consumer/gradle/"
}

create_consumer() {
  local consumer=$1 bootstrap_version=$2 target_version=$3
  local target_url target_sha fixture_root
  target_url=$(manifest_entry_value targetDistributions "$target_version" url)
  target_sha=$(manifest_entry_value targetDistributions "$target_version" sha256)
  fixture_root=$BUILDISH_TEST_REPO_ROOT/tests/fixtures/launchers/$bootstrap_version
  mkdir -p "$consumer/gradle/wrapper"
  cp "$fixture_root/gradlew" "$consumer/gradlew"
  cp "$fixture_root/gradlew.bat" "$consumer/gradlew.bat"
  chmod +x "$consumer/gradlew"
  cat >"$consumer/settings.gradle.kts" <<'EOF'
rootProject.name = "buildish-test-consumer"
EOF
  : >"$consumer/build.gradle.kts"
  cat >"$consumer/gradle/wrapper/gradle-wrapper.properties" <<EOF
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=${target_url/:/\\:}
distributionSha256Sum=$target_sha
networkTimeout=10000
validateDistributionUrl=true
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
EOF
  cat >"$consumer/.gitignore" <<'EOF'
/gradle/wrapper/gradle-wrapper.jar
/.gradlew-buildish-update-*.bat
EOF
  cat >"$consumer/.gitattributes" <<'EOF'
/gradlew text eol=lf
/gradlew.bat -text
/gradle/buildish-wrapper-bootstrap.sh text eol=lf
/gradle/buildish-wrapper-bootstrap.ps1 text eol=lf
/gradle/buildish-wrapper.init.gradle.kts text eol=lf
EOF
  copy_canonical_sources "$consumer"
}

substitute_runtime_url() {
  local helper=$1 replacement=$2
  python3 - "$helper" "$BUILDISH_TEST_RAW_PREFIX" "$replacement" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
count = text.count(sys.argv[2])
if count != 1:
    raise SystemExit(f"fixture URL substitution expected one token, found {count}: {path}")
path.write_text(text.replace(sys.argv[2], sys.argv[3]), encoding="utf-8", newline="\n")
PY
}

start_http_fixture() {
  local payload=$1 stall_seconds=${2:-20}
  local server_dir=$BUILDISH_TEST_ROOT/http-$RANDOM-$RANDOM
  mkdir -p "$server_dir"
  python3 "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/http-server.py" \
    --payload "$payload" --log "$server_dir/requests.jsonl" \
    --port-file "$server_dir/port" --stall-seconds "$stall_seconds" \
    >"$server_dir/server.stdout" 2>"$server_dir/server.stderr" &
  BUILDISH_TEST_HTTP_PID=$!
  register_cleanup_pid "$BUILDISH_TEST_HTTP_PID"
  local attempt
  for attempt in {1..100}; do
    if [[ -s $server_dir/port ]]; then
      BUILDISH_TEST_HTTP_PORT=$(<"$server_dir/port")
      BUILDISH_TEST_HTTP_LOG=$server_dir/requests.jsonl
      return 0
    fi
    kill -0 "$BUILDISH_TEST_HTTP_PID" 2>/dev/null || test_fail "localhost fixture exited before publishing its port"
    sleep 0.05
  done
  test_fail "localhost fixture did not publish a port"
}

http_route_request_count() {
  local log=$1 route=$2
  python3 - "$log" "$route" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
if not path.exists():
    print(0)
    raise SystemExit
with path.open(encoding="utf-8") as stream:
    print(sum(json.loads(line)["route"] == sys.argv[2] for line in stream))
PY
}

assert_http_route_requested_once() {
  local log=$1 route=$2
  assert_http_route_request_count "$log" "$route" 1
}

assert_http_route_request_count() {
  local log=$1 route=$2 expected=$3
  local count
  count=$(http_route_request_count "$log" "$route")
  assert_equal "$expected" "$count" "HTTP request count for $route"
}

assert_http_request_path_once() {
  local log=$1 expected=$2
  python3 - "$log" "$expected" <<'PY'
import json
from pathlib import Path
import sys

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
matches = [record for record in records if record["path"] == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit(f"expected one request for {sys.argv[2]!r}, found {len(matches)}")
PY
}

provision_wrapper_jar() {
  local version=$1
  local destination=$BUILDISH_TEST_BUILD_ROOT/test-tools/wrapper-$version.jar
  local url expected actual
  url=$(manifest_entry_value wrapperVersions "$version" rawJarUrl)
  expected=$(manifest_entry_value wrapperVersions "$version" wrapperJarSha256)
  mkdir -p "$(dirname "$destination")"
  if [[ ! -f $destination ]]; then
    expect_success "download-wrapper-$version" 60 curl --fail --location --silent --show-error --output "$destination.tmp" "$url"
    mv "$destination.tmp" "$destination"
  fi
  actual=$(sha256_file "$destination")
  assert_equal "$expected" "$actual" "Wrapper JAR $version digest"
  printf '%s\n' "$destination"
}

provision_gradle() {
  local version=$1 env_name supplied_home home archive url expected actual
  env_name=BUILDISH_TEST_GRADLE_${version//./_}_HOME
  supplied_home=${!env_name:-}
  if [[ -n $supplied_home ]]; then
    [[ -x $supplied_home/bin/gradle ]] ||
      test_fail "supplied Gradle $version home is missing bin/gradle: $supplied_home"
    expect_success "validate-supplied-gradle-$version" 60 \
      env GRADLE_USER_HOME="$BUILDISH_TEST_BUILD_ROOT/test-tools/validate-gradle-$version-home" \
      "$supplied_home/bin/gradle" --no-daemon --version
    printf '%s\n' "$BUILDISH_TEST_LAST_STDOUT" | grep -Fxq "Gradle $version" ||
      test_fail "supplied Gradle home did not report exact version $version: $supplied_home"
    printf '%s\n' "$supplied_home/bin/gradle"
    return 0
  fi

  home=$BUILDISH_TEST_BUILD_ROOT/test-tools/gradle-$version
  if [[ -x $home/bin/gradle ]]; then
    expect_success "validate-provisioned-gradle-$version" 60 \
      env GRADLE_USER_HOME="$BUILDISH_TEST_BUILD_ROOT/test-tools/validate-gradle-$version-home" \
      "$home/bin/gradle" --no-daemon --version
    printf '%s\n' "$BUILDISH_TEST_LAST_STDOUT" | grep -Fxq "Gradle $version" ||
      test_fail "provisioned Gradle home did not report exact version $version: $home"
    printf '%s\n' "$home/bin/gradle"
    return 0
  fi
  archive=$BUILDISH_TEST_BUILD_ROOT/test-tools/gradle-$version-bin.zip
  url=$(manifest_entry_value targetDistributions "$version" url)
  expected=$(manifest_entry_value targetDistributions "$version" sha256)
  mkdir -p "$BUILDISH_TEST_BUILD_ROOT/test-tools"
  if [[ ! -f $archive ]]; then
    expect_success "download-gradle-$version" 180 curl --fail --location --silent --show-error --output "$archive.tmp" "$url"
    mv "$archive.tmp" "$archive"
  fi
  actual=$(sha256_file "$archive")
  assert_equal "$expected" "$actual" "Gradle $version distribution digest"
  [[ $home == "$BUILDISH_TEST_BUILD_ROOT/test-tools/gradle-$version" ]] ||
    test_fail "refusing to replace noncanonical Gradle home: $home"
  rm -rf "$home"
  expect_success "extract-gradle-$version" 120 python3 -m zipfile -e \
    "$archive" "$BUILDISH_TEST_BUILD_ROOT/test-tools"
  chmod +x "$home/bin/gradle"
  [[ -x $home/bin/gradle ]] || test_fail "provisioned Gradle executable is missing: $home/bin/gradle"
  printf '%s\n' "$home/bin/gradle"
}
