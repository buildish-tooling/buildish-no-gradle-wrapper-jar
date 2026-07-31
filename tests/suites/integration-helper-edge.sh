#!/bin/bash
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

# Compatibility coordinator for the helper topic suites.
run_helper_edge_case_suite() {
  local test_root=$1
  local posix_base_project=$2
  local powershell_base_project=$3
  local scenario_root="$test_root/helper-edge-cases"
  local posix_version
  local powershell_version

  posix_version=$(extract_gradle_version "$posix_base_project")
  powershell_version=$(extract_gradle_version "$powershell_base_project")
  [ -n "$posix_version" ] || fail 'unable to extract the installed Gradle version for the POSIX helper edge-case suite.'
  [ -n "$powershell_version" ] || fail 'unable to extract the installed Gradle version for the PowerShell helper edge-case suite.'

  run_helper_integrity_suite "$scenario_root" "$posix_base_project" "$powershell_base_project" "$posix_version" "$powershell_version"
  run_helper_configuration_suite "$scenario_root" "$posix_base_project" "$powershell_base_project" "$posix_version" "$powershell_version"
  run_helper_protocol_suite "$scenario_root" "$posix_base_project" "$powershell_base_project" "$powershell_version"
}
