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

# Installer-focused scenarios for tests/integration.sh. The entrypoint sources
# this after the shared helper libraries.

# An isolated installation commit is the rollback boundary documented for
# adopters. Reverting it must reproduce the exact pre-install Git tree.
exercise_installer_git_revert_rollback() {
  source_project_dir=$1
  project_dir=$2
  installer_kind=$3

  log "exercising $installer_kind installer Git-revert rollback in '$project_dir'"
  copy_project_fixture "$source_project_dir" "$project_dir"
  git -C "$project_dir" init -q
  git -C "$project_dir" add --all
  git -C "$project_dir" -c user.name=Buildish-Test -c user.email=buildish-test@example.invalid commit -qm 'pre-install state'
  baseline_tree=$(git -C "$project_dir" rev-parse 'HEAD^{tree}')

  "run_${installer_kind}_installer_capture" "$project_dir"
  assert_last_command_succeeded "$installer_kind installer failed while preparing the rollback scenario."
  git -C "$project_dir" add --all
  if git -C "$project_dir" diff --cached --quiet; then
    fail "$installer_kind installer produced no changes for the rollback scenario."
  fi
  git -C "$project_dir" -c user.name=Buildish-Test -c user.email=buildish-test@example.invalid commit -qm 'install no-gradle-wrapper-jar helper'
  installation_commit=$(git -C "$project_dir" rev-parse HEAD)

  git -C "$project_dir" -c user.name=Buildish-Test -c user.email=buildish-test@example.invalid revert --no-edit "$installation_commit" >/dev/null
  reverted_tree=$(git -C "$project_dir" rev-parse 'HEAD^{tree}')
  [ "$reverted_tree" = "$baseline_tree" ] ||
    fail "$installer_kind installer rollback did not reproduce the pre-install Git tree."
  [ -z "$(git -C "$project_dir" status --porcelain)" ] ||
    fail "$installer_kind installer rollback left uncommitted project changes."
}

# Keep the reviewed-install examples aligned with this standalone repository's
# actual root-level installers rather than the former monorepo-only tools path.
exercise_standalone_installation_documentation_contract() {
  docs_path=$TOOL_DIR/docs/_index.md

  log 'checking standalone reviewed-install documentation contract'
  if grep -Fq './tools/buildish-no-gradle-wrapper-jar/install.' "$docs_path"; then
    fail 'reviewed-install docs still contain the former monorepo-only installer path.'
  fi
  grep -Fq 'bash "$tool_dir/install.sh" --trusted-source-dir "$tool_dir" "$project_dir"' "$docs_path" ||
    fail 'reviewed-install docs do not show the standalone POSIX installer contract.'
  grep -Fq '"$ToolDirectory\install.ps1" --trusted-source-dir $ToolDirectory $ProjectDirectory' "$docs_path" ||
    fail 'reviewed-install docs do not show the standalone PowerShell installer contract.'
  grep -Fq 'buildishWrapperJarSha256Sum=<reviewed lowercase 64-character Wrapper JAR SHA-256>' "$docs_path" ||
    fail 'reviewed-install docs do not describe the required project-owned wrapper-JAR digest pin.'
  grep -Fq 'sh install.sh --help' "$docs_path" ||
    fail 'reviewed-install docs do not expose the non-mutating POSIX help command.'
  grep -Fq 'powershell.exe -File .\install.ps1 --help' "$docs_path" ||
    fail 'reviewed-install docs do not expose the Windows PowerShell help command.'
  grep -Fq 'git revert <installation-commit>' "$docs_path" ||
    fail 'reviewed-install docs do not show the tested Git-revert rollback contract.'
  grep -Fq '### Cold and offline behavior' "$docs_path" ||
    fail 'reviewed-install docs do not explain cold and offline behavior.'
  grep -Fq '`gradlew.bat` invokes `powershell.exe` by name' "$docs_path" ||
    fail 'reviewed-install docs do not distinguish the gradlew.bat Windows PowerShell requirement from pwsh.'
}

# Exercise the shared output normalizer itself so future assertion cleanups do
# not regress either the PowerShell or plain-Linux output contracts.
exercise_output_normalization_contract() {
  output_file=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-test.XXXXXX")

  log 'checking captured-output normalization contract'
  cat >"$output_file" <<'EOF'
Exception: /tmp/bootstrap-install.ps1:47
Line |
  47 |  throw 'This checked-in bootstrap-install.ps1 still contains unreplace …
     |  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     | This checked-in bootstrap-install.ps1 still contains unreplaced release
     | placeholders. Use a release-generated bootstrap-install.ps1 or the
     | reviewed local-copy/manual-verification flow.
EOF
  store_captured_output_from_file "$output_file"
  assert_last_output_contains 'release placeholders' 'normalized PowerShell stderr did not collapse wrapped message fragments into one searchable sentence.'
  [ "$CAPTURED_OUTPUT" != "$CAPTURED_OUTPUT_NORMALIZED" ] || fail 'PowerShell stderr normalization did not remove the presentation-only render block.'

  python3 - <<'PY' "$output_file"
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(
    b'\x1b[31;1mWrite-Error: /tmp/buildish-no-gradle-wrapper-jar.ps1:708\x1b[0m\n'
    b'\x1b[31;1mLine |\x1b[0m\n'
    b'\x1b[31;1m 708 |  \xe2\x80\xa6 Write-Error "buildish-no-gradle-wrapper-jar: $($_.Exception.Message)"\x1b[0m\n'
    b'\x1b[31;1m     |                                                   ~~~~~~~~~~~~~~~~~~~~\x1b[0m\n'
    b'\x1b[31;1m     | buildish-no-gradle-wrapper-jar: wrapper checksum must not be a symbolic\x1b[0m\n'
    b'\x1b[31;1m     | link:\x1b[0m\n'
    b"\x1b[31;1m     | '/tmp/gradle-wrapper-8.14.4.sha256'.\x1b[0m\n"
)
PY
  store_captured_output_from_file "$output_file"
  assert_last_output_contains 'wrapper checksum must not be a symbolic link:' 'normalized PowerShell Write-Error stderr did not collapse wrapped message fragments into one searchable sentence when ANSI terminal sequences were present.'
  assert_last_output_not_contains 'Line |' 'normalized PowerShell Write-Error stderr still contained the presentation-only render block header.'

  cat >"$output_file" <<'EOF'
plain linux stderr line
EOF
  store_captured_output_from_file "$output_file"
  [ "$CAPTURED_OUTPUT" = "$CAPTURED_OUTPUT_NORMALIZED" ] || fail 'Linux/plain stderr should be left unchanged by captured-output normalization.'

  rm -f "$output_file"
}

# Exercise installer failure when gradle-wrapper.properties is missing, because
# patching without wrapper metadata would leave the project in an unknown state.
exercise_installer_missing_properties_failure() {
  project_dir=$1
  installer_kind=$2

  log "exercising $installer_kind installer missing-properties failure in '$project_dir'"
  gradle_init_fixture "$project_dir"
  rm -f "$project_dir/gradle/wrapper/gradle-wrapper.properties"

  "run_${installer_kind}_installer_capture" "$project_dir"
  assert_last_command_failed "$installer_kind installer unexpectedly succeeded without gradle-wrapper.properties."
  assert_last_output_contains 'Gradle wrapper properties file was not found' "$installer_kind installer failure output did not mention the missing gradle-wrapper.properties file."
}

# Exercise the installer CLI guard that requires an explicit trusted source dir
# before helper files are copied into a project.
exercise_installer_requires_trusted_source_dir_failure() {
  project_dir=$1
  installer_kind=$2

  log "exercising $installer_kind installer missing --trusted-source-dir failure in '$project_dir'"
  gradle_init_fixture "$project_dir"

  case "$installer_kind" in
    posix)
      run_and_capture sh "$TOOL_DIR/install.sh" "$project_dir"
      ;;
    powershell)
      run_and_capture pwsh -NoLogo -NoProfile -File "$TOOL_DIR/install.ps1" "$project_dir"
      ;;
    *)
      fail "unknown installer kind '$installer_kind'"
      ;;
  esac

  assert_last_command_failed "$installer_kind installer unexpectedly succeeded without --trusted-source-dir."
  assert_last_output_contains 'trusted-source-dir is required' "$installer_kind installer failure output did not explain that --trusted-source-dir is mandatory."
}

# The installer must reject projects that have not established the reviewed
# version-to-wrapper-JAR binding before it removes the generated JAR or patches
# launchers.
exercise_installer_requires_wrapper_jar_pin() {
  project_dir=$1
  installer_kind=$2
  properties_path=$project_dir/gradle/wrapper/gradle-wrapper.properties

  log "exercising $installer_kind installer missing wrapper-JAR pin failure in '$project_dir'"
  gradle_init_fixture "$project_dir"
  remove_wrapper_property "$properties_path" buildishWrapperJarSha256Sum

  "run_${installer_kind}_installer_capture" "$project_dir"
  assert_last_command_failed "$installer_kind installer unexpectedly succeeded without buildishWrapperJarSha256Sum."
  assert_last_output_contains 'missing the required buildishWrapperJarSha256Sum entry' "$installer_kind installer failure did not explain the required wrapper-JAR pin."
  [ -f "$project_dir/gradle/wrapper/gradle-wrapper.jar" ] || fail "$installer_kind installer removed gradle-wrapper.jar before validating the required wrapper-JAR pin."
  assert_helper_files_absent "$project_dir"
}

# Exercise the documented current-directory default with the former PowerShell-
# only environment fallback set, so inherited process state cannot redirect an
# installation when the caller omits the optional positional target.
exercise_powershell_installer_ignores_target_environment_variable() {
  current_project_dir=$1
  environment_project_dir=$2

  log "exercising PowerShell installer current-directory default in '$current_project_dir'"
  gradle_init_fixture "$current_project_dir"
  cp -R "$current_project_dir" "$environment_project_dir"

  output_file=$(mktemp "${TMPDIR:-/tmp}/buildish-no-gradle-wrapper-jar-test.XXXXXX")
  set +e
  (
    cd "$current_project_dir"
    BUILDISH_NO_GRADLE_WRAPPER_JAR_TARGET_DIR=$environment_project_dir \
      pwsh -NoLogo -NoProfile -File "$TOOL_DIR/install.ps1" --trusted-source-dir "$TOOL_DIR"
  ) >"$output_file" 2>&1
  CAPTURED_STATUS=$?
  set -e
  store_captured_output_from_file "$output_file"
  rm -f "$output_file"

  assert_last_command_succeeded 'PowerShell installer failed when using the current-directory target default.'
  assert_helper_files "$current_project_dir"
  assert_helper_files_absent "$environment_project_dir"
  [ -e "$environment_project_dir/gradle/wrapper/gradle-wrapper.jar" ] || fail 'PowerShell installer followed BUILDISH_NO_GRADLE_WRAPPER_JAR_TARGET_DIR and modified the wrong project.'
}

# Run each installer repeatedly against an already patched CRLF batch launcher.
# This catches logical-line checks that accidentally include the carriage return
# and append another helper block on every installation.
exercise_installer_crlf_idempotence() {
  source_project_dir=$1
  project_dir=$2
  installer_kind=$3
  gradlew_bat_path=$project_dir/gradlew.bat
  first_install_snapshot=$project_dir/gradlew.bat.after-first-install

  log "exercising $installer_kind installer CRLF idempotence in '$project_dir'"
  copy_project_fixture "$source_project_dir" "$project_dir"
  python3 - <<'PY' "$gradlew_bat_path"
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
path.write_bytes(data)
PY

  "run_${installer_kind}_installer_capture" "$project_dir"
  assert_last_command_succeeded "$installer_kind installer failed on the first CRLF idempotency run."
  cp "$gradlew_bat_path" "$first_install_snapshot"

  "run_${installer_kind}_installer_capture" "$project_dir"
  assert_last_command_succeeded "$installer_kind installer failed on the second CRLF idempotency run."
  cmp -s "$first_install_snapshot" "$gradlew_bat_path" || fail "$installer_kind installer changed gradlew.bat on its second CRLF installation."
  assert_file_exact_line_count "$gradlew_bat_path" 'set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=%*' 1 "$installer_kind installer duplicated the helper block in a CRLF gradlew.bat."
  rm -f "$first_install_snapshot"
}

# Preserve the complete existing mode rather than collapsing launchers and
# .gitignore to the mode chosen for an installer temporary file.
exercise_posix_installer_mode_preservation() {
  source_project_dir=$1
  project_dir=$2

  log "exercising POSIX installer mode preservation in '$project_dir'"
  copy_project_fixture "$source_project_dir" "$project_dir"
  chmod 0711 "$project_dir/gradlew"
  chmod 0640 "$project_dir/gradlew.bat"
  chmod 0644 "$project_dir/.gitignore"

  run_posix_installer_capture "$project_dir"
  assert_last_command_succeeded 'POSIX installer failed during the mode-preservation scenario.'
  python3 - <<'PY' "$project_dir/gradlew" "$project_dir/gradlew.bat" "$project_dir/.gitignore" || fail 'POSIX installer did not preserve launcher or .gitignore modes.'
from pathlib import Path
import stat
import sys

expected = (0o711, 0o640, 0o644)
actual = tuple(stat.S_IMODE(Path(path).stat().st_mode) for path in sys.argv[1:])
raise SystemExit(0 if actual == expected else 1)
PY
}

# Force a late launcher-shape validation failure and prove that helpers, the
# wrapper JAR, launchers, and .gitignore remain byte-for-byte unchanged.
exercise_installer_unsupported_launcher_transaction() {
  source_project_dir=$1
  project_dir=$2
  installer_kind=$3
  snapshot_dir=$project_dir.before-install

  log "exercising $installer_kind installer unchanged-on-failure transaction in '$project_dir'"
  copy_project_fixture "$source_project_dir" "$project_dir"
  python3 - <<'PY' "$project_dir/gradlew.bat"
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(
    b'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi\r\n'
    b'unsupported-gradlew-bat-execute-line\r\n'
)
PY
  copy_project_fixture "$project_dir" "$snapshot_dir"

  "run_${installer_kind}_installer_capture" "$project_dir"
  assert_last_command_failed "$installer_kind installer unexpectedly accepted an unsupported gradlew.bat execute line."
  assert_last_output_contains 'Unable to apply the expected update to gradlew.bat' "$installer_kind installer failure did not identify the unsupported gradlew.bat shape."
  diff -r "$snapshot_dir" "$project_dir" >/dev/null || fail "$installer_kind installer changed the project despite failing launcher preflight."
}

# Deny the final wrapper-JAR backup after the other managed destinations have
# already been moved into the transaction. This exercises actual rollback, not
# only the complete-output preflight path above.
exercise_installer_late_backup_rollback() {
  source_project_dir=$1
  project_dir=$2
  installer_kind=$3
  snapshot_dir=$project_dir.before-install
  wrapper_dir=$project_dir/gradle/wrapper

  log "exercising $installer_kind installer late-backup rollback in '$project_dir'"
  copy_project_fixture "$source_project_dir" "$project_dir"
  [ -f "$wrapper_dir/gradle-wrapper.jar" ] || fail "$installer_kind rollback fixture is missing gradle-wrapper.jar."
  chmod 0555 "$wrapper_dir"
  copy_project_fixture "$project_dir" "$snapshot_dir"

  "run_${installer_kind}_installer_capture" "$project_dir"
  chmod 0755 "$wrapper_dir" "$snapshot_dir/gradle/wrapper"
  assert_last_command_failed "$installer_kind installer unexpectedly succeeded when the wrapper-JAR backup was denied."
  diff -r "$snapshot_dir" "$project_dir" >/dev/null || fail "$installer_kind installer did not restore the complete project after a late backup failure."
  if find "$project_dir" -maxdepth 1 -type d -name '.buildish-no-gradle-wrapper-jar-transaction.*' | grep -q .; then
    fail "$installer_kind installer left a transaction directory after rollback."
  fi

}

# Redirect the managed Gradle directory through a symlink and prove both
# installers reject it before touching the external directory.
exercise_installer_managed_ancestor_link_rejection() {
  source_project_dir=$1
  project_dir=$2
  installer_kind=$3
  external_gradle_dir=$project_dir.external-gradle
  external_snapshot_dir=$project_dir.external-gradle-before-install

  log "exercising $installer_kind installer managed ancestor-link rejection in '$project_dir'"
  copy_project_fixture "$source_project_dir" "$project_dir"
  mv "$project_dir/gradle" "$external_gradle_dir"
  ln -s "$external_gradle_dir" "$project_dir/gradle"
  copy_project_fixture "$external_gradle_dir" "$external_snapshot_dir"

  "run_${installer_kind}_installer_capture" "$project_dir"
  assert_last_command_failed "$installer_kind installer unexpectedly followed a symlinked Gradle directory."
  assert_last_output_contains 'Gradle directory must not be a symbolic link' "$installer_kind installer failure did not identify the symlinked Gradle directory."
  diff -r "$external_snapshot_dir" "$external_gradle_dir" >/dev/null || fail "$installer_kind installer modified files through a symlinked Gradle directory."
}

# A managed destination that is a directory must be rejected during preflight.
# Prove that neither installer removes the directory or mutates any other
# project file while reporting the type collision.
exercise_installer_managed_file_directory_rejection() {
  source_project_dir=$1
  project_dir=$2
  installer_kind=$3
  managed_path=$project_dir/gradle/buildish-no-gradle-wrapper-jar.ps1
  snapshot_dir=$project_dir.before-install

  log "exercising $installer_kind installer managed-file directory rejection in '$project_dir'"
  copy_project_fixture "$source_project_dir" "$project_dir"
  [ -f "$managed_path" ] || fail "$installer_kind directory-collision fixture is missing the installed PowerShell helper."
  rm -f "$managed_path"
  mkdir "$managed_path"
  copy_project_fixture "$project_dir" "$snapshot_dir"

  "run_${installer_kind}_installer_capture" "$project_dir"
  assert_last_command_failed "$installer_kind installer unexpectedly replaced a managed-file directory."
  assert_last_output_contains 'PowerShell helper script must be a regular file' "$installer_kind installer failure did not identify the managed-file directory collision."
  diff -r "$snapshot_dir" "$project_dir" >/dev/null || fail "$installer_kind installer changed the project despite rejecting a managed-file directory."
}

# Exercise the unsafe-dev installer acknowledgement guard so the dangerous flow
# cannot run without an explicit opt-in flag.
exercise_unsafe_dev_installer_requires_acknowledgement_failure() {
  project_dir=$1
  installer_kind=$2

  log "exercising $installer_kind unsafe dev installer missing-acknowledgement failure in '$project_dir'"
  gradle_init_fixture "$project_dir"

  case "$installer_kind" in
    posix)
      run_and_capture sh "$TOOL_DIR/unsafe-dev-install.sh" "$project_dir"
      ;;
    powershell)
      run_and_capture pwsh -NoLogo -NoProfile -File "$TOOL_DIR/unsafe-dev-install.ps1" "$project_dir"
      ;;
    *)
      fail "unknown installer kind '$installer_kind'"
      ;;
  esac

  assert_last_command_failed "$installer_kind unsafe dev installer unexpectedly succeeded without the unsafe acknowledgement flag."
  assert_last_output_contains 'yes-i-know-this-is-unsafe' "$installer_kind unsafe dev installer failure output did not mention the mandatory unsafe acknowledgement flag."
}

# Exercise the unsafe-dev installer CI barrier so the intentionally unsafe flow
# refuses to run in automated environments.
exercise_unsafe_dev_installer_ci_barrier_failure() {
  project_dir=$1
  installer_kind=$2

  log "exercising $installer_kind unsafe dev installer CI barrier in '$project_dir'"
  gradle_init_fixture "$project_dir"

  case "$installer_kind" in
    posix)
      run_and_capture env CI=true sh "$TOOL_DIR/unsafe-dev-install.sh" --yes-i-know-this-is-unsafe "$project_dir"
      ;;
    powershell)
      run_and_capture env CI=true pwsh -NoLogo -NoProfile -File "$TOOL_DIR/unsafe-dev-install.ps1" --yes-i-know-this-is-unsafe "$project_dir"
      ;;
    *)
      fail "unknown installer kind '$installer_kind'"
      ;;
  esac

  assert_last_command_failed "$installer_kind unsafe dev installer unexpectedly ran in a CI-marked environment."
  assert_last_output_contains 'not suitable for CI environments' "$installer_kind unsafe dev installer failure output did not mention that the script is not suitable for CI environments."
}

# Exercise the unsafe-dev installer happy path on a localhost mirror so the
# warning banner and helper installation still get a smoke test outside CI.
exercise_unsafe_dev_installer_success() {
  project_dir=$1
  installer_kind=$2

  if current_environment_looks_like_ci; then
    log "skipping $installer_kind unsafe dev installer success path because the current environment already looks like CI."
    return 0
  fi

  log "exercising $installer_kind unsafe dev installer success path in '$project_dir'"
  gradle_init_fixture "$project_dir"
  start_static_http_server "$TOOL_DIR"

  case "$installer_kind" in
    posix)
      run_posix_unsafe_dev_installer_capture "$project_dir" BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL="http://127.0.0.1:$TEST_HTTP_SERVER_PORT"
      ;;
    powershell)
      run_powershell_unsafe_dev_installer_capture "$project_dir" BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL="http://127.0.0.1:$TEST_HTTP_SERVER_PORT"
      ;;
    *)
      stop_test_http_server
      fail "unknown installer kind '$installer_kind'"
      ;;
  esac

  stop_test_http_server
  assert_last_command_succeeded "$installer_kind unsafe dev installer failed during the happy-path smoke test."
  assert_last_output_contains 'downloads and executes unverified content' "$installer_kind unsafe dev installer did not emit the loud unsafe warning banner."
  assert_helper_files "$project_dir"
}

# Choose a known-good target that differs from both the installed version and a
# version reserved by another fixture. A no-op Wrapper task cannot exercise the
# version-change logic, and reusing the replay version would collapse that
# fixture's cross-version invariant later in the suite.
select_distinct_wrapper_target_version() {
  local initial_version=$1
  local preferred_version=$2
  local fallback_version=$3
  local reserved_version=$4

  if [ "$preferred_version" != "$initial_version" ] && [ "$preferred_version" != "$reserved_version" ]; then
    printf '%s\n' "$preferred_version"
  elif [ "$fallback_version" != "$initial_version" ] && [ "$fallback_version" != "$reserved_version" ]; then
    printf '%s\n' "$fallback_version"
  else
    fail "wrapper update test requires a target distinct from initial Gradle '$initial_version' and reserved Gradle '$reserved_version'."
  fi
}

# Lock in the preferred, installed-version collision, and reserved-version
# collision branches without downloading distributions.
exercise_wrapper_target_version_selection() {
  local selected_version
  selected_version=$(select_distinct_wrapper_target_version 9.4.1 9.6.1 9.3.0 8.14)
  [ "$selected_version" = 9.6.1 ] ||
    fail "wrapper update target selection did not keep the usable preferred version (selected '$selected_version')."
  selected_version=$(select_distinct_wrapper_target_version 9.6.1 9.6.1 9.4.1 8.14)
  [ "$selected_version" = 9.4.1 ] ||
    fail "wrapper update target selection did not avoid a no-op version change (selected '$selected_version')."
  selected_version=$(select_distinct_wrapper_target_version 9.4.1 8.14 9.6.1 8.14)
  [ "$selected_version" = 9.6.1 ] ||
    fail "wrapper update target selection reused the reserved replay version (selected '$selected_version')."
}

# Exercise the end-to-end POSIX installer flow, then change or regenerate the
# wrapper at the selected target version and verify the helper still works.
exercise_wrapper_update_to_version() {
  project_dir=$1
  bootstrap_gradle_version=$2
  preferred_target_version=$3
  fallback_target_version=${4:-}
  reserved_target_version=${5:-}

  log "starting wrapper exercise in '$project_dir'"
  gradle_init_fixture "$project_dir" "$bootstrap_gradle_version"
  run_posix_installer_capture "$project_dir"
  assert_last_command_succeeded 'POSIX installer failed during the wrapper exercise.'
  assert_installer_distribution_sha_warning_output 'POSIX installer'
  [ ! -e "$project_dir/gradle/wrapper/gradle-wrapper.jar" ] || fail 'install.sh should remove the existing gradle-wrapper.jar.'
  assert_helper_files "$project_dir"
  assert_launcher_patches "$project_dir"
  assert_gitignore_updates "$project_dir"

  log "verifying freshly installed helper for '$project_dir'"
  run_wrapper "$project_dir" help
  initial_version=$(extract_gradle_version "$project_dir")
  [ -n "$initial_version" ] || fail 'unable to extract the initial Gradle version after install.sh.'
  if [ -n "$fallback_target_version" ]; then
    target_version=$(select_distinct_wrapper_target_version \
      "$initial_version" \
      "$preferred_target_version" \
      "$fallback_target_version" \
      "$reserved_target_version")
  else
    target_version=$preferred_target_version
  fi
  assert_metadata_for_version "$project_dir" "$initial_version"
  properties_path=$project_dir/gradle/wrapper/gradle-wrapper.properties
  previous_wrapper_pin=$(sed -n 's/^buildishWrapperJarSha256Sum=//p' "$properties_path")

  if [ "$target_version" = "$initial_version" ]; then
    log "regenerating wrapper in '$project_dir' at Gradle '$target_version'"
  else
    log "changing wrapper in '$project_dir' from '$initial_version' to '$target_version'"
  fi
  run_wrapper_capture "$project_dir" wrapper --gradle-version "$target_version" --distribution-type bin
  assert_last_command_succeeded 'Gradle Wrapper task failed during the wrapper exercise.'
  assert_init_distribution_sha_warning_output 'Gradle init script'
  if [ "$target_version" = "$initial_version" ]; then
    assert_last_output_not_contains 'was only preserved; it was not recalculated' 'Gradle init script emitted the version-change pin warning during a same-version regeneration.'
  else
    assert_last_output_contains 'was only preserved; it was not recalculated' 'Gradle init script did not explain that a version change requires a reviewed wrapper-JAR pin update.'
  fi
  updated_version=$(extract_gradle_version "$project_dir")
  [ "$updated_version" = "$target_version" ] || fail "expected updated Gradle version '$target_version' but found '$updated_version'."
  preserved_wrapper_pin=$(sed -n 's/^buildishWrapperJarSha256Sum=//p' "$properties_path")
  [ "$preserved_wrapper_pin" = "$previous_wrapper_pin" ] || fail 'Gradle init script did not preserve the reviewed wrapper-JAR pin across Wrapper task property regeneration.'
  if [ "$target_version" != "$initial_version" ]; then
    updated_wrapper_pin=$(fetch_gradle_wrapper_checksum "$updated_version")
    set_wrapper_property "$properties_path" buildishWrapperJarSha256Sum "$updated_wrapper_pin"
    run_wrapper_capture "$project_dir" wrapper --gradle-version "$target_version" --distribution-type bin
    assert_last_command_succeeded 'Second Gradle Wrapper task failed after installing the reviewed wrapper-JAR pin.'
  fi
  assert_launcher_patches "$project_dir"

  log "verifying helper after the Wrapper task for '$project_dir' at Gradle '$updated_version'"
  run_wrapper "$project_dir" help
  assert_metadata_for_version "$project_dir" "$updated_version"
}

# Run the default PowerShell installer smoke path and verify the installed
# helper/launcher artifacts behave like the POSIX path.
run_powershell_installer_flow() {
  project_dir=$1
  log "running default PowerShell installer flow in '$project_dir'"
  gradle_init_fixture "$project_dir"
  run_powershell_installer_capture "$project_dir"
  assert_last_command_succeeded 'PowerShell installer failed during the default integration flow.'
  assert_installer_distribution_sha_warning_output 'PowerShell installer'
  [ ! -e "$project_dir/gradle/wrapper/gradle-wrapper.jar" ] || fail 'install.ps1 should remove the existing gradle-wrapper.jar.'
  assert_helper_files "$project_dir"
  assert_launcher_patches "$project_dir"
  assert_gitignore_updates "$project_dir"

  log "verifying PowerShell-installed helper for '$project_dir'"
  run_wrapper "$project_dir" help
  installed_version=$(extract_gradle_version "$project_dir")
  [ -n "$installed_version" ] || fail 'unable to extract the installed Gradle version after install.ps1.'
  assert_metadata_for_version "$project_dir" "$installed_version"
}

# Run the installer-centric portion of the default integration suite, including
# the shared output-normalization contract, both installers, and unsafe-dev
# guardrail checks.
run_installer_suite() {
  test_root=$1
  posix_project_dir=$2
  powershell_project_dir=$3

  log "starting installer suite (test_root='$test_root')"
  exercise_standalone_installation_documentation_contract
  exercise_output_normalization_contract
  exercise_wrapper_target_version_selection
  exercise_wrapper_update_to_version \
    "$posix_project_dir" \
    '' \
    "$UPDATED_GRADLE_VERSION" \
    "$WRAPPER_UPDATE_FALLBACK_VERSION" \
    "$TWO_SEGMENT_GRADLE_VERSION"
  run_powershell_installer_flow "$powershell_project_dir"
  exercise_installer_missing_properties_failure "$test_root/posix-installer-missing-properties" posix
  exercise_installer_missing_properties_failure "$test_root/powershell-installer-missing-properties" powershell
  exercise_installer_requires_trusted_source_dir_failure "$test_root/posix-installer-requires-trusted-source-dir" posix
  exercise_installer_requires_trusted_source_dir_failure "$test_root/powershell-installer-requires-trusted-source-dir" powershell
  exercise_installer_requires_wrapper_jar_pin "$test_root/posix-installer-requires-wrapper-pin" posix
  exercise_installer_requires_wrapper_jar_pin "$test_root/powershell-installer-requires-wrapper-pin" powershell
  exercise_powershell_installer_ignores_target_environment_variable "$test_root/powershell-installer-current-directory" "$test_root/powershell-installer-environment-directory"
  exercise_installer_crlf_idempotence "$powershell_project_dir" "$test_root/posix-installer-crlf-idempotence" posix
  exercise_installer_crlf_idempotence "$powershell_project_dir" "$test_root/powershell-installer-crlf-idempotence" powershell
  exercise_posix_installer_mode_preservation "$powershell_project_dir" "$test_root/posix-installer-mode-preservation"
  exercise_installer_unsupported_launcher_transaction "$powershell_project_dir" "$test_root/posix-installer-transaction-failure" posix
  exercise_installer_unsupported_launcher_transaction "$powershell_project_dir" "$test_root/powershell-installer-transaction-failure" powershell
  exercise_installer_late_backup_rollback "$powershell_project_dir" "$test_root/posix-installer-rollback" posix
  exercise_installer_managed_ancestor_link_rejection "$powershell_project_dir" "$test_root/posix-installer-ancestor-link" posix
  exercise_installer_managed_ancestor_link_rejection "$powershell_project_dir" "$test_root/powershell-installer-ancestor-link" powershell
  exercise_installer_managed_file_directory_rejection "$powershell_project_dir" "$test_root/posix-installer-directory-collision" posix
  exercise_installer_managed_file_directory_rejection "$powershell_project_dir" "$test_root/powershell-installer-directory-collision" powershell
  gradle_init_fixture "$test_root/installer-rollback-source"
  exercise_installer_git_revert_rollback "$test_root/installer-rollback-source" "$test_root/posix-installer-git-rollback" posix
  exercise_installer_git_revert_rollback "$test_root/installer-rollback-source" "$test_root/powershell-installer-git-rollback" powershell
  exercise_unsafe_dev_installer_requires_acknowledgement_failure "$test_root/posix-unsafe-dev-requires-ack" posix
  exercise_unsafe_dev_installer_requires_acknowledgement_failure "$test_root/powershell-unsafe-dev-requires-ack" powershell
  exercise_unsafe_dev_installer_ci_barrier_failure "$test_root/posix-unsafe-dev-ci-barrier" posix
  exercise_unsafe_dev_installer_ci_barrier_failure "$test_root/powershell-unsafe-dev-ci-barrier" powershell
  exercise_unsafe_dev_installer_success "$test_root/posix-unsafe-dev-success" posix
  exercise_unsafe_dev_installer_success "$test_root/powershell-unsafe-dev-success" powershell
}
