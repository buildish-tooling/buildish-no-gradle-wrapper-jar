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

The test suite uses the minimal Wrapper bootstrap harness described below.

The test architecture exercises generic product rules with a finite test
matrix. It does not retain coverage for runtime GPG, checksum or
signature sidecars, automatic installers, release bootstrap assets,
PowerShell-to-batch stdout transport, or speculative historical launchers.

## Compatibility source of truth

`fixtures/compatibility-manifest.json` is the only versioned test-data source of
truth. It is compatibility evidence, not a product allowlist. It records:

- Wrapper versions `8.14.5` and `9.6.1`, their raw tags and exact JAR digests;
- canonical binary distribution URLs and SHA-256 values;
- byte-identical POSIX and Windows launcher fixtures;
- baseline, upgrade, downgrade, and optional second-pass transitions;
- installed-Gradle adoption cases;
- native-Windows stable-copy exit results; and
- the pinned Renovate `44.7.0` task-executing contract.

Generated launchers under `fixtures/launchers/` preserve their canonical line
endings. POSIX fixtures are executable and use LF; batch fixtures preserve
CRLF. No Wrapper JAR, Gradle distribution, class file, npm package, or expected
patched launcher is tracked as a fixture.

Those raw launchers are the relevant Gradle-generated fixture pieces for the
offline structural checks. Tracking Wrapper JAR or distribution bytes merely
to avoid integration setup would contradict the component's executable-content
boundary and make the source tree much larger; lifecycle tests provision and
verify those ignored artifacts in the project-local test cache instead.

## Test layout

```text
tests/
├── README.md
├── integration.sh
├── windows-integration.ps1
├── windows/
│   ├── lib/
│   │   ├── assertions.ps1
│   │   ├── consumer-fixture.ps1
│   │   ├── http-fixture.ps1
│   │   ├── gradle-harness.ps1
│   │   ├── native-process.ps1
│   │   └── tool-fixtures.ps1
│   ├── suites/
│   │   ├── lifecycle.ps1
│   │   ├── runtime.ps1
│   │   └── stable-copy.ps1
│   └── unit/
│       └── fixtures.tests.ps1
├── fixtures/
│   ├── compatibility-manifest.json
│   ├── http-server.py
│   ├── init-transform-check.gradle.kts
│   ├── launcher-contract.py
│   ├── launchers/
│   │   ├── 8.14.5/{gradlew,gradlew.bat}
│   │   └── 9.6.1/{gradlew,gradlew.bat}
│   └── renovate/
│       ├── config.json
│       └── run-artifact-update.mjs
├── lib/
│   ├── integration-common.sh
│   └── integration-fixtures.sh
└── suites/
    ├── integration-invariants.sh
    ├── integration-runtime.sh
    ├── integration-init-script.sh
    └── integration-renovate.sh
```

## Main entry points

`integration.sh` is the POSIX orchestration entry point. Its final interface
accepts only:

```text
all | scaffolding | invariants | runtime | lifecycle | renovate
```

It owns the unique test root, bounded suite-local Gradle state, timeouts,
cleanup registration, per-case timing, and failure-log retention. Scenario
details belong in the topic suites.

`windows-integration.ps1` is the sole native-Windows entry point. Its final
interface is:

```text
-Suite All|Runtime|Lifecycle|StableCopy
-BuildDirectory <path>
-Gradle8145Home <optional-path>
-Gradle961Home <optional-path>
```

The entry point loads native-process, tool-provisioning, HTTP-fixture,
consumer-fixture, assertion, Gradle-harness, and suite files from `windows/`.
It must work unchanged in a local native-Windows environment and Windows CI.
Host VM setup, transport, ISO paths, and credentials are not repository test
inputs.

## Shared code

`lib/integration-common.sh` owns logging, assertions, bounded process capture,
SHA-256 helpers, and cleanup registration.

`lib/integration-fixtures.sh` owns temporary consumer creation, exact Gradle
provisioning, canonical source copying, test-only localhost URL substitution,
and local HTTP server lifecycle.

Do not recreate generic project and runner libraries or any bootstrap,
installer, helper-configuration, helper-integrity, helper-protocol, or
helper-edge suite.

## Suite ownership

- `integration-invariants.sh` covers manifest, repository, and consumer
  invariants with exact path-focused diagnostics.
- `integration-runtime.sh` covers POSIX cold and warm behavior, download bounds,
  digest failure, cleanup, spaces, trap restoration, and concurrent same-pin
  publication.
- `integration-init-script.sh` covers root task scoping, initial adoption,
  upgrades and downgrades, POSIX-only and Windows-only launcher preservation,
  launcher patching, configuration cache, Isolated Projects, and clean-checkout
  cold starts. A fixture appends a narrow task to a temporary copy of the
  product init script so its production text transformations and negative
  grammar matrix run in one Gradle invocation without adding a compiled product
  artifact.
- `integration-renovate.sh` invokes the real pinned Renovate manager artifact
  update and checks the returned launcher and properties set.
- Native-Windows Runtime, Lifecycle, and StableCopy suites cover the equivalent
  Windows behavior, including exact propagation of exit codes `0`, `37`, and
  `83`.

The launcher-contract Python utility validates fixtures and consumer output; it
does not patch launchers or contain generated launcher text. The invariant
checker is network-free. Runtime network behavior is tested only against a
localhost server with fixed fixture routes.

Generic version syntax, derived URLs, manifest structure, launcher structure,
and repository invariants are tested by the offline Python checks. Shell and
PowerShell suites retain only platform-native parsing, download, publication,
cleanup, and process behavior. Gradle lifecycle tests are reserved for actual
task-generation, launcher-patching, configuration-cache, composite-build, and
Isolated Projects contracts.

The platform-neutral PowerShell unit check exercises harness mechanics that do
not require native Windows, including deterministic application selection when
`PATH` exposes multiple `python.exe` candidates as on GitHub-hosted runners.

## Commands

Focused Make targets cover syntax, manifest, invariant self-tests, repository
invariants, POSIX runtime, Wrapper lifecycle, Renovate, and RAT. `make help` is
the command source of truth. The complete non-Windows entry point is:

```sh
make check
```

Run native-Windows coverage with:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File tests\windows-integration.ps1 -Suite All
```

Use the smallest suite or Make target while iterating, then run the complete
platform-appropriate entry points before treating a change as finished.

## Maintenance rules

- Keep orchestration in `integration.sh`, shared mechanics in the two libraries,
  and scenario intent in the four POSIX suites.
- Provision only Gradle `8.14.5` and `9.6.1`, under ignored project-local test
  directories, and verify any caller-supplied exact Gradle home before use.
- Reuse the ignored lifecycle `GRADLE_USER_HOME` on POSIX and one ignored shared
  `GRADLE_USER_HOME` across all native-Windows suites. Consumer projects and
  configuration-cache state remain unique per case.
- Reuse Gradle daemons within lifecycle runs, stop every suite-owned daemon
  before final cleanup, and delete the complete run root only after that stop so
  Windows file-cache locks cannot turn successful cases into cleanup failures.
- Bound every external process and register cleanup before starting resources.
- Keep test-only source URL substitution out of product configuration and
  product code.
- Preserve exact fixture bytes, launcher modes, line endings, and final
  newlines, including effective Git checkout attributes.
- Add compatibility only with corresponding manifest, artifact-identity,
  launcher, lifecycle, native-Windows, and clean-checkout evidence.
