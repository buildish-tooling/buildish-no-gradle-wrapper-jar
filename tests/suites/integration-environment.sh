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

# Environment and CLI contracts for tests/integration.sh. The entrypoint
# sources this after the shared helper libraries.

# Prove that ordinary tool discovery honors an explicitly supplied Gradle on
# PATH without executing a user's SDKMAN startup script.
exercise_default_tool_lookup_ignores_sdkman_init() {
  scenario_dir=$1
  fake_home=$scenario_dir/home
  fake_bin=$scenario_dir/bin
  marker_path=$scenario_dir/sdkman-init-sourced
  missing_gradle_output=$scenario_dir/missing-gradle-output

  log 'checking default Gradle PATH precedence over SDKMAN initialization'
  mkdir -p "$fake_home/.sdkman/bin" "$fake_bin" "$scenario_dir/build" "$scenario_dir/empty-bin"
  cat > "$fake_bin/gradle" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/gradle"
  cat > "$fake_home/.sdkman/bin/sdkman-init.sh" <<'EOF'
: > "$SDKMAN_TEST_MARKER"
sdk() { :; }
EOF

  (
    HOME=$fake_home
    BUILD_DIR=$scenario_dir/build
    SDKMAN_TEST_MARKER=$marker_path
    PATH=$fake_bin:$PATH
    export HOME BUILD_DIR SDKMAN_TEST_MARKER PATH
    unset -f sdk >/dev/null 2>&1 || true
    require_base_commands
    [ ! -e "$marker_path" ] || fail 'ordinary tool discovery sourced the SDKMAN init script despite Gradle being available on PATH.'
  )

  if (
    HOME=$fake_home
    BUILD_DIR=$scenario_dir/build
    SDKMAN_TEST_MARKER=$marker_path
    PATH=$scenario_dir/empty-bin
    export HOME BUILD_DIR SDKMAN_TEST_MARKER PATH
    unset -f gradle sdk >/dev/null 2>&1 || true
    require_base_commands
  ) >"$missing_gradle_output" 2>&1; then
    fail 'ordinary tool discovery unexpectedly succeeded without Gradle on PATH.'
  fi
  [ ! -e "$marker_path" ] || fail 'ordinary tool discovery sourced the SDKMAN init script when Gradle was missing from PATH.'
  grep -Fq "required command 'gradle' is not available on PATH" "$missing_gradle_output" ||
    fail 'missing-Gradle failure did not explain the PATH prerequisite.'

  (
    HOME=$fake_home
    SDKMAN_TEST_MARKER=$marker_path
    PATH=$scenario_dir/empty-bin
    export HOME SDKMAN_TEST_MARKER PATH
    unset -f sdk >/dev/null 2>&1 || true
    source_sdkman_environment
    command -v sdk >/dev/null 2>&1 || fail 'explicit SDKMAN initialization did not expose the sdk command.'
  )
  [ -e "$marker_path" ] || fail 'explicit SDKMAN initialization did not source the configured init script.'
}

assert_help_command() {
  entrypoint_label=$1
  expected_usage=$2
  shift 2

  run_and_capture "$@"
  assert_last_command_succeeded "$entrypoint_label help unexpectedly failed."
  assert_last_output_contains "$expected_usage" "$entrypoint_label help did not show its usage contract."
}

# Every installation entrypoint exposes both common help flags before trust,
# acknowledgement, placeholder, CI, filesystem, or network validation.
exercise_install_entrypoint_help_contracts() {
  log 'checking installer and bootstrap help contracts'

  for help_option in -h --help; do
    assert_help_command 'POSIX local installer' 'Usage: install.sh' \
      sh "$TOOL_DIR/install.sh" "$help_option"
    assert_help_command 'PowerShell local installer' 'Usage: install.ps1' \
      pwsh -NoLogo -NoProfile -File "$TOOL_DIR/install.ps1" "$help_option"
    assert_help_command 'POSIX release bootstrap' 'Usage: bootstrap-install.sh' \
      sh "$TOOL_DIR/bootstrap-install.sh" "$help_option"
    assert_help_command 'PowerShell release bootstrap' 'Usage: bootstrap-install.ps1' \
      pwsh -NoLogo -NoProfile -File "$TOOL_DIR/bootstrap-install.ps1" "$help_option"
    assert_help_command 'POSIX unsafe development installer' 'Usage: unsafe-dev-install.sh' \
      env CI=1 BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL=http://127.0.0.1:1 sh "$TOOL_DIR/unsafe-dev-install.sh" "$help_option"
    assert_help_command 'PowerShell unsafe development installer' 'Usage: unsafe-dev-install.ps1' \
      env CI=1 BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL=http://127.0.0.1:1 pwsh -NoLogo -NoProfile -File "$TOOL_DIR/unsafe-dev-install.ps1" "$help_option"
  done
}

run_environment_contract_suite() {
  environment_contract_root=$1

  log "starting environment and CLI contract suite (test_root='$environment_contract_root')"
  exercise_default_tool_lookup_ignores_sdkman_init "$environment_contract_root/default-tool-lookup"
  exercise_install_entrypoint_help_contracts
}
