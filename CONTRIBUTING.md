<!--
Copyright 2026 The Buildish Authors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Contributing to Buildish no-gradle-wrapper-jar

Thank you for considering a contribution. The component is a small
source-only Wrapper JAR bootstrap with POSIX shell, Windows PowerShell, one
project-local Gradle init script, focused tests, and component documentation.

No component release has been published yet.

Please follow [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Before opening a pull request

- Check whether an existing
  [issue or pull request](https://github.com/buildish-tooling/buildish-no-gradle-wrapper-jar/issues)
  already covers the change.
- For larger changes, start a short design discussion in a GitHub issue before
  investing heavily in implementation. General project questions can also be
  sent to [dev@buildish.org](mailto:dev@buildish.org).
- Keep pull requests focused and separate unrelated work.
- Review the POSIX, native-Windows, Gradle lifecycle, and documentation effects
  of a behavior change even when only one platform file is edited.
- Preserve the version-agnostic product contract. Add versions to the finite
  test matrix only when they add useful compatibility evidence; product source
  must not contain version or digest allowlists.

## Pull request expectations

- Base pull requests on `main`.
- Explain the motivation and observable behavior.
- Add or update focused tests and documentation when applicable.
- State the commands and native platforms you validated and any remaining
  limitations.
- Keep the three canonical runtime sources small and independently reviewable:
  `buildish-wrapper-bootstrap.sh`, `buildish-wrapper-bootstrap.ps1`, and
  `buildish-wrapper.init.gradle.kts`.
- Do not reintroduce runtime GPG, downloaded checksum or signature sidecars,
  automatic installers, remote execution shortcuts, or user-global Gradle init
  files without a separately accepted design.

## Security issues

Do not open a public issue for a suspected vulnerability. Report it to
[security@buildish.org](mailto:security@buildish.org).

Read [`SECURITY.md`](SECURITY.md) and the canonical
[`docs/threat-model.md`](docs/threat-model.md) before reporting or changing
security-sensitive behavior. The runtime boundary protects only the cold
network handoff for a missing JAR. The checkout and an existing local ignored
JAR are trusted state.

## Development prerequisites

The checks use only tools needed for the product contract and its test matrix:

- a POSIX shell, Bash, common Unix utilities, and GNU Make;
- Python 3;
- Git, `curl` 8.4.0 or newer, `tar`, and SHA-512 support for Apache RAT
  provisioning and POSIX runtime validation;
- Java 21 or newer for Apache RAT and Gradle test execution;
- either `sha256sum` or compatible `shasum` support;
- tested Gradle distributions provisioned by the test fixtures; and
- Node.js and npm for Renovate `44.7.0` through the pinned repository-local
  fixture command.

Native-Windows validation additionally requires native `cmd.exe`, Windows
PowerShell 5.1 (`powershell.exe`), a supported JDK, and the .NET APIs used by
the bootstrap. A particular VM, cloud runner, or host setup is not part of the
repository contract.

Runtime or test downloads are stored only in ignored project-local build or
fixture directories. Do not install test tooling into user-global locations as
part of a repository change.

## Validation commands

The command surface provides focused targets for syntax, manifest, repository
invariants, POSIX runtime, Wrapper lifecycle, Renovate, and RAT. Use `make help`
as the source of truth, run the narrowest relevant target while iterating, then
run `make check` before treating a change as complete.

Native Windows uses the platform-neutral checkout entry point:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File tests\windows-integration.ps1 -Suite All
```

The same command must work in local Windows environments and Windows CI. Host
VM lifecycle, ISO, credential, and transport details do not belong in tracked
product or test instructions.

See [`tests/README.md`](tests/README.md) for suite ownership and focused
commands.

## Test expectations

Test the defined boundary and lifecycle rather than deleted behavior:

- missing-JAR download limits, checksum verification, cleanup, and publication;
- warm paths with no network or hashing work and no PowerShell process on
  Windows;
- exact property parsing, generic stable-version validation, and digest
  validation;
- launcher marker, init-script attachment, and generated newline/mode behavior;
- effective checkout attributes for byte-stable POSIX, PowerShell, Kotlin, and
  batch sources across `core.autocrlf` settings;
- root `:wrapper` scoping across ordinary, composite, `buildSrc`,
  configuration-cache, and Isolated Projects cases;
- baseline, first-pass, optional second-pass, installed-Gradle adoption, and
  supported Renovate transitions; and
- native-Windows stable-copy exit propagation and cleanup.

Do not add matrices for runtime GPG, metadata sidecars, installers, user-global
init scripts, custom distributions, speculative launcher generations, or local
attackers who already control the checkout.

## Documentation changes

The component's published source content lives in `site/pages/` and `docs/`.
Keep links relative and route-oriented as described in [`AGENTS.md`](AGENTS.md).
Development documentation must identify unreleased behavior clearly.

Public documentation may state that no compiled Wrapper executable is tracked
in Git. Excluding compiled bootstrap executables from source releases remains
an objective until the actual component archive is assembled and inspected
with a local ignored JAR present. Do not present that objective as a shipped
release property.

When working in the full Buildish workspace, site content or routing changes
must also pass `make site-check-local` from that workspace's `site/` directory.

## Release tooling

Release publication is blocked. Do not dispatch the retained development
release workflows until the real component source-archive path proves that
ignored local Wrapper JARs and other compiled bootstrap executables are absent
from the assembled source archive and the Buildish release process is defined
and reviewed.
