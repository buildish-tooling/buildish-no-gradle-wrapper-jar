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

set -eu

# POSIX installer for the Buildish no-gradle-wrapper-jar helper tool.
# https://buildish.org/components/no-gradle-wrapper-jar/
#
# The installer assumes it is being run against an existing Gradle project that
# already has `gradlew`, `gradlew.bat`, and `gradle/wrapper/gradle-wrapper.properties`.
# It then:
#   1. stages the helper files into `gradle/`
#   2. removes any checked-in `gradle-wrapper.jar`
#   3. patches `gradlew` and `gradlew.bat` so the helpers run on every launch
#   4. updates `.gitignore` so retained checksum/signature side files stay local
#
# Security / safety properties:
#   * existing symlinks are rejected instead of being followed
#   * file updates go through temporary files and atomic moves where possible
#   * helper files are only staged from a caller-supplied --trusted-source-dir
#     because this installer is not meant to establish trust in downloaded bytes

BUILDISH_TOOL_NAME='buildish-no-gradle-wrapper-jar'
BUILDISH_TRUSTED_SOURCE_DIR=''
BUILDISH_CR=$(printf '\r')

# Consistent installer failure prefix.
buildish_install_fail() {
  echo "${BUILDISH_TOOL_NAME} install: $*" >&2
  exit 1
}

buildish_install_warn() {
  echo "${BUILDISH_TOOL_NAME} install: $*" >&2
}

# Command preflight used before depending on external programs.
buildish_install_require_command() {
  command -v "$1" >/dev/null 2>&1 || buildish_install_fail "Required command '$1' was not found on PATH."
}

# The installer never follows user-controlled symlinks. That keeps patching scoped
# to ordinary files inside the target project and avoids surprising writes.
buildish_install_assert_not_symlink() {
  [ ! -L "$1" ] || buildish_install_fail "$2 must not be a symbolic link: '$1'."
}

# Create temp files alongside the destination so the final move stays on the same
# filesystem and is as atomic as the platform allows.
buildish_install_make_temp() {
  mktemp "$1/.buildish-no-gradle-wrapper-jar-install.XXXXXX"
}

buildish_install_move_temp_file() {
  temp_path=$1
  target_path=$2
  failure_message=$3

  if ! mv -f "$temp_path" "$target_path"; then
    rm -f "$temp_path"
    buildish_install_fail "$failure_message"
  fi
}

# Local-copy variant used by integration tests and verified bootstrap handoff.
# The caller is explicitly trusted to provide already-trusted local files.
buildish_install_copy_to() {
  target_path=$1
  source_path=$2
  label=$3

  [ -f "$source_path" ] || buildish_install_fail "$label source file was not found at '$source_path'."
  buildish_install_assert_not_symlink "$target_path" "$label"
  buildish_install_assert_not_symlink "$source_path" "$label source file"
  temp_path=$(buildish_install_make_temp "$GRADLE_DIR") || buildish_install_fail "Unable to create a temporary file for $label."

  if ! cat "$source_path" > "$temp_path"; then
    rm -f "$temp_path"
    buildish_install_fail "Unable to copy $label from '$source_path'."
  fi

  buildish_install_move_temp_file "$temp_path" "$target_path" "Unable to move $label into '$target_path'."
}

# Stage one helper file from the already-trusted local source directory.
buildish_install_stage_tool_file() {
  target_path=$1
  file_name=$2
  label=$3

  buildish_install_copy_to "$target_path" "$TRUSTED_SOURCE_DIR_ABSOLUTE/$file_name" "$label"
}

# Re-emit a possibly multi-line block using a caller-selected newline style so the
# patched launchers preserve their original LF / CRLF convention.
buildish_install_write_text_with_newlines() {
  text=$1
  newline_kind=$2

  printf '%s' "$text" | while IFS= read -r line || [ -n "$line" ]; do
    case "$newline_kind" in
      crlf) printf '%s\r\n' "$line" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

# Derive the helper-aware batch Java invocation from the generated `%*` argument
# marker so each supported launcher shape only has to be listed once.
buildish_install_patch_batch_execute_line() {
  current_line=$1
  case $current_line in
    *' %*'*) ;;
    *) buildish_install_fail "Unsupported batch execute line shape: '$current_line'." ;;
  esac
  remaining_after_argument_marker=${current_line#*' %*'}
  case $remaining_after_argument_marker in
    *' %*'*) buildish_install_fail "Unsupported batch execute line shape: '$current_line'." ;;
  esac

  patched_line=$(printf '%s\n' "$current_line" | sed 's/ %\*/ %BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS% %*/')
  printf '%s' "$patched_line"
}

# Insert a block after any one of several exact anchor lines, preserving newline
# style and execute bits, and treating the operation as idempotent if the
# inserted first line is already present.
buildish_install_insert_after_any_line() {
  target_path=$1
  insertion_block=$2
  label=$3
  shift 3

  if [ ! -f "$target_path" ]; then
    buildish_install_warn "Skipping missing $label at '$target_path'."
    return 0
  fi

  buildish_install_assert_not_symlink "$target_path" "$label"

  insertion_first_line=$(printf '%s' "$insertion_block" | sed -n '1p')
  if grep -Fqx "$insertion_first_line" "$target_path"; then
    return 0
  fi

  temp_path=$(buildish_install_make_temp "$TARGET_DIR_ABSOLUTE") ||
    buildish_install_fail "Unable to create a temporary file while patching $label."
  was_executable=0
  [ -x "$target_path" ] && was_executable=1
  found_anchor=0

  while IFS= read -r current_line || [ -n "$current_line" ]; do
    normalized_line=$current_line
    case $normalized_line in
      *"$BUILDISH_CR") normalized_line=${normalized_line%"$BUILDISH_CR"} ;;
    esac

    printf '%s\n' "$current_line" >> "$temp_path"
    if [ "$found_anchor" -eq 0 ]; then
      for anchor_line in "$@"; do
        if [ "$normalized_line" = "$anchor_line" ]; then
          found_anchor=1
          case $current_line in
            *"$BUILDISH_CR") buildish_install_write_text_with_newlines "$insertion_block" crlf >> "$temp_path" ;;
            *) buildish_install_write_text_with_newlines "$insertion_block" lf >> "$temp_path" ;;
          esac
          break
        fi
      done
    fi
  done < "$target_path"

  if [ "$found_anchor" -ne 1 ]; then
    rm -f "$temp_path"
    buildish_install_fail "Unable to find the expected insertion point in $label at '$target_path'."
  fi

  if [ "$was_executable" -eq 1 ]; then
    chmod +x "$temp_path"
  fi

  buildish_install_move_temp_file "$temp_path" "$target_path" "Unable to replace patched $label at '$target_path'."
}

# Replace one exact line when present. Missing lines are tolerated here because
# newer Gradle versions may generate slightly different launchers; the installer
# verifies the required patched line afterwards.
buildish_install_replace_exact_line_if_present() {
  target_path=$1
  old_line=$2
  replacement=$3
  label=$4

  if [ ! -f "$target_path" ]; then
    buildish_install_warn "Skipping missing $label at '$target_path'."
    return 0
  fi

  buildish_install_assert_not_symlink "$target_path" "$label"

  replacement_first_line=$(printf '%s' "$replacement" | sed -n '1p')
  if grep -Fqx "$replacement_first_line" "$target_path"; then
    return 0
  fi

  temp_path=$(buildish_install_make_temp "$TARGET_DIR_ABSOLUTE") ||
    buildish_install_fail "Unable to create a temporary file while updating $label."
  was_executable=0
  [ -x "$target_path" ] && was_executable=1
  replaced=0

  while IFS= read -r current_line || [ -n "$current_line" ]; do
    normalized_line=$current_line
    case $normalized_line in
      *"$BUILDISH_CR") normalized_line=${normalized_line%"$BUILDISH_CR"} ;;
    esac

    if [ "$normalized_line" = "$old_line" ]; then
      replaced=1
      case $current_line in
        *"$BUILDISH_CR") buildish_install_write_text_with_newlines "$replacement" crlf >> "$temp_path" ;;
        *) buildish_install_write_text_with_newlines "$replacement" lf >> "$temp_path" ;;
      esac
      continue
    fi

    printf '%s\n' "$current_line" >> "$temp_path"
  done < "$target_path"

  if [ "$replaced" -ne 1 ]; then
    rm -f "$temp_path"
    return 0
  fi

  if [ "$was_executable" -eq 1 ]; then
    chmod +x "$temp_path"
  fi

  buildish_install_move_temp_file "$temp_path" "$target_path" "Unable to replace updated $label at '$target_path'."
}

# Same as above, but accepts any of several supported generated launcher shapes.
buildish_install_assert_any_exact_line_present() {
  target_path=$1
  label=$2
  shift 2

  while IFS= read -r current_line || [ -n "$current_line" ]; do
    case $current_line in
      *"$BUILDISH_CR") current_line=${current_line%"$BUILDISH_CR"} ;;
    esac

    for expected_line in "$@"; do
      if [ "$current_line" = "$expected_line" ]; then
        return 0
      fi
    done
  done < "$target_path"

  buildish_install_fail "Unable to apply the expected update to $label at '$target_path'."
}

# The installer intentionally removes any existing wrapper JAR so subsequent
# `./gradlew` runs must go through the helper's verification / redownload path.
buildish_install_remove_regular_file() {
  target_path=$1
  label=$2

  if [ ! -e "$target_path" ]; then
    return 0
  fi

  buildish_install_assert_not_symlink "$target_path" "$label"
  [ -f "$target_path" ] || buildish_install_fail "$label must be a regular file: '$target_path'."
  rm -f "$target_path" || buildish_install_fail "Unable to remove $label at '$target_path'."
}

# Keep the retained metadata files out of source control by default while leaving
# teams free to commit them if their policy prefers that.
buildish_install_update_gitignore() {
  gitignore_path=$TARGET_DIR_ABSOLUTE/.gitignore
  entry_sha='gradle/wrapper/gradle-wrapper-*.sha256'
  entry_asc='gradle/wrapper/gradle-wrapper-*.asc'
  comment_line='# Added by buildish-no-gradle-wrapper-jar'

  if [ -e "$gitignore_path" ]; then
    buildish_install_assert_not_symlink "$gitignore_path" '.gitignore'
    grep -Fqx "$entry_sha" "$gitignore_path" && has_sha=1 || has_sha=0
    grep -Fqx "$entry_asc" "$gitignore_path" && has_asc=1 || has_asc=0
    grep -Fqx "$comment_line" "$gitignore_path" && has_comment=1 || has_comment=0
  else
    has_sha=0
    has_asc=0
    has_comment=0
  fi

  if [ "$has_sha" -eq 1 ] && [ "$has_asc" -eq 1 ]; then
    return 0
  fi

  temp_path=$(buildish_install_make_temp "$TARGET_DIR_ABSOLUTE") ||
    buildish_install_fail "Unable to create a temporary file while updating .gitignore."

  if [ -f "$gitignore_path" ]; then
    cat "$gitignore_path" > "$temp_path"
    printf '\n' >> "$temp_path"
  fi
  if [ "$has_comment" -eq 0 ]; then
    printf '%s\n' "$comment_line" >> "$temp_path"
  fi
  if [ "$has_sha" -eq 0 ]; then
    printf '%s\n' "$entry_sha" >> "$temp_path"
  fi
  if [ "$has_asc" -eq 0 ]; then
    printf '%s\n' "$entry_asc" >> "$temp_path"
  fi

  buildish_install_move_temp_file "$temp_path" "$gitignore_path" "Unable to update '$gitignore_path'."
}

buildish_install_stage_helper_files() {
  buildish_install_stage_tool_file \
    "$HELPER_SH_PATH" \
    'buildish-no-gradle-wrapper-jar.sh' \
    'POSIX helper script'
  buildish_install_stage_tool_file \
    "$HELPER_PS1_PATH" \
    'buildish-no-gradle-wrapper-jar.ps1' \
    'PowerShell helper script'
  buildish_install_stage_tool_file \
    "$HELPER_INIT_PATH" \
    'buildish-no-gradle-wrapper-jar.init.gradle.kts' \
    'Gradle init script'
}

buildish_install_update_gradlew_bat() {
  buildish_install_replace_exact_line_if_present \
    "$GRADLEW_BAT_PATH" \
    "$GRADLEW_BAT_HELPER_COMMAND" \
    "$GRADLEW_BAT_HELPER_BLOCK" \
    'gradlew.bat'
  buildish_install_insert_after_any_line \
    "$GRADLEW_BAT_PATH" \
    "$GRADLEW_BAT_HELPER_BLOCK" \
    'gradlew.bat' \
    "$GRADLEW_BAT_ANCHOR"
  buildish_install_replace_exact_line_if_present \
    "$GRADLEW_BAT_PATH" \
    "$GRADLEW_BAT_OLD_EXECUTE_LINE" \
    "$GRADLEW_BAT_PATCHED_OLD_EXECUTE_LINE" \
    'gradlew.bat'
  buildish_install_replace_exact_line_if_present \
    "$GRADLEW_BAT_PATH" \
    "$GRADLEW_BAT_LEGACY_EXECUTE_LINE" \
    "$GRADLEW_BAT_PATCHED_LEGACY_EXECUTE_LINE" \
    'gradlew.bat'
  buildish_install_replace_exact_line_if_present \
    "$GRADLEW_BAT_PATH" \
    "$GRADLEW_BAT_CURRENT_EXECUTE_LINE" \
    "$GRADLEW_BAT_PATCHED_CURRENT_EXECUTE_LINE" \
    'gradlew.bat'
  buildish_install_replace_exact_line_if_present \
    "$GRADLEW_BAT_PATH" \
    "$GRADLEW_BAT_GRADLE_9_EXECUTE_LINE" \
    "$GRADLEW_BAT_PATCHED_GRADLE_9_EXECUTE_LINE" \
    'gradlew.bat'
  buildish_install_assert_any_exact_line_present \
    "$GRADLEW_BAT_PATH" \
    'gradlew.bat' \
    "$GRADLEW_BAT_PATCHED_OLD_EXECUTE_LINE" \
    "$GRADLEW_BAT_PATCHED_LEGACY_EXECUTE_LINE" \
    "$GRADLEW_BAT_PATCHED_CURRENT_EXECUTE_LINE" \
    "$GRADLEW_BAT_PATCHED_GRADLE_9_EXECUTE_LINE"
}

buildish_install_require_command mktemp

# Installer entrypoint validation and derived paths.
# Parse --trusted-source-dir option and the optional positional target-directory argument.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --trusted-source-dir)
      [ "$#" -ge 2 ] || buildish_install_fail '--trusted-source-dir requires a path argument.'
      BUILDISH_TRUSTED_SOURCE_DIR=$2
      shift 2
      ;;
    --trusted-source-dir=*)
      BUILDISH_TRUSTED_SOURCE_DIR=${1#--trusted-source-dir=}
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      buildish_install_fail "Unknown option '$1'."
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -le 1 ] || buildish_install_fail 'Expected zero or one positional argument: the target project directory.'
TARGET_DIR=${1:-.}
[ -d "$TARGET_DIR" ] || buildish_install_fail "Target directory does not exist: '$TARGET_DIR'."

TARGET_DIR_ABSOLUTE=$(cd "$TARGET_DIR" >/dev/null 2>&1 && pwd) ||
  buildish_install_fail "Unable to resolve target directory '$TARGET_DIR'."
[ -n "$BUILDISH_TRUSTED_SOURCE_DIR" ] ||
  buildish_install_fail '--trusted-source-dir is required. This installer only stages already-trusted local files.'
TRUSTED_SOURCE_DIR_ABSOLUTE=$(cd "$BUILDISH_TRUSTED_SOURCE_DIR" >/dev/null 2>&1 && pwd) ||
  buildish_install_fail "Unable to resolve trusted local source directory '$BUILDISH_TRUSTED_SOURCE_DIR'."
GRADLE_DIR=$TARGET_DIR_ABSOLUTE/gradle
WRAPPER_DIR=$GRADLE_DIR/wrapper
PROPERTIES_PATH=$WRAPPER_DIR/gradle-wrapper.properties
WRAPPER_JAR_PATH=$WRAPPER_DIR/gradle-wrapper.jar
GRADLEW_PATH=$TARGET_DIR_ABSOLUTE/gradlew
GRADLEW_BAT_PATH=$TARGET_DIR_ABSOLUTE/gradlew.bat
HELPER_SH_PATH=$GRADLE_DIR/buildish-no-gradle-wrapper-jar.sh
HELPER_PS1_PATH=$GRADLE_DIR/buildish-no-gradle-wrapper-jar.ps1
HELPER_INIT_PATH=$GRADLE_DIR/buildish-no-gradle-wrapper-jar.init.gradle.kts

# The Windows launcher patch works in two stages:
#   * a helper block captures the PowerShell helper's stdout into an env var
#   * the final Java invocation line appends that env var before `%*`
#
# Supporting the pre-8.14 classpath/main-class form plus the later `-jar` forms,
# including Gradle 9's endlocal wrapper, keeps compatibility explicit.
GRADLEW_CURRENT_ANCHOR='APP_HOME=$( cd -P "${APP_HOME:-./}" > /dev/null && printf '\''%s\n'\'' "$PWD" ) || exit'
GRADLEW_OLD_ANCHOR='APP_HOME=$( cd "${APP_HOME:-./}" && pwd -P ) || exit'
GRADLEW_BAT_ANCHOR='for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi'
GRADLEW_BAT_HELPER_COMMAND='powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%APP_HOME%\gradle\buildish-no-gradle-wrapper-jar.ps1"'
GRADLEW_BAT_HELPER_BLOCK=$(cat <<EOF
set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=%*
set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=
for /f "delims=" %%a in ('$GRADLEW_BAT_HELPER_COMMAND') do @set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=%%a
set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=
if errorlevel 1 goto fail
EOF
)
GRADLEW_BAT_OLD_EXECUTE_LINE='"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -classpath "%CLASSPATH%" org.gradle.wrapper.GradleWrapperMain %*'
GRADLEW_BAT_LEGACY_EXECUTE_LINE='"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -classpath "%CLASSPATH%" -jar "%APP_HOME%\gradle\wrapper\gradle-wrapper.jar" %*'
GRADLEW_BAT_CURRENT_EXECUTE_LINE='"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -jar "%APP_HOME%\gradle\wrapper\gradle-wrapper.jar" %*'
GRADLEW_BAT_GRADLE_9_EXECUTE_LINE='endlocal & "%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -jar "%APP_HOME%\gradle\wrapper\gradle-wrapper.jar" %* & call :exitWithErrorLevel'
GRADLEW_BAT_PATCHED_OLD_EXECUTE_LINE=$(buildish_install_patch_batch_execute_line "$GRADLEW_BAT_OLD_EXECUTE_LINE")
GRADLEW_BAT_PATCHED_LEGACY_EXECUTE_LINE=$(buildish_install_patch_batch_execute_line "$GRADLEW_BAT_LEGACY_EXECUTE_LINE")
GRADLEW_BAT_PATCHED_CURRENT_EXECUTE_LINE=$(buildish_install_patch_batch_execute_line "$GRADLEW_BAT_CURRENT_EXECUTE_LINE")
GRADLEW_BAT_PATCHED_GRADLE_9_EXECUTE_LINE=$(buildish_install_patch_batch_execute_line "$GRADLEW_BAT_GRADLE_9_EXECUTE_LINE")

[ -f "$PROPERTIES_PATH" ] ||
  buildish_install_fail "Gradle wrapper properties file was not found at '$PROPERTIES_PATH'. Run this installer from a Gradle project root or pass that directory as the only argument."
buildish_install_assert_not_symlink "$PROPERTIES_PATH" 'gradle-wrapper.properties'
# The helper can reconstruct and verify `gradle-wrapper.jar`, but it does not
# replace Gradle's own distribution ZIP verification. Warn early so adopters see
# the trust gap in the generated properties file before the first wrapper run.
if ! grep -Eq '^distributionSha256Sum=[^[:space:]].*' "$PROPERTIES_PATH"; then
  buildish_install_warn "WARNING: '$PROPERTIES_PATH' does not define distributionSha256Sum. Gradle itself will not pin the distribution ZIP checksum during wrapper downloads; this helper continues, but it only verifies gradle-wrapper.jar."
fi

# Stage helper files first so launcher patches never point at missing scripts.
buildish_install_stage_helper_files
buildish_install_remove_regular_file "$WRAPPER_JAR_PATH" 'gradle-wrapper.jar'

# Patch both launchers and then assert that the final expected batch execute line
# is present so silent launcher-format drift does not go unnoticed.
buildish_install_insert_after_any_line \
  "$GRADLEW_PATH" \
  '. "${APP_HOME}/gradle/buildish-no-gradle-wrapper-jar.sh"' \
  'gradlew' \
  "$GRADLEW_CURRENT_ANCHOR" \
  "$GRADLEW_OLD_ANCHOR"
buildish_install_update_gradlew_bat
buildish_install_update_gitignore

echo "${BUILDISH_TOOL_NAME} install: Installed helper files into '$GRADLE_DIR' and updated launcher scripts in '$TARGET_DIR_ABSOLUTE'."
