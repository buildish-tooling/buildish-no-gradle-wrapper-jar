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

Date: 2026-04-07

This page is the user-facing summary of the current security and trust model for the
`no-gradle-wrapper-jar` blueprint.

For the planned hardened installer delivery model, see:

- [Secure installer bootstrap approach](../secure-installer-approach/)

For the full repository-level assessment, findings, and threat-model answers, see:

- [Full security assessment](https://github.com/apache/buildish-no-gradle-wrapper-jar/blob/main/SECURITY-ASSESSMENT.md)

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

`install.sh` and `install.ps1` are now trusted-local-only stagers.

They no longer download helper files from the network. Instead, they require
`--trusted-source-dir` and only copy already-trusted local payloads into the target project.

That means the remaining open work is not inside `install.*` anymore. The repository now also ships
tiny, reviewable `bootstrap-install.*` verifier scripts, but the checked-in copies are release
templates on purpose. They fail closed until a release step renders hard-coded release URLs and the
pinned signing-key material described in the dedicated
[`secure-installer-approach`](../secure-installer-approach/) page.

The same warning applies to trusted-input overrides:

- `--trusted-source-dir` is for trusted local development, verified bootstrap handoff, and tests only.

This is an explicit trust-boundary assumption: if an attacker can already write the checked-out
project or execute code in the same user or CI context, that security boundary is already gone for
that checkout and execution context. In that model, `--trusted-source-dir` is acceptable as a
trusted caller input, but it is not safe as an untrusted user-controlled input.

There is also an intentionally unsafe development-only shortcut:

- `unsafe-dev-install.sh`
- `unsafe-dev-install.ps1`

Those scripts download and execute unverified development-branch content on purpose. They require a
mandatory `--yes-i-know-this-is-unsafe` acknowledgement and refuse to run in common CI
environments. They are not part of the secure installer story.

### CI bootstrap path

The repository's own CI bootstrap is in better shape than the installer bootstrap path:

- GitHub Actions are pinned by SHA.
- Workflow permissions stay minimal.
- The Gradle distribution ZIP is checked against the official SHA-256 file before use.
- Windows CI verifies the downloaded GnuPG installer before extraction.

## Operator guidance

- Prefer the reviewed local-copy installer flow over any remote execution shortcut.
- Treat `--trusted-source-dir` as a trusted-caller-only input.
- Treat checked-in `bootstrap-install.*` files as release templates. Only release-rendered copies
  with pinned URLs and signing-key material are meant for execution.
- Treat `unsafe-dev-install.*` as trusted-local-development-only scripts, never as CI or automation
  entrypoints.
- On Windows, use a native Windows GnuPG build for `gradlew.bat` verification. The helper
  intentionally rejects the Git-for-Windows bundled `gpg.exe`.
- Expect helper timeout failures to be explicit; a hung PowerShell helper download should fail with
  a timeout error instead of waiting forever.

## Current status

The runtime verification design for `gradle-wrapper.jar` is strong and appears to prevent silent
acceptance of poisoned cached JAR contents under the normal threat model.

The runtime verification design for `gradle-wrapper.jar` remains the strongest security property in
this repository.

`install.sh` and `install.ps1` no longer have a helper-download trust gap, and the repository now
contains the secure `bootstrap-install.*` verification logic. The remaining operational limitation is
that end users still need rendered release copies with real release URLs and ASF-managed signing-key
material before that path is fully shipped.

The repository now also ships explicit `unsafe-dev-install.*` shortcuts for people who consciously
want a blind-trust development path against the current main branch. Those scripts are intentionally
insecure, require an explicit acknowledgement flag, and refuse CI environments.