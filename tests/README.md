<!--
 Copyright 2026 The Buildish Authors

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance
 with the License. You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied. See the License for the specific
 language governing permissions and limitations under the License.
-->

# Test layout

This directory contains the shell and PowerShell tests for this project.

## Main entrypoints

- `integration.sh` is the main shell entrypoint used by `bash tests/integration.sh` and `make check`.
- `windows-integration.ps1` contains the Windows-focused PowerShell integration coverage.
- `windows-git-gpg-rejection.ps1` covers the Windows Git/GPG rejection case.

Keep `tests/integration.sh` small. It should mostly:

- initialize shared shell state
- source the helper and suite files in the correct order
- dispatch the supported suite modes

## Folder structure

### `lib/`

Shared shell code that is reused by more than one scenario group.

- `integration-common.sh` contains logging, output capture, assertions, and
  shared environment/tool lookup helpers.
- `integration-project.sh` contains project paths, property/file mutations,
  launcher assertions, and wrapper metadata assertions.
- `integration-runners.sh` contains Gradle, installer, bootstrap, and direct
  helper process runners.
- `integration-fixtures.sh` contains fixture builders and mutable test-environment helpers such as Gradle project setup, local HTTP servers, and bootstrap-signing helpers.

If logic is generic and used by several suites, it belongs in `lib/`.

### `suites/`

Topic-oriented scenario groups.

- `integration-environment.sh` covers tool-selection and CLI help contracts.
- `integration-launcher-contract.sh` compares all supported launcher generations
  against canonical byte-for-byte input/output fixtures for both installers and
  the Gradle init script.
- `integration-installer.sh` covers installer and unsafe-dev flows.
- `integration-helper-integrity.sh` covers artifact recovery, metadata, size,
  link, and replay behavior.
- `integration-helper-configuration.sh` covers properties, pins, timeouts, and
  external-tool failures.
- `integration-helper-protocol.sh` covers launcher arguments and PowerShell's
  stdout/stderr transport contract.
- `integration-helper-edge.sh` is the compatibility coordinator for those three
  helper topic suites.
- `integration-init-script.sh` covers init-script-specific behavior.
- `integration-bootstrap.sh` covers bootstrap installer scenarios.

Each suite file should keep related `exercise_*` functions together and expose one `run_*_suite()` entrypoint for orchestration.

## Where to add new tests

- Add a new helper to `lib/` only when it is shared by multiple suites.
- Add a new scenario to the existing suite file that matches the topic.
- Add a new suite file only when a topic is large enough to deserve its own `run_*_suite()` function.
- Avoid growing `tests/integration.sh` again with scenario-specific logic.

A good rule of thumb is:

- orchestration in `integration.sh`
- reusable mechanics in `lib/`
- scenario intent in `suites/`

## Running the tests

Common commands:

- `bash tests/integration.sh`
- `make check`
- `pwsh -File tests/windows-integration.ps1`

The default suite uses the Gradle executable already selected on `PATH` and
does not source SDKMAN. The `single-version` and `version-list` modes are the
explicit exceptions: they initialize SDKMAN to select requested historical
Gradle versions and a compatible installed Java 17 runtime.

Use the smallest useful command while iterating locally, then run the broader project check before finishing a change.

## Maintenance notes

This layout still relies on shared shell globals and source order. The library
order is common, project, runners, then fixtures; suite modules follow.

When editing the shell suite:

- keep shared variable initialization in `tests/integration.sh`
- source `lib/` before `suites/`
- keep helpers documented near the function definitions
- prefer adding focused scenario functions instead of creating long inline blocks in the dispatcher
