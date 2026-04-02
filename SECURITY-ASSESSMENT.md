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

# Security assessment

Date: 2026-04-01

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

## Positive security properties

- `distributionUrl` is restricted to canonical `https://services.gradle.org/...`
  forms with numeric-only version parsing.
- The helper verifies detached signatures using a pinned public key fingerprint.
- GPG verification runs in a fresh temporary home and disables auto key retrieval.
- Corrupt cached JARs are deleted before redownload.
- Metadata and JAR downloads use temp files and move into place only after success.
- Installers reject symlinks / reparse points instead of following them.
- GitHub Actions are pinned by SHA and use `persist-credentials: false`.
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
> The installation method will be hardened with the first release of this component.
> See [`release-work.md`](./release-work.md) for details.

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

### 2. Low: CI installs Gradle over HTTPS without checksum verification

Affected file:

- `.github/workflows/ci.yml`

The CI workflow downloads `gradle-8.14.4-bin.zip` directly and installs it without
verifying an official checksum or signature.

Impact:

- A compromise of the download path for that CI bootstrap step could execute
  attacker-controlled Gradle code inside CI.
- The workflow permissions are relatively constrained, which limits blast radius,
  but this is still avoidable supply-chain exposure.

Recommendation:

- Verify the Gradle distribution checksum in CI before unpacking it.

### 3. Informational: local write access to the project implies full compromise

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

The most important remaining risk is the unsigned installer/bootstrap path. If that
is hardened, the repository's security posture becomes materially stronger.