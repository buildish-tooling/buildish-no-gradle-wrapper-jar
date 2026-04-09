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

# Init-script-focused scenarios for tests/integration.sh.

# Exercise that the init script suppresses the warning banner once the project
# defines distributionSha256Sum explicitly.
exercise_init_script_warning_suppression() {
  project_dir=$1

  log "exercising init-script distributionSha256Sum warning suppression in '$project_dir'"
  cat >> "$project_dir/build.gradle" <<'EOF'

tasks.named('wrapper') {
  distributionSha256Sum = 'a' * 64
}
EOF

  run_gradle_with_init_script_capture "$project_dir" wrapper
  assert_last_command_succeeded 'Init script unexpectedly failed when distributionSha256Sum was present.'
  assert_last_output_not_contains 'Buildish helper warning:' 'Init script emitted the missing distributionSha256Sum warning even though the checksum was present.'
  assert_launcher_patches "$project_dir"
}

# Exercise init-script idempotence against already patched launchers so wrapper
# reruns do not duplicate helper includes or batch launcher blocks.
exercise_init_script_idempotence() {
  project_dir=$1
  gradlew_path="$project_dir/gradlew"
  gradlew_bat_path="$project_dir/gradlew.bat"

  log "exercising init-script idempotence in '$project_dir'"
  cat >> "$project_dir/build.gradle" <<'EOF'

tasks.named('wrapper') {
  doLast {
    scriptFile.setText([
      'APP_HOME=$( cd -P "${APP_HOME:-./}" > /dev/null && printf \'%s\\n\' "$PWD" ) || exit',
      '. "${APP_HOME}/gradle/buildish-no-gradle-wrapper-jar.sh"',
    ].join('\n'), 'UTF-8')
    batchScript.setText([
      'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi',
      'set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=%*',
      'set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=',
      'for /f "delims=" %%a in (\'powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%APP_HOME%\\gradle\\buildish-no-gradle-wrapper-jar.ps1"\') do @set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=%%a',
      'set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=',
      'if errorlevel 1 goto fail',
      '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" %BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS% %*',
    ].join('\r\n'), 'UTF-8')
  }
}

gradle.taskGraph.whenReady {
  def wrapperTask = tasks.named('wrapper').get()
  def customAction = wrapperTask.actions.remove(wrapperTask.actions.size() - 1)
  wrapperTask.actions.add(wrapperTask.actions.size() - 1, customAction)
}
EOF

  run_gradle_with_init_script_capture "$project_dir" wrapper
  assert_last_command_succeeded 'Init script unexpectedly duplicated an already patched launcher.'
  assert_file_exact_line_count "$gradlew_path" '. "${APP_HOME}/gradle/buildish-no-gradle-wrapper-jar.sh"' 1 'Init script duplicated the POSIX helper include in an already patched gradlew.'
  assert_file_exact_line_count "$gradlew_bat_path" 'set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=%*' 1 'Init script duplicated the batch helper block in an already patched gradlew.bat.'
  assert_file_exact_line_count "$gradlew_bat_path" '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -jar "%APP_HOME%\gradle\wrapper\gradle-wrapper.jar" %BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS% %*' 1 'Init script duplicated the patched batch Java invocation line.'
}

# Exercise init-script patching of launcher files that lack trailing newlines so
# line-ending style is preserved instead of normalized accidentally.
exercise_init_script_newline_preservation() {
  project_dir=$1
  gradlew_path="$project_dir/gradlew"
  gradlew_bat_path="$project_dir/gradlew.bat"

  log "exercising init-script newline preservation and no-trailing-newline patching in '$project_dir'"
  cat >> "$project_dir/build.gradle" <<'EOF'

tasks.named('wrapper') {
  doLast {
    scriptFile.setText('APP_HOME=$( cd -P "${APP_HOME:-./}" > /dev/null && printf \'%s\\n\' "$PWD" ) || exit', 'UTF-8')
    batchScript.setText([
      'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi',
      '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" %*',
    ].join('\r\n'), 'UTF-8')
  }
}

gradle.taskGraph.whenReady {
  def wrapperTask = tasks.named('wrapper').get()
  def customAction = wrapperTask.actions.remove(wrapperTask.actions.size() - 1)
  wrapperTask.actions.add(wrapperTask.actions.size() - 1, customAction)
}
EOF

  run_gradle_with_init_script_capture "$project_dir" wrapper
  assert_last_command_succeeded 'Init script failed to patch launcher files that lacked a trailing newline.'
  assert_launcher_patches "$project_dir"
  assert_file_newline_shape "$gradlew_path" lf no 'Init script did not preserve LF newline style without adding a trailing newline to gradlew.'
  assert_file_newline_shape "$gradlew_bat_path" crlf no 'Init script did not preserve CRLF newline style without adding a trailing newline to gradlew.bat.'
}

# Exercise the init-script failure path when gradlew no longer contains the
# expected POSIX insertion anchor.
exercise_init_script_gradlew_anchor_failure() {
  project_dir=$1

  log "exercising init-script unsupported gradlew anchor failure in '$project_dir'"
  cat >> "$project_dir/build.gradle" <<'EOF'

tasks.named('wrapper') {
  doLast {
    scriptFile.setText('unsupported-gradlew-anchor', 'UTF-8')
    batchScript.setText([
      'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi',
      '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" %*',
    ].join('\r\n'), 'UTF-8')
  }
}

gradle.taskGraph.whenReady {
  def wrapperTask = tasks.named('wrapper').get()
  def customAction = wrapperTask.actions.remove(wrapperTask.actions.size() - 1)
  wrapperTask.actions.add(wrapperTask.actions.size() - 1, customAction)
}
EOF

  run_gradle_with_init_script_capture "$project_dir" wrapper
  assert_last_command_failed 'Init script unexpectedly accepted an unsupported gradlew anchor.'
  assert_last_output_contains 'Unable to find the expected insertion point in gradlew' 'Init script failure output did not mention the unsupported gradlew anchor.'
}

# Exercise the init-script failure path when gradlew.bat no longer contains the
# expected Java invocation line to replace.
exercise_init_script_gradlew_bat_replacement_failure() {
  project_dir=$1

  log "exercising init-script unsupported gradlew.bat execute-line failure in '$project_dir'"
  cat >> "$project_dir/build.gradle" <<'EOF'

tasks.named('wrapper') {
  doLast {
    scriptFile.setText('APP_HOME=$( cd -P "${APP_HOME:-./}" > /dev/null && printf \'%s\\n\' "$PWD" ) || exit', 'UTF-8')
    batchScript.setText([
      'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi',
      'unsupported-gradlew-bat-execute-line',
    ].join('\r\n'), 'UTF-8')
  }
}

gradle.taskGraph.whenReady {
  def wrapperTask = tasks.named('wrapper').get()
  def customAction = wrapperTask.actions.remove(wrapperTask.actions.size() - 1)
  wrapperTask.actions.add(wrapperTask.actions.size() - 1, customAction)
}
EOF

  run_gradle_with_init_script_capture "$project_dir" wrapper
  assert_last_command_failed 'Init script unexpectedly accepted an unsupported gradlew.bat execute line.'
  assert_last_output_contains 'Unable to find the expected replacement point in gradlew.bat' 'Init script failure output did not mention the unsupported gradlew.bat execute line.'
}

# Run the init-script-focused regression slice on independent fixture copies so
# launcher mutations from one case cannot mask another.
run_init_script_focused_suite() {
  test_root=$1
  base_project="$test_root/init-script-base"
  scenario_root="$test_root/init-script-focused"

  log "starting focused init-script suite (base_project='$base_project')"
  gradle_init_fixture "$base_project"

  copy_init_script_fixture "$base_project" "$scenario_root/warning-suppression"
  exercise_init_script_warning_suppression "$scenario_root/warning-suppression"

  copy_init_script_fixture "$base_project" "$scenario_root/idempotence"
  exercise_init_script_idempotence "$scenario_root/idempotence"

  copy_init_script_fixture "$base_project" "$scenario_root/newline-preservation"
  exercise_init_script_newline_preservation "$scenario_root/newline-preservation"

  copy_init_script_fixture "$base_project" "$scenario_root/unsupported-gradlew-anchor"
  exercise_init_script_gradlew_anchor_failure "$scenario_root/unsupported-gradlew-anchor"

  copy_init_script_fixture "$base_project" "$scenario_root/unsupported-gradlew-bat-replacement"
  exercise_init_script_gradlew_bat_replacement_failure "$scenario_root/unsupported-gradlew-bat-replacement"
}