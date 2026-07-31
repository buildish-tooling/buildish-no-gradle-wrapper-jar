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

Thank you for considering a contribution to the Buildish no-gradle-wrapper-jar
blueprint. This repository contains POSIX shell and PowerShell helpers,
installers, a Gradle init script, integration tests, and the component's
documentation.

Please follow the [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Before opening a pull request

- Check whether an existing issue or pull request already covers the change.
- For larger changes, start a short design discussion on a GitHub issue before
  investing heavily in implementation.
- Keep pull requests focused; split unrelated work into separate changes.
- When behavior exists in both POSIX shell and PowerShell, check whether the
  equivalent path needs the same change.

## Pull request expectations

- Base pull requests on `main`.
- Describe the motivation and the change clearly.
- Add or update tests and documentation when applicable.
- Keep commit messages and pull request text readable for future project history.
- State which checks you ran and any remaining platform limitations.

## Security issues

Do **not** open a public issue for a suspected security vulnerability. Instead,
report it to [security@buildish.org](mailto:security@buildish.org).

Follow [`SECURITY.md`](SECURITY.md) for the reporting boundary, and read the
repository [`docs/threat-model.md`](docs/threat-model.md) before reporting or
changing security-sensitive behavior.

## Development prerequisites

The complete local check expects these tools on `PATH`:

- a POSIX shell, Bash, and common Unix utilities;
- GNU Make;
- Java 21 or newer;
- Gradle;
- PowerShell (`pwsh`);
- GnuPG (`gpg`);
- Python 3;
- `curl`, Git, and `tar`; and
- `sha256sum` and `sha512sum`, or compatible `shasum` support.

The integration tests download Gradle wrapper artifacts from the upstream Gradle
and GitHub endpoints, and the RAT check may download Apache RAT into the local
`build/` directory. Network access is therefore required for a clean first run.

Native Windows launcher testing additionally requires `cmd.exe`, Windows
PowerShell (`powershell.exe`), and a native Windows GnuPG build. The
Git-for-Windows bundled `gpg.exe` is intentionally tested as an unsupported
configuration for `gradlew.bat` verification.

## Local verification

Run the narrowest relevant check while iterating, then run the complete check
before treating a change as finished:

- `make help` — list the supported targets;
- `make syntax-check` — parse the shell and PowerShell scripts;
- `make test` — run the POSIX-hosted integration suite;
- `make rat-check` — run the license-header check;
- `make release-check` — run the integration and license-header checks; and
- `make check` — run the complete local verification suite.

On native Windows, also run:

```powershell
pwsh -NoLogo -NoProfile -File tests/windows-integration.ps1
pwsh -NoLogo -NoProfile -File tests/windows-git-gpg-rejection.ps1
```

See [`tests/README.md`](tests/README.md) for the test-suite structure and advice
on where to add new scenarios.

## Test expectations

Changes should include focused regression coverage when practical. Test the
behavioral contract rather than only the successful path, including relevant
failure, malformed-input, recovery, idempotency, and platform-specific cases.

The POSIX and PowerShell implementations deliberately provide the same user
journey through different platform mechanisms. When changing one
implementation, review its counterpart and the shared launcher-patching
contract for drift. Keep orchestration in `tests/integration.sh`, shared
mechanics in `tests/lib/`, and topic-oriented scenarios in `tests/suites/`.

## Documentation changes

The component's published source content lives in `site/pages/` and `docs/`.
Keep links relative and route-oriented as described in [`AGENTS.md`](AGENTS.md).
When working in the full Buildish workspace, changes to site content or routing
must also pass `make site-check-local` from the workspace's `site/` directory.

## Release tooling

The Buildish release process for this component is not yet defined. The scripts
under `buildish-release-tooling/` are development tooling and must not be used
to publish a release until reviewed release instructions replace the current
placeholder process.
