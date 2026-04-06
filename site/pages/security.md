---
title: "Security and trust model"
description: Security properties, trust boundaries, and the current assessment for the no-gradle-wrapper-jar blueprint.
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

# Security and trust model

Date: 2026-04-06

This page explains what the no-gradle-wrapper-jar blueprint verifies, which trust boundaries it
assumes, and which security gap still remains before the component can claim a fully pinned
bootstrap path.

## Trust model

### Runtime helper path

The strongest trust boundary in this repository is the normal `gradlew` / `gradlew.bat` runtime
path.

Before the helper accepts `gradle/wrapper/gradle-wrapper.jar`, it requires all of these checks to
pass:

1. `distributionUrl` must use the canonical `https://services.gradle.org/distributions/...` shape.
2. The Gradle version is derived only from the validated distribution URL.
3. The authoritative wrapper checksum and detached signature are downloaded from
   `services.gradle.org`.
4. The wrapper JAR bytes are downloaded from the matching Gradle source tag on GitHub.
5. The JAR must match the expected SHA-256 checksum.
6. The detached signature must verify against pinned Gradle signing-key fingerprints in an isolated
   temporary GPG home.
7. Downloaded metadata and JAR files are written via temporary paths and only moved into place on
   success.

That means poisoned cache content or a corrupted download should fail closed instead of being
accepted silently.

### Installer bootstrap path

The installer path is intentionally documented as weaker today.

`install.sh` and `install.ps1` still download helper files from
`raw.githubusercontent.com/apache/buildish/...` without a detached-signature or checksum
verification step for the helper payload itself. This is the main remaining security gap.

The same warning applies to trusted-input overrides:

- `--source-dir` is for trusted local development and tests only.
- `BUILDISH_NO_GRADLE_WRAPPER_JAR_BASE_URL` is trusted input, not an untrusted user setting.

### CI bootstrap path

The repository's own CI bootstrap is in better shape than before:

- GitHub Actions are pinned by SHA.
- Workflow permissions stay minimal.
- The Gradle distribution ZIP is checked against the official SHA-256 file before use.
- Windows CI keeps the fast direct GnuPG installer download path, but only after verifying the
  downloaded `.exe` against repo-pinned signature material in `.github/signatures/`.
- That Windows CI check imports the repo-pinned `signature_key.asc`, verifies the repo-pinned
  detached `.sig`, and requires the expected valid signer fingerprint
  `6DAA6E64A76D2840571B4902528897B826403ADA`.

## Scope

This assessment reviewed the full repository, with primary focus on:

- `buildish-no-gradle-wrapper-jar.sh`
- `buildish-no-gradle-wrapper-jar.ps1`
- `install.sh`
- `install.ps1`
- `buildish-no-gradle-wrapper-jar.init.gradle.kts`
- `.github/workflows/ci.yml`
- `scripts/rat-check.sh`
- integration test scripts

## Executive summary

No critical vulnerability was found in the normal helper runtime path for recreating
`gradle-wrapper.jar`.

The strongest security property in this repository is that the runtime helpers do
not trust a cached or downloaded wrapper JAR unless it:

1. matches the expected SHA-256 value, and
2. verifies against a pinned Gradle signing key fingerprint in an isolated GPG home.

That substantially reduces the risk of accepting a poisoned `gradle-wrapper.jar`
from the project-local cache or from the network.

The main residual security issue is earlier in the bootstrap chain: the installers
download helper files from `raw.githubusercontent.com` without a checksum or
signature verification step. If that bootstrap source, its TLS trust, or the
installer's source-selection environment variables are compromised, the result is
arbitrary code execution in the developer or CI context.

## Operator guidance

- Prefer the reviewed local-copy installer flow over remote pipe-to-shell execution.
- Treat `--source-dir` and base-URL overrides as trusted-development-only inputs.
- On Windows, use a native Windows GnuPG build for `gradlew.bat` verification. The helper
  intentionally rejects the Git-for-Windows bundled `gpg.exe`.
- Expect timeout failures to be explicit now; a hung PowerShell download should fail with a timeout
  error instead of waiting forever.

## Positive security properties

- `distributionUrl` is restricted to canonical `https://services.gradle.org/...`
  forms with numeric-only version parsing.
- The helper verifies detached signatures using a pinned public key fingerprint.
- GPG verification runs in a fresh temporary home and disables auto key retrieval.
- Corrupt cached JARs are deleted before redownload.
- Metadata and JAR downloads use temp files and move into place only after success.
- PowerShell download paths fail within explicit time bounds instead of waiting indefinitely.
- Installers reject symlinks / reparse points instead of following them.
- Windows helper execution rejects Git-for-Windows GPG and requires native Windows GnuPG.
- GitHub Actions are pinned by SHA and use `persist-credentials: false`.
- CI verifies the downloaded Gradle distribution against the official SHA-256 file.
- Windows CI verifies the fast direct GnuPG installer download against repo-pinned OpenPGP
  signature material before extraction.
- Workflow permissions are minimal (`contents: read` by default).

## Findings

### 1. Medium: installer bootstrap downloads are not cryptographically pinned

Affected files:

- `install.sh`
- `install.ps1`

The installers currently download helper files from:

- `https://raw.githubusercontent.com/apache/buildish/main/tools/buildish-no-gradle-wrapper-jar/...`

Those downloads are not verified with a checksum, detached signature, or release
archive signature.

> [!NOTE]
> The installation method is expected to be hardened further with the first release of this
> component by moving the installer bootstrap from raw helper downloads to a signed release asset.

Impact:

- If the bootstrap download source is compromised, or if the caller intentionally or
  accidentally points `--source-dir` at an untrusted origin, attacker-controlled helper
  code can be installed.
- That helper code is then executed automatically by `gradlew` / `gradlew.bat`.
- Successful exploitation would allow arbitrary code execution and therefore secret
  or credential theft in the current user or CI job context.

Notes:

- This is the most important security weakness in the repository.
- The runtime helper itself is substantially better protected than the installer
  bootstrap path.

Recommendation:

- Distribute a signed release artifact or a checksummed release bundle and make the
  installers verify it before staging files.
- Treat `--source-dir` as a trusted-development-only flag; it bypasses the download path
  and installs files directly from a local directory without additional verification.

### 2. Informational: local write access to the project implies full compromise

Affected files:

- project-local helper scripts under `gradle/`
- `gradlew` / `gradlew.bat`
- `build.gradle*`, `settings.gradle*`, init scripts, and wrapper properties

This is not a bug in this repository; it is a trust-boundary statement.

If an attacker can already modify files in the checked-out project, they can cause
arbitrary code execution through ordinary Gradle or launcher mechanisms regardless
of the wrapper-JAR verification logic.

That means the relevant question is not whether a malicious local collaborator could
eventually run code, but whether they can do so *without* modifying obvious code or
launcher files. In the reviewed design, the answer appears to be no.

## Direct answers to the threat questions

### Are there issues that could lead to security incidents?

Yes.

The main realistic issue is the installer bootstrap trust gap: helper files are
downloaded without cryptographic pinning. Under compromise of that source, this can
lead to arbitrary code execution and subsequent credential theft.

Outside that bootstrap issue, no direct vulnerability was found that would let a
network attacker bypass the helper's runtime JAR verification checks.

### Is it possible to poison the cache contents?

Partially, but not in the way that would silently subvert trust.

- An attacker with local write access can corrupt or replace cached files in
  `gradle/wrapper/`.
- The helper will reject malformed checksum files, malformed signature files, and
  wrapper JARs whose checksum or detached signature verification fails.
- Therefore, persistent cache poisoning that results in an *accepted malicious*
  `gradle-wrapper.jar` does not appear feasible without one of these stronger
  assumptions:
  - compromise of the pinned Gradle signing key,
  - compromise of trusted helper code itself,
  - or compromise of the installer/bootstrap source before the trusted helper is in place.

So:

- **malicious accepted JAR via cache poisoning:** not found
- **local DoS by corrupting cache files:** yes

### Is arbitrary code execution possible?

Yes, under the following conditions:

1. if the installer bootstrap source is compromised or redirected, or
2. if an attacker already has write access to the checked-out project or its local
   helper files, or
3. if a trusted execution environment intentionally provides an untrusted
   `BUILDISH_NO_GRADLE_WRAPPER_JAR_BASE_URL` or source directory override.

No arbitrary-code-execution path was found in the reviewed helper runtime logic that
would allow an untrusted cached/downloaded wrapper JAR to be accepted without
passing the checksum and detached-signature validation steps.

### Is secret / credential stealing possible?

Not through any built-in exfiltration path in the reviewed code.

However, any successful arbitrary code execution in the developer shell or CI job
would make secret theft possible, including:

- environment variables
- Git credentials
- Gradle repository credentials
- cloud credentials exposed to the current process
- files readable by the current user

So the answer is:

- **direct secret-stealing behavior in the current code:** not found
- **secret theft after compromise of bootstrap/install or local project files:** yes

## Overall conclusion

The runtime verification design for `gradle-wrapper.jar` is strong and appears to
prevent silent acceptance of poisoned cached JAR contents under the normal threat
model.

The most important remaining risk is the unsigned installer/bootstrap path. Outside
that gap, the runtime helper, launcher patching, CI bootstrap, and current operator
guidance are in good shape for this stage of the project.