---
title: "Buildish no-gradle-wrapper-jar blueprint"
description: Run `gradlew` / `gradlew.bat` without `gradle-wrapper.jar` in the source tree.
---

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

This directory contains a copyable blueprint for projects that want local `gradlew` / `gradlew.bat`
usage without checking `gradle/wrapper/gradle-wrapper.jar` into the source tree.

## Automatic installation scripts

This repository also ships installer entrypoints that stage helper files from a caller-supplied
trusted local directory, patch existing `gradlew` / `gradlew.bat`, remove any pre-existing
`gradle/wrapper/gradle-wrapper.jar`, and add the retained wrapper metadata patterns to `.gitignore`.
Before changing the project, each installer requires a reviewed wrapper-JAR digest pin in
`gradle-wrapper.properties`.

The installer scripts for POSIX environments and Windows are idempotent, so safe to run multiple times.
Re-running the installer scripts updates the helper files to the latest version.

Run `sh install.sh --help` or `powershell.exe -File .\install.ps1 --help` to see
the local install syntax without reading or changing a target project. The
release-bootstrap and explicitly unsafe development entrypoints also support
`-h` and `--help`; help never performs filesystem or network setup.

### Recommended reviewed-install flow

Clone this component repository separately from the target Gradle project, select
an exact commit, and review that checkout before running its installer. The
installer copies only from the directory supplied with `--trusted-source-dir`;
it does not establish trust in the checkout for you.

Start from a clean target-project worktree and commit its current state before
installation. The installers roll back failures they detect during publication,
while an isolated Git commit provides the reviewable rollback boundary after a
successful installation.

### Add the required wrapper-JAR pin

Find the **Wrapper JAR** SHA-256 for the exact Gradle version selected by `distributionUrl` in
Gradle's [checksum documentation](https://gradle.org/release-checksums/). Do not use the similarly
named distribution ZIP checksum. Add exactly one lowercase value to
`gradle/wrapper/gradle-wrapper.properties` and review it with the URL:

```properties
distributionUrl=https\://services.gradle.org/distributions/gradle-<version>-bin.zip
buildishWrapperJarSha256Sum=<reviewed lowercase 64-character Wrapper JAR SHA-256>
```

This committed value is the project's version-to-artifact binding. The downloaded upstream
checksum and Gradle signature must both agree with it; cached or downloaded metadata cannot replace
the project-owned pin.

#### POSIX / bash

Acquire and select the reviewed source revision:

```sh
tool_dir=/path/to/buildish-no-gradle-wrapper-jar
reviewed_commit='<full commit SHA you reviewed>'
git clone https://github.com/buildish-tooling/buildish-no-gradle-wrapper-jar.git "$tool_dir"
git -C "$tool_dir" checkout --detach "$reviewed_commit"
```

Run the standalone checkout's installer against the target project:

```sh
project_dir=/path/to/gradle-project
git -C "$project_dir" status --short
bash "$tool_dir/install.sh" --trusted-source-dir "$tool_dir" "$project_dir"
git -C "$project_dir" diff -- gradlew gradlew.bat gradle/ .gitignore
(cd "$project_dir" && ./gradlew --version)
git -C "$project_dir" add -A -- gradlew gradlew.bat gradle/ .gitignore
git -C "$project_dir" commit -m 'Install Buildish no-gradle-wrapper-jar helper'
```

#### Windows / PowerShell

Acquire and select the reviewed source revision:

```powershell
$ToolDirectory = 'C:\path\to\buildish-no-gradle-wrapper-jar'
$ReviewedCommit = '<full commit SHA you reviewed>'
git clone https://github.com/buildish-tooling/buildish-no-gradle-wrapper-jar.git $ToolDirectory
git -C $ToolDirectory checkout --detach $ReviewedCommit
```

Run the standalone checkout's installer against the target project:

```powershell
$ProjectDirectory = 'C:\path\to\gradle-project'
git -C $ProjectDirectory status --short
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
  "$ToolDirectory\install.ps1" --trusted-source-dir $ToolDirectory $ProjectDirectory
git -C $ProjectDirectory diff -- gradlew gradlew.bat gradle/ .gitignore
Push-Location $ProjectDirectory
try { .\gradlew.bat --version } finally { Pop-Location }
git -C $ProjectDirectory add -A -- gradlew gradlew.bat gradle/ .gitignore
git -C $ProjectDirectory commit -m 'Install Buildish no-gradle-wrapper-jar helper'
```

If the component is intentionally vendored inside a larger source tree, set
`tool_dir` / `$ToolDirectory` to that reviewed directory instead. The installer
does not require a particular parent-directory layout.

### Review, commit, and rollback

The installation diff should be limited to:

- the required `buildishWrapperJarSha256Sum` in `gradle-wrapper.properties`;
- three new `gradle/buildish-no-gradle-wrapper-jar.*` helper files;
- helper invocation changes in `gradlew` and `gradlew.bat`;
- retained metadata patterns in `.gitignore`; and
- deletion of `gradle/wrapper/gradle-wrapper.jar`.

Investigate any other change before committing. Keep the installation in its
own commit, as shown above. To uninstall or roll back later, revert that commit:

```sh
git revert <installation-commit>
```

This restores the exact pre-install tracked tree, including the original
launchers, `.gitignore`, and wrapper JAR. Both installer implementations verify
this round trip in the integration suite. If installation changes are still
uncommitted, inspect them with `git diff` and use your normal Git restoration
workflow; do not delete the whole `gradle/` directory because it also contains
the project's wrapper configuration.

### Unsafe development shortcut

If you explicitly want the old "just trust the current main branch" proof-of-concept flow, use the
dedicated `unsafe-dev-install.*` scripts instead of `install.*`.

These scripts are intentionally insecure:

- they download and execute unverified development-branch content
- they require `--yes-i-know-this-is-unsafe`
- they are not suitable for CI, automation, or environments with secrets

#### POSIX / bash

Run from the target project root:

```sh
curl -fsSL https://raw.githubusercontent.com/buildish-tooling/buildish/main/tools/buildish-no-gradle-wrapper-jar/unsafe-dev-install.sh | sh -s -- --yes-i-know-this-is-unsafe
```

To target a different directory:

```sh
curl -fsSL https://raw.githubusercontent.com/buildish-tooling/buildish/main/tools/buildish-no-gradle-wrapper-jar/unsafe-dev-install.sh | sh -s -- --yes-i-know-this-is-unsafe /path/to/project
```

#### Windows / PowerShell

Run from the target project root:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/buildish-tooling/buildish/main/tools/buildish-no-gradle-wrapper-jar/unsafe-dev-install.ps1))) --yes-i-know-this-is-unsafe
```

Or run it against a specific directory after downloading/cloning this repository locally:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/buildish-tooling/buildish/main/tools/buildish-no-gradle-wrapper-jar/unsafe-dev-install.ps1))) --yes-i-know-this-is-unsafe C:\path\to\project
```

### Security note

`install.sh` and `install.ps1` no longer fetch helper files themselves. They require a
`--trusted-source-dir` because they are meant to stage already-trusted local payloads, not to
establish trust in downloaded bytes.

The `unsafe-dev-install.*` one-liners above exist only as explicit development shortcuts. They are
not suitable for CI, automation, or environments with secrets.

The repository now also contains `bootstrap-install.*` release templates for the secure remote path,
but those checked-in copies intentionally fail until a release step renders pinned release URLs,
the exact signed-manifest SHA-256, and signing-key material into them. The manifest pin prevents a
different validly signed release payload set from being replayed at the selected release URL. Until
those rendered release assets are published, the reviewed local-copy flow above remains the
preferred safe path.

For the detailed, non-versioned trust model and the current security assessment, see
[`security.md`](../security/).

For trusted local development, verified bootstrap handoff, and integration testing, pass
`--trusted-source-dir <path>` to point the installer at a checked-out
`buildish-no-gradle-wrapper-jar` directory and copy helper files from disk
instead of downloading anything from the network.

## Files in this blueprint

- `buildish-no-gradle-wrapper-jar.sh` — POSIX helper for `gradlew`
- `buildish-no-gradle-wrapper-jar.ps1` — PowerShell helper for Windows / `gradlew.bat`
- `buildish-no-gradle-wrapper-jar.init.gradle.kts` — Gradle init script that re-patches freshly generated launcher files after `:wrapper`

The helpers are standalone on purpose. They do not import this repository's TypeScript runtime.

## Script code vs. binary executable

The scripts in this repository are written in POSIX shell and Windows PowerShell
to keep inspection and verification straightforward. They still depend on the
host tools and runtime APIs listed below; they are source scripts, not
dependency-free executables.

## What the helpers do

The helpers read `gradle/wrapper/gradle-wrapper.properties`, derive the configured Gradle version,
require its project-owned `buildishWrapperJarSha256Sum`, ensure that
`gradle/wrapper/gradle-wrapper.jar` matches that pin and Gradle's checksum/signature before Gradle
starts, and inject the project-local Gradle init script when it is available.

The detailed verification flow and trust boundaries live in [`security.md`](../security/).
This release-specific page only documents the operational behavior of the shipped helper scripts.

The helpers retain the downloaded metadata beside the wrapper properties file as:

- `gradle/wrapper/gradle-wrapper-<version>.sha256`
- `gradle/wrapper/gradle-wrapper-<version>.asc`

They write downloaded files through temporary paths and then move them into place, so partially
written files are not left behind if a download or verification step fails. If retained metadata
has a valid shape but fails its binding or cryptographic check, the helpers refresh the checksum
and signature together once and re-run verification. A cached JAR that also disagrees with the
project pin is rejected rather than used to authorize that refresh.

The injected init script hooks the Gradle `Wrapper` task so that when Renovate or a developer runs
`./gradlew wrapper`, the freshly generated `gradlew` / `gradlew.bat` files are patched again with
the Buildish helper invocation. Gradle drops unknown properties while regenerating
`gradle-wrapper.properties`, so the init script also preserves the existing Buildish pin.

## Updating the Gradle version

Run the normal Wrapper task with the desired version. The init script preserves the old
`buildishWrapperJarSha256Sum` and warns that it was not recalculated:

```sh
./gradlew wrapper --gradle-version <new-version> --distribution-type bin
```

Then obtain the new version's Wrapper JAR checksum from Gradle's checksum documentation and replace
`buildishWrapperJarSha256Sum` in the same reviewed change as `distributionUrl`. The helper
intentionally fails the next launch if the old and new values do not agree. Do not hash the JAR
written by this first Wrapper task: that task still runs under the old Gradle version and can emit
the old wrapper artifact.

Run the Wrapper task a second time after updating the reviewed pin so the newly selected Gradle
version regenerates all wrapper files:

```sh
./gradlew wrapper --gradle-version <new-version> --distribution-type bin
```

Review the resulting properties and launcher changes before running `./gradlew --version` again.

## Troubleshooting

### PowerShell says `gpg.exe` is unsupported or missing

The Windows helper requires a native Windows GnuPG installation. The Git-for-Windows bundled
`gpg.exe` is intentionally rejected for `gradlew.bat` verification. Install `Gpg4win`,
`choco install gnupg`, or `scoop install gpg`.

### The helper reports a checksum or detached-signature mismatch

Treat that as a security failure, not as a transient warning. The helper intentionally refuses to
run Gradle with an unverified `gradle-wrapper.jar`. Remove the retained metadata files only if you
understand why they are stale, then retry.

### The helper fails with a timeout

That usually means a stalled network path, proxy, or upstream endpoint. Runtime helper downloads
and release-rendered bootstrap downloads use a 60-second default deadline. Fix the network path and
retry instead of trying to bypass verification.

Set `BUILDISH_NO_GRADLE_WRAPPER_JAR_HTTP_TIMEOUT_SECONDS` to a positive integer to change the
runtime helper deadline. The release-rendered POSIX bootstrap uses
`BUILDISH_BOOTSTRAP_INSTALL_HTTP_TIMEOUT_SECONDS` for the same purpose. Invalid or zero values fail
before network access.

### The helper reports a missing or mismatched buildishWrapperJarSha256Sum

Add exactly one lowercase Wrapper JAR SHA-256 for the version in `distributionUrl`, or update the
preserved value after a Wrapper upgrade. Review the URL and pin together. Do not copy the value from
an unexplained local cache entry merely to make the error disappear.

### The installer says the launcher shape is unsupported

The patching logic intentionally expects known Gradle launcher patterns so it can fail closed.
Regenerate the wrapper with a supported Gradle version or update this blueprint to the new launcher
shape before patching it automatically.

## Required tools

| Scenario | Required environment | Network behavior |
| --- | --- | --- |
| POSIX local install | POSIX shell, `mktemp`, and common file/text utilities | No network access; copies from `--trusted-source-dir` |
| Windows local install | Windows PowerShell or PowerShell 7 | No network access; copies from `--trusted-source-dir` |
| POSIX `gradlew` runtime | POSIX shell, `curl`, `gpg`, `mktemp`, and SHA-256 utilities | Needed when verified wrapper files are not already cached |
| Windows `gradlew.bat` runtime | Windows PowerShell (`powershell.exe`), native Windows `gpg.exe`, and .NET hashing/HTTP APIs | Needed when verified wrapper files are not already cached |
| Release bootstrap | Runtime platform tools; POSIX also needs `dd`, `mkfifo`, and `curl` or `wget` | Always required to acquire the release payload |
| POSIX-hosted integration tests | Bash, Gradle on `PATH`, PowerShell 7 (`pwsh`), GnuPG, Python 3, Git, checksum tools, and upstream access | Required |
| Native Windows integration tests | `pwsh`, `cmd.exe`, `powershell.exe`, native Windows GnuPG, Git, and upstream access | Required |
| Complete `make check` | Integration-test tools plus Make, Java 21+, `tar`, and SHA-512 support for RAT | Required on a clean first run |

> [!IMPORTANT]
> `gradlew.bat` invokes `powershell.exe` by name. Installing PowerShell 7
> (`pwsh`) alone does not satisfy that runtime requirement.

### POSIX helper

- POSIX shell
- `curl`
- `gpg`
- `mktemp`
- either `sha256sum` or `shasum`

The release-rendered POSIX bootstrap additionally requires `dd` and `mkfifo`; it uses them to stop
unknown-length responses at the documented byte limit. It supports either `curl` or `wget`.

### PowerShell helper

- Windows PowerShell (`powershell.exe`) for `gradlew.bat`
- native Windows `gpg.exe`
- `System.Net.Http`
- `Get-FileHash`

### Cold and offline behavior

The reviewed local-copy installers work offline because they only copy files
from `--trusted-source-dir`. Release bootstraps and unsafe development
installers always require network access.

The first helper-backed wrapper run normally downloads checksum/signature
metadata and `gradle-wrapper.jar`. Later runs can work without network access
when all three retained files are present and still pass the project pin,
checksum, and signature checks. The required host commands must still be
installed. Missing, stale, corrupt, or wrong-version cache files require network
recovery and fail closed while offline. Gradle may separately require its
distribution ZIP unless that ZIP is already present in `GRADLE_USER_HOME`.

> [!IMPORTANT]
> `gradlew.bat` verification requires a native Windows GnuPG build. The helper intentionally rejects
> the Git-for-Windows bundled `gpg.exe` because that MSYS-flavored toolchain resolves helper programs
> via Unix-style paths and breaks the verification contract. Install one of these instead:
>
> - [Gpg4win](https://gpg4win.org/)
> - `choco install gnupg`
> - `scoop install gpg`

## Manual installation

Projects copy three files into their own `gradle/` directory and add one small invocation to their
generated `gradlew` / `gradlew.bat`.

Before copying or patching anything, add and review the required
`buildishWrapperJarSha256Sum` property described above.

### 1. Copy the helper files into the target project

If you use the automatic installer above, it performs this copy step and the launcher/
`.gitignore` updates for you.

Copy from the reviewed component checkout:

- `buildish-no-gradle-wrapper-jar.sh` -> `gradle/buildish-no-gradle-wrapper-jar.sh`
- `buildish-no-gradle-wrapper-jar.ps1` -> `gradle/buildish-no-gradle-wrapper-jar.ps1`
- `buildish-no-gradle-wrapper-jar.init.gradle.kts` -> `gradle/buildish-no-gradle-wrapper-jar.init.gradle.kts`

### 2. Patch `gradlew`

Insert the following line immediately after `APP_HOME` is resolved:

```sh
. "${APP_HOME}/gradle/buildish-no-gradle-wrapper-jar.sh"
```

In current Gradle launchers, that means directly after:

```sh
APP_HOME=$( cd -P "${APP_HOME:-./}" > /dev/null && printf '%s\n' "$PWD" ) || exit
```

### 3. Patch `gradlew.bat`

Insert the following block immediately after the `for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi`
line, and replace the final `"%JAVA_EXE%" ... %*` invocation so it includes
`%BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS%` before `%*`:

```bat
set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=%*
set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=
for /f "delims=" %%a in ('powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%APP_HOME%\gradle\buildish-no-gradle-wrapper-jar.ps1"') do @set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=%%a
set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=
if errorlevel 1 goto fail
```

### 4. Stop tracking `gradle-wrapper.jar`

Projects that want source trees without compiled wrapper binaries should remove
`gradle/wrapper/gradle-wrapper.jar` from version control.

Whether projects also commit the retained `.sha256` / `.asc` files is a policy choice. The helper
works when those files are absent because it will download and retain them locally.

## Development and verification

This tool directory has its own local verification trampoline:

- `make test` — shell integration tests using `gradle init`
- `make rat-check` — Apache RAT over the tracked tool files
- `make check` — syntax checks, integration tests, and RAT

The integration tests expect these commands to be available on `PATH`:

- `gradle`
- `pwsh`
- `gpg`
- `python3`
- `git`
- `curl`
- either `sha256sum` or `shasum`

They also need network access so the helper can fetch the wrapper JAR, checksum, and detached
signature from the upstream Gradle endpoints. The complete check additionally
uses Make, Java 21+, `tar`, and SHA-512 support as documented in
[`CONTRIBUTING.md`](https://github.com/buildish-tooling/buildish-no-gradle-wrapper-jar/blob/main/CONTRIBUTING.md).

## Customization boundaries

The scripts intentionally assume the same Gradle hosts as the
[Buildish Mammoth Cache for Gradle](https://buildish.org/components/mammoth-cache/):

- `services.gradle.org` for checksum and detached signature metadata
- `raw.githubusercontent.com/gradle/gradle/...` for the wrapper JAR bytes

Projects that use custom Gradle distributions or custom wrapper JAR locations will need to adapt
the URLs and, possibly, the trust material.

## Current validation scope in this repository

This repository validates the blueprint with tool-local syntax checks, shell integration tests that
exercise `gradle init` plus `./gradlew ...` flows, and a dedicated Apache RAT check for the tracked
tool files.

The repository has also run a realistic wrapper-upgrade probe that bootstraps with Gradle `8.1.1`
and Java `17`, then upgrades through the latest tested patch release of each minor line from `8.1`
through `9.4`:

- `8.1.1`, `8.2.1`, `8.3`, `8.4`, `8.5`, `8.6`, `8.7`, `8.8`, `8.9`
- `8.10.2`, `8.11.1`, `8.12.1`, `8.13`, `8.14.4`
- `9.0.0`, `9.1.0`, `9.2.1`, `9.3.1`, `9.4.1`

That version exercise is a record of test coverage in this repository, not a compatibility promise
or formal support guarantee for every project layout, operating system, shell environment, or future
Gradle release.

The default CI and integration suite additionally bootstrap with Gradle `9.6.1`, covering its
current POSIX and Windows launcher shapes.
