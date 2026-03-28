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

BUILDISH_TEST_REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILDISH_TEST_BUILD_ROOT=$BUILDISH_TEST_REPO_ROOT/build
mkdir -p "$BUILDISH_TEST_BUILD_ROOT/tests"
BUILDISH_TEST_ROOT=$(mktemp -d "$BUILDISH_TEST_BUILD_ROOT/tests/run.XXXXXX")
GRADLE_USER_HOME=$BUILDISH_TEST_ROOT/gradle-user-home
export BUILDISH_TEST_REPO_ROOT BUILDISH_TEST_BUILD_ROOT BUILDISH_TEST_ROOT GRADLE_USER_HOME

# shellcheck source=tests/lib/integration-common.sh
source "$BUILDISH_TEST_REPO_ROOT/tests/lib/integration-common.sh"
# shellcheck source=tests/lib/integration-fixtures.sh
source "$BUILDISH_TEST_REPO_ROOT/tests/lib/integration-fixtures.sh"
# shellcheck source=tests/suites/integration-runtime.sh
source "$BUILDISH_TEST_REPO_ROOT/tests/suites/integration-runtime.sh"
# shellcheck source=tests/suites/integration-init-script.sh
source "$BUILDISH_TEST_REPO_ROOT/tests/suites/integration-init-script.sh"

for optional_suite in integration-invariants.sh integration-renovate.sh; do
  if [[ -f $BUILDISH_TEST_REPO_ROOT/tests/suites/$optional_suite ]]; then
    # shellcheck source=/dev/null
    source "$BUILDISH_TEST_REPO_ROOT/tests/suites/$optional_suite"
  fi
done

finish_integration() {
  local status=$?
  trap - EXIT HUP INT TERM
  cleanup_registered_resources
  if [[ $status == 0 && $BUILDISH_TEST_FAILURE == 0 ]]; then
    rm -rf -- "$BUILDISH_TEST_ROOT"
    test_log 'all requested suites passed'
    exit 0
  fi
  if [[ $status == 0 ]]; then
    status=1
  fi
  test_log "failure artifacts retained under $BUILDISH_TEST_ROOT"
  exit "$status"
}
trap finish_integration EXIT
trap 'exit 130' HUP INT TERM

run_scaffolding_suite() {
  BUILDISH_TEST_CASE='scaffolding'
  require_command bash
  require_command python3
  require_command setsid
  require_command timeout
  python3 -m json.tool "$BUILDISH_TEST_MANIFEST" >/dev/null
  python3 - "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/http-server.py" <<'PY'
import ast
from pathlib import Path
import sys
ast.parse(Path(sys.argv[1]).read_text(encoding="utf-8"), filename=sys.argv[1])
PY
  if [[ -f $BUILDISH_TEST_REPO_ROOT/tests/fixtures/launcher-contract.py ]]; then
    expect_success scaffolding-launchers 20 python3 \
      "$BUILDISH_TEST_REPO_ROOT/tests/fixtures/launcher-contract.py" \
      check-fixtures --manifest "$BUILDISH_TEST_MANIFEST"
  fi

  local payload=$BUILDISH_TEST_REPO_ROOT/tests/fixtures/launchers/8.14.5/gradlew
  start_http_fixture "$payload" 2
  expect_success scaffolding-http 10 python3 - "$BUILDISH_TEST_HTTP_PORT" <<'PY'
from urllib.request import urlopen
import sys
with urlopen(f"http://127.0.0.1:{sys.argv[1]}/jar", timeout=2) as response:
    assert response.status == 200
    assert response.read(2) == b"#!"
PY
  expect_success scaffolding-http-misleading-length 20 python3 - \
    "$BUILDISH_TEST_HTTP_PORT" <<'PY'
from urllib.request import urlopen
import sys

with urlopen(
    f"http://127.0.0.1:{sys.argv[1]}/oversize/misleading", timeout=5
) as response:
    total = 0
    while block := response.read(64 * 1024):
        total += len(block)
assert total > 10 * 1024 * 1024, total
PY

  local descendant_pid_file=$BUILDISH_TEST_ROOT/timeout-descendant.pid
  expect_timeout scaffolding-timeout-descendants 1 bash -c '
    bash -c '\''
      trap "" TERM
      printf "%s\\n" "$$" >"$1"
      while :; do sleep 1; done
    '\'' buildish-timeout-descendant "$1" &
    wait
  ' buildish-timeout-parent "$descendant_pid_file"
  [[ -s $descendant_pid_file ]] || test_fail 'timeout descendant did not publish its PID'
  local descendant_pid
  descendant_pid=$(<"$descendant_pid_file")
  local attempt
  for attempt in {1..100}; do
    if ! kill -0 "$descendant_pid" 2>/dev/null; then
      descendant_pid=
      break
    fi
    sleep 0.01
  done
  [[ -z $descendant_pid ]] || test_fail "timeout left descendant PID $descendant_pid running"
}

run_named_suite() {
  case $1 in
    scaffolding) run_scaffolding_suite ;;
    invariants)
      declare -F run_invariants_suite >/dev/null ||
        test_fail 'missing required test artifact: tests/suites/integration-invariants.sh'
      run_invariants_suite
      ;;
    runtime) run_runtime_suite ;;
    lifecycle) run_lifecycle_suite ;;
    renovate)
      declare -F run_renovate_suite >/dev/null ||
        test_fail 'missing required test artifact: tests/suites/integration-renovate.sh'
      run_renovate_suite
      ;;
    *) test_fail "unsupported suite '$1'" ;;
  esac
}

mode=${1:-all}
[[ $# -le 1 ]] || test_fail 'usage: tests/integration.sh [all|scaffolding|invariants|runtime|lifecycle|renovate]'
case $mode in
  all)
    for suite in scaffolding invariants runtime lifecycle renovate; do
      run_named_suite "$suite"
    done
    ;;
  scaffolding|invariants|runtime|lifecycle|renovate)
    run_named_suite "$mode"
    ;;
  *)
    test_fail "usage: tests/integration.sh [all|scaffolding|invariants|runtime|lifecycle|renovate]"
    ;;
esac
