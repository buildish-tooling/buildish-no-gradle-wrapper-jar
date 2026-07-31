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

# Golden launcher transformations shared by the POSIX installer, PowerShell
# installer, and Gradle init script.

launcher_contract_case_names() {
  python3 "$TESTS_DIR/fixtures/launcher-contract.py" --list
}

assert_launcher_contract_output() {
  implementation=$1
  case_name=$2
  actual_project_dir=$3
  fixture_root=$4

  for launcher_name in gradlew gradlew.bat; do
    expected_path=$fixture_root/$case_name/expected/$launcher_name
    actual_path=$actual_project_dir/$launcher_name
    if ! cmp -s "$expected_path" "$actual_path"; then
      diff -u "$expected_path" "$actual_path" >&2 || true
      fail "$implementation launcher output for '$case_name/$launcher_name' did not match the canonical fixture."
    fi
  done
}

prepare_launcher_contract_installer_project() {
  base_project=$1
  fixture_root=$2
  case_name=$3
  project_dir=$4

  copy_project_fixture "$base_project" "$project_dir"
  cp "$fixture_root/$case_name/input/gradlew" "$project_dir/gradlew"
  cp "$fixture_root/$case_name/input/gradlew.bat" "$project_dir/gradlew.bat"
  chmod +x "$project_dir/gradlew"
}

exercise_launcher_contract_installers() {
  base_project=$1
  fixture_root=$2
  scenario_root=$3

  for installer_kind in posix powershell; do
    for case_name in $(launcher_contract_case_names); do
      project_dir=$scenario_root/$installer_kind/$case_name
      prepare_launcher_contract_installer_project "$base_project" "$fixture_root" "$case_name" "$project_dir"
      case $installer_kind in
        posix) run_posix_installer_capture "$project_dir" ;;
        powershell) run_powershell_installer_capture "$project_dir" ;;
      esac
      assert_last_command_succeeded "$installer_kind installer failed the canonical '$case_name' launcher contract."
      assert_launcher_contract_output "$installer_kind installer" "$case_name" "$project_dir" "$fixture_root"
    done
  done
}

prepare_launcher_contract_init_project() {
  base_project=$1
  fixture_root=$2
  project_dir=$3

  copy_init_script_fixture "$base_project" "$project_dir"
  cp -R "$fixture_root" "$project_dir/launcher-contract-fixtures"
  for case_name in $(launcher_contract_case_names); do
    output_wrapper_dir=$project_dir/launcher-contract-output/$case_name/gradle/wrapper
    mkdir -p "$output_wrapper_dir"
    cp "$base_project/gradle/wrapper/gradle-wrapper.jar" "$output_wrapper_dir/gradle-wrapper.jar"
    cp "$base_project/gradle/wrapper/gradle-wrapper.properties" "$output_wrapper_dir/gradle-wrapper.properties"
  done

  cat >> "$project_dir/build.gradle" <<'EOF'

def launcherContractCaseNames = file('launcher-contract-fixtures').listFiles()
  .findAll { it.isDirectory() }
  .collect { it.name }
  .sort()
def launcherContractTasks = launcherContractCaseNames.collect { caseName ->
  tasks.register("launcher-contract-$caseName", Wrapper) {
    scriptFile = file("launcher-contract-output/$caseName/gradlew")
    jarFile = file("launcher-contract-output/$caseName/gradle/wrapper/gradle-wrapper.jar")
    doLast {
      scriptFile.bytes = file("launcher-contract-fixtures/$caseName/input/gradlew").bytes
      batchScript.bytes = file("launcher-contract-fixtures/$caseName/input/gradlew.bat").bytes
    }
  }
}

gradle.taskGraph.whenReady {
  launcherContractTasks.each { taskProvider ->
    def wrapperTask = taskProvider.get()
    def fixtureAction = wrapperTask.actions.remove(wrapperTask.actions.size() - 1)
    wrapperTask.actions.add(wrapperTask.actions.size() - 1, fixtureAction)
  }
}
EOF
}

exercise_launcher_contract_init_script() {
  base_project=$1
  fixture_root=$2
  project_dir=$3

  prepare_launcher_contract_init_project "$base_project" "$fixture_root" "$project_dir"
  set --
  for case_name in $(launcher_contract_case_names); do
    set -- "$@" "launcher-contract-$case_name"
  done
  run_gradle_with_init_script_capture "$project_dir" "$@"
  assert_last_command_succeeded 'Gradle init script failed a canonical launcher contract.'
  for case_name in $(launcher_contract_case_names); do
    assert_launcher_contract_output \
      'Gradle init script' \
      "$case_name" \
      "$project_dir/launcher-contract-output/$case_name" \
      "$fixture_root"
  done
}

run_launcher_contract_suite() {
  launcher_contract_root=$1
  fixture_root=$launcher_contract_root/fixtures
  base_project=$launcher_contract_root/base-project

  log "starting canonical launcher contract suite (root='$launcher_contract_root')"
  python3 "$TESTS_DIR/fixtures/launcher-contract.py" --output "$fixture_root"
  gradle_init_fixture "$base_project"
  exercise_launcher_contract_installers \
    "$base_project" \
    "$fixture_root" \
    "$launcher_contract_root/installers"
  exercise_launcher_contract_init_script \
    "$base_project" \
    "$fixture_root" \
    "$launcher_contract_root/init-script"
}
