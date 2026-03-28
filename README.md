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

# Buildish no-gradle-wrapper-jar blueprint

> [!IMPORTANT]
> The minimal Wrapper bootstrap is implemented and validated in this
> development tree. No component release has been published yet; adopters must
> acquire the required source files from an exact reviewed revision.

This repository is a source-only blueprint for Gradle projects that want to use
one or both ordinary `gradlew` and `gradlew.bat` entry points without tracking
`gradle/wrapper/gradle-wrapper.jar` in Git.

It is intended for maintainers whose repository policy avoids committed
compiled binaries but who still want the standard Gradle Wrapper commands. The
trade-off is deliberate: the first run needs network and host-tool support and
creates an ignored executable JAR; later runs trust that checkout-local JAR.

The integration consists of a reviewable init script plus the bootstrap helper
for each launcher the consumer maintains, copied into the project's `gradle/`
directory:

- `buildish-wrapper-bootstrap.sh`
- `buildish-wrapper-bootstrap.ps1`
- `buildish-wrapper.init.gradle.kts`

Adoption also adds root-scoped checkout attributes for the launcher and helper
files the project maintains.

Initial adoption explicitly attaches the project-local init script to a native
root `Wrapper` task. The same task integration preserves the existing launcher
set—POSIX-only, Windows-only, or both—and the two Buildish Wrapper JAR
properties during normal Wrapper updates and supported task-executing Renovate
updates. When neither launcher exists before initial adoption, Gradle's normal
pair is retained.

The intended runtime has one narrow network security property: a Wrapper JAR
downloaded by the Buildish bootstrap is not published to the executable path
until its SHA-256 matches the committed project pin. An existing local ignored
JAR and the rest of the checkout are trusted state; the warm path does not
reverify them.

No compiled Wrapper executable is tracked in Git. Excluding compiled bootstrap
executables from a source release remains an objective, not a current release
claim. Release publication is blocked until the real component source-archive
path verifies the assembled archive while a local ignored Wrapper JAR is
present.

The primary development guide covers reviewed source acquisition, adoption,
cold and warm behavior, Wrapper and Renovate updates, native-Windows stable
launcher copies, compatibility, and recovery:

- [Unreleased development documentation and source acquisition](docs/)
- [Canonical threat model](docs/threat-model.md)
- [Security reporting policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)

Published component navigation is available at
<https://buildish.org/components/no-gradle-wrapper-jar/>.

## License

See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
