---
title: "Buildish no-gradle-wrapper-jar blueprint"
description: Run `gradlew` / `gradlew.bat` without `gradle-wrapper.jar` in the source tree.
---

<!--
Copyright 2026 The Apache Software Foundation

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

The installer scripts for POSIX environments and Windows are idempotent, so safe to run multiple times.
Re-running the installer scripts updates the helper files to the latest version.

### Recommended reviewed-install flow

Prefer downloading or checking out this repository first, then running the installer from a reviewed
local copy:

#### POSIX / bash

Run from the target project root:

```sh
bash ./tools/buildish-no-gradle-wrapper-jar/install.sh --trusted-source-dir ./tools/buildish-no-gradle-wrapper-jar
```

To target a different directory:

```sh
bash ./tools/buildish-no-gradle-wrapper-jar/install.sh --trusted-source-dir ./tools/buildish-no-gradle-wrapper-jar /path/to/project
```

#### Windows / PowerShell

Run from the target project root:

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\buildish-no-gradle-wrapper-jar\install.ps1 --trusted-source-dir .\tools\buildish-no-gradle-wrapper-jar
```

Or run it against a specific directory:

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\buildish-no-gradle-wrapper-jar\install.ps1 --trusted-source-dir .\tools\buildish-no-gradle-wrapper-jar C:\path\to\project
```

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
curl -fsSL https://raw.githubusercontent.com/apache/buildish/main/tools/buildish-no-gradle-wrapper-jar/unsafe-dev-install.sh | sh -s -- --yes-i-know-this-is-unsafe
```

To target a different directory:

```sh
curl -fsSL https://raw.githubusercontent.com/apache/buildish/main/tools/buildish-no-gradle-wrapper-jar/unsafe-dev-install.sh | sh -s -- --yes-i-know-this-is-unsafe /path/to/project
```

#### Windows / PowerShell

Run from the target project root:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/apache/buildish/main/tools/buildish-no-gradle-wrapper-jar/unsafe-dev-install.ps1))) --yes-i-know-this-is-unsafe
```

Or run it against a specific directory after downloading/cloning this repository locally:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/apache/buildish/main/tools/buildish-no-gradle-wrapper-jar/unsafe-dev-install.ps1))) --yes-i-know-this-is-unsafe C:\path\to\project
```

### Security note

`install.sh` and `install.ps1` no longer fetch helper files themselves. They require a
`--trusted-source-dir` because they are meant to stage already-trusted local payloads, not to
establish trust in downloaded bytes.

The `unsafe-dev-install.*` one-liners above exist only as explicit development shortcuts. They are
not suitable for CI, automation, or environments with secrets.

The repository now also contains `bootstrap-install.*` release templates for the secure remote path,
but those checked-in copies intentionally fail until a release step renders pinned release URLs and
signing-key material into them. Until those rendered release assets are published, the reviewed
local-copy flow above remains the preferred safe path.

For the detailed, non-versioned trust model and the current security assessment, see
[`security.md`](../security/).

For trusted local development, verified bootstrap handoff, and integration testing, pass
`--trusted-source-dir <path>` to point the installer at a checked-out
`tools/buildish-no-gradle-wrapper-jar/` directory and copy helper files from disk instead of
downloading anything from the network.

## Files in this blueprint

- `buildish-no-gradle-wrapper-jar.sh` — POSIX helper for `gradlew`
- `buildish-no-gradle-wrapper-jar.ps1` — PowerShell helper for Windows / `gradlew.bat`
- `buildish-no-gradle-wrapper-jar.init.gradle.kts` — Gradle init script that re-patches freshly generated launcher files after `:wrapper`

The helpers are standalone on purpose. They do not import this repository's TypeScript runtime.

## Script code vs. binary executable

The scripts in this repository are written in POSIX shell and Windows PowerShell not just for maximum
portability, but to explicitly enable inspection and verification.
They do not require any external dependencies beyond a POSIX shell and `gpg` on
POSIX, or PowerShell and a native Windows `gpg.exe` on Windows.

## What the helpers do

The helpers read `gradle/wrapper/gradle-wrapper.properties`, derive the configured Gradle version,
ensure that `gradle/wrapper/gradle-wrapper.jar` is present and verified before Gradle starts, and
inject the project-local Gradle init script when it is available.

The detailed verification flow and trust boundaries live in [`security.md`](../security/).
This release-specific page only documents the operational behavior of the shipped helper scripts.

The helpers retain the downloaded metadata beside the wrapper properties file as:

- `gradle/wrapper/gradle-wrapper-<version>.sha256`
- `gradle/wrapper/gradle-wrapper-<version>.asc`

They write downloaded files through temporary paths and then move them into place, so partially
written files are not left behind if a download or verification step fails.

The injected init script hooks the Gradle `Wrapper` task so that when Renovate or a developer runs
`./gradlew wrapper`, the freshly generated `gradlew` / `gradlew.bat` files are patched again with
the Buildish helper invocation.

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

That usually means a stalled network path, proxy, or upstream endpoint. Recent PowerShell helper
download paths fail explicitly instead of hanging forever. Fix the network path and retry instead of
trying to bypass verification.

### The installer says the launcher shape is unsupported

The patching logic intentionally expects known Gradle launcher patterns so it can fail closed.
Regenerate the wrapper with a supported Gradle version or update this blueprint to the new launcher
shape before patching it automatically.

## Required tools

### POSIX helper

- POSIX shell
- `curl`
- `gpg`
- `mktemp`
- either `sha256sum` or `shasum`

### PowerShell helper

- Windows PowerShell / PowerShell
- native Windows `gpg.exe`
- `Invoke-WebRequest`
- `Get-FileHash`

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

### 1. Copy the helper files into the target project

If you use the automatic installer above, it performs this copy step and the launcher/
`.gitignore` updates for you.

Copy:

- `tools/buildish-no-gradle-wrapper-jar/buildish-no-gradle-wrapper-jar.sh` -> `gradle/buildish-no-gradle-wrapper-jar.sh`
- `tools/buildish-no-gradle-wrapper-jar/buildish-no-gradle-wrapper-jar.ps1` -> `gradle/buildish-no-gradle-wrapper-jar.ps1`
- `tools/buildish-no-gradle-wrapper-jar/buildish-no-gradle-wrapper-jar.init.gradle.kts` -> `gradle/buildish-no-gradle-wrapper-jar.init.gradle.kts`

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

They also need network access so the helper can fetch the wrapper JAR, checksum, and detached
signature from the upstream Gradle endpoints.

## Customization boundaries

The scripts intentionally assume the same Gradle hosts as the
[Apache Buildish Mammoth Cache for Gradle](https://buildish.apache.org/components/mammoth-cache-gradle/):

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
