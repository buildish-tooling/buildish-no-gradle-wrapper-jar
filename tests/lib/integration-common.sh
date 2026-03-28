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

if [[ ${BUILDISH_TEST_COMMON_LOADED:-} == 1 ]]; then
  return 0
fi
BUILDISH_TEST_COMMON_LOADED=1

declare -a BUILDISH_TEST_CLEANUP_PIDS=()
declare -a BUILDISH_TEST_CLEANUP_PATHS=()
declare -a BUILDISH_TEST_CLEANUP_FUNCTIONS=()
BUILDISH_TEST_CASE='scaffolding'
BUILDISH_TEST_FAILURE=0
BUILDISH_TEST_LAST_STATUS=0
BUILDISH_TEST_LAST_STDOUT=''
BUILDISH_TEST_LAST_STDERR=''

test_log() {
  printf 'integration-test: %s\n' "$*" >&2
}

test_fail() {
  test_log "${BUILDISH_TEST_CASE}: $*"
  BUILDISH_TEST_FAILURE=1
  return 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || test_fail "required command '$1' is unavailable"
}

register_cleanup_pid() {
  BUILDISH_TEST_CLEANUP_PIDS+=("$1")
}

unregister_cleanup_pid() {
  local target=$1 pid
  local -a retained=()
  for pid in "${BUILDISH_TEST_CLEANUP_PIDS[@]}"; do
    if [[ $pid != "$target" ]]; then
      retained+=("$pid")
    fi
  done
  BUILDISH_TEST_CLEANUP_PIDS=("${retained[@]}")
}

register_cleanup_path() {
  BUILDISH_TEST_CLEANUP_PATHS+=("$1")
}

register_cleanup_function() {
  declare -F "$1" >/dev/null 2>&1 || test_fail "cleanup function does not exist: $1"
  BUILDISH_TEST_CLEANUP_FUNCTIONS+=("$1")
}

cleanup_registered_resources() {
  local cleanup_function pid path
  for cleanup_function in "${BUILDISH_TEST_CLEANUP_FUNCTIONS[@]}"; do
    "$cleanup_function" || true
  done
  BUILDISH_TEST_CLEANUP_FUNCTIONS=()
  for pid in "${BUILDISH_TEST_CLEANUP_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  BUILDISH_TEST_CLEANUP_PIDS=()
  for path in "${BUILDISH_TEST_CLEANUP_PATHS[@]}"; do
    [[ -n $path && $path == "$BUILDISH_TEST_BUILD_ROOT"/* ]] || continue
    rm -rf -- "$path"
  done
  BUILDISH_TEST_CLEANUP_PATHS=()
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    test_fail "neither sha256sum nor shasum is available"
  fi
}

assert_file_exists() {
  [[ -f $1 ]] || test_fail "expected file does not exist: $1"
}

assert_file_absent() {
  [[ ! -e $1 ]] || test_fail "unexpected path exists: $1"
}

assert_equal() {
  local expected=$1 actual=$2 description=$3
  [[ $actual == "$expected" ]] || test_fail "$description: expected '$expected', got '$actual'"
}

assert_contains() {
  local value=$1 expected=$2 description=$3
  [[ $value == *"$expected"* ]] || test_fail "$description: missing '$expected'"
}

assert_not_contains() {
  local value=$1 unexpected=$2 description=$3
  [[ $value != *"$unexpected"* ]] || test_fail "$description: unexpectedly contained '$unexpected'"
}

assert_no_wrapper_temporaries() {
  local wrapper_dir=$1
  local matches
  matches=$(find "$wrapper_dir" -maxdepth 1 -type f \
    ! -name gradle-wrapper.properties ! -name gradle-wrapper.jar -print 2>/dev/null || true)
  [[ -z $matches ]] || test_fail "unexpected Wrapper-directory files remain: $matches"
}

run_bounded() {
  local label=$1 seconds=$2
  shift 2
  local case_dir stdout_file stderr_file group_file group_id attempt started_at
  local -a command
  case_dir=$BUILDISH_TEST_ROOT/logs/$label
  mkdir -p "$case_dir"
  stdout_file=$case_dir/stdout
  stderr_file=$case_dir/stderr
  group_file=$case_dir/process-group
  if declare -F "$1" >/dev/null 2>&1; then
    local function_definition
    function_definition=$(declare -f "$1")
    command=(bash -c "$function_definition"$'\n''"$0" "$@"' "$@")
  else
  command=("$@")
  fi
  started_at=$SECONDS
  set +e
  timeout --foreground --signal=KILL "${seconds}s" \
    setsid bash -c 'printf "%s\n" "$$" >"$1"; shift; exec "$@"' \
      buildish-bounded-session "$group_file" "${command[@]}" \
    >"$stdout_file" 2>"$stderr_file"
  BUILDISH_TEST_LAST_STATUS=$?
  set -e
  if [[ $BUILDISH_TEST_LAST_STATUS == 124 || $BUILDISH_TEST_LAST_STATUS == 137 ]]; then
    if [[ -s $group_file ]]; then
      group_id=$(<"$group_file")
      if [[ $group_id =~ ^[1-9][0-9]*$ ]]; then
        kill -KILL -- "-$group_id" 2>/dev/null || true
        for attempt in {1..100}; do
          kill -0 -- "-$group_id" 2>/dev/null || break
          sleep 0.01
        done
        if kill -0 -- "-$group_id" 2>/dev/null; then
          test_fail "$label could not terminate process group $group_id after timeout"
        fi
      else
        test_fail "$label recorded an invalid process group: $group_id"
      fi
    else
      test_fail "$label timed out before recording its process group"
    fi
  fi
  BUILDISH_TEST_LAST_STDOUT=$(cat "$stdout_file")
  BUILDISH_TEST_LAST_STDERR=$(cat "$stderr_file")
  BUILDISH_TEST_LAST_DURATION_SECONDS=$((SECONDS - started_at))
  test_log "TIMING $label ${BUILDISH_TEST_LAST_DURATION_SECONDS}s"
}

expect_success() {
  local label=$1 seconds=$2
  shift 2
  run_bounded "$label" "$seconds" "$@"
  if [[ $BUILDISH_TEST_LAST_STATUS == 124 || $BUILDISH_TEST_LAST_STATUS == 137 ]]; then
    test_fail "$label exceeded ${seconds}s"
    return
  fi
  [[ $BUILDISH_TEST_LAST_STATUS == 0 ]] || {
    test_log "$label stdout: $BUILDISH_TEST_LAST_STDOUT"
    test_log "$label stderr: $BUILDISH_TEST_LAST_STDERR"
    test_fail "$label exited $BUILDISH_TEST_LAST_STATUS"
  }
}

expect_failure() {
  local label=$1 seconds=$2
  shift 2
  run_bounded "$label" "$seconds" "$@"
  if [[ $BUILDISH_TEST_LAST_STATUS == 124 || $BUILDISH_TEST_LAST_STATUS == 137 ]]; then
    test_fail "$label exceeded ${seconds}s"
    return
  fi
  [[ $BUILDISH_TEST_LAST_STATUS != 0 ]] || test_fail "$label unexpectedly succeeded"
}

expect_timeout() {
  local label=$1 seconds=$2
  shift 2
  run_bounded "$label" "$seconds" "$@"
  [[ $BUILDISH_TEST_LAST_STATUS == 124 || $BUILDISH_TEST_LAST_STATUS == 137 ]] ||
    test_fail "$label exited $BUILDISH_TEST_LAST_STATUS instead of timing out"
}
