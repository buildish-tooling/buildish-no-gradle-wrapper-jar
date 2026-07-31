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

# Security assessment

Date: 2026-04-07

This document provides a repository-local copy of the current security assessment for the
`no-gradle-wrapper-jar` component.

For the planned hardened installer delivery model, see the dedicated
[secure installer bootstrap approach](site/pages/secure-installer-approach.md) document.

## Trust model

### Runtime helper path

The strongest trust boundary in this repository is the normal `gradlew` / `gradlew.bat` runtime
path.

Before the helper accepts `gradle/wrapper/gradle-wrapper.jar`, it requires all of these checks to
pass:

1. `distributionUrl` must use the canonical `https://services.gradle.org/distributions/...` shape.
2. The Gradle version is derived only from the validated distribution URL.
3. The project must commit exactly one reviewed lowercase `buildishWrapperJarSha256Sum` for that
   version.
4. The upstream wrapper checksum and detached signature are downloaded from
   `services.gradle.org`.
5. The downloaded checksum must agree with the project-owned pin.
6. The wrapper JAR bytes are downloaded from the matching Gradle source tag on GitHub.
7. The JAR must match the project-owned SHA-256 pin.
8. The detached signature must verify against pinned Gradle signing-key fingerprints in an isolated
   temporary GPG home.
9. Downloaded metadata and JAR files are written via temporary paths and only moved into place on
   success.
10. Valid-looking corrupt checksum/signature sidecars receive one paired refresh and full
    re-verification, but a cached JAR that also disagrees with the project pin remains a hard
    failure.

That means poisoned cache content or a corrupted download should fail closed instead of being
accepted silently.

### Installer bootstrap path

`install.sh` and `install.ps1` are now trusted-local-only stagers.

They no longer download helper files from the network. They require `--trusted-source-dir` and only
copy already-trusted local payloads into the target project.

The repository now also contains tiny `bootstrap-install.*` verifier templates described in
[site/pages/secure-installer-approach.md](site/pages/secure-installer-approach.md).

Those templates verify a signed per-platform payload manifest and then hand off via
`--trusted-source-dir`, but they intentionally fail closed until a release step renders real release
URLs, the exact signed-manifest SHA-256, and Buildish-managed signing-key material. The embedded
manifest digest selects the intended release payload set; the signature independently proves
publisher authorization.

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

The repository's own CI bootstrap is in better shape than before:

- GitHub Actions are pinned by SHA.
- Workflow permissions stay minimal.
- The Gradle distribution ZIP is checked against the official SHA-256 file before use.
- Windows CI keeps the fast direct GnuPG installer download path, but only after verifying the
  downloaded `.exe` against repo-pinned signature material in `.github/signatures/`.
- That Windows CI check imports the repo-pinned minimal allowed-signer key in
  `signature_key.asc`, verifies the repo-pinned detached `.sig`, and requires the expected valid
  signer fingerprint `6DAA6E64A76D2840571B4902528897B826403ADA`.

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

The strongest security property in this repository is that the runtime helpers do not trust a
cached or downloaded wrapper JAR unless it:

1. matches the reviewed project-owned SHA-256 pin,
2. agrees with Gradle's version-specific published checksum, and
3. verifies against a pinned Gradle signing key fingerprint in an isolated GPG home.

That substantially reduces the risk of accepting a poisoned `gradle-wrapper.jar` from the
project-local cache or from the network.

The main residual design limitation is earlier in the bootstrap chain: the secure, release-based
`bootstrap-install.*` verifier logic now exists in-repo, but rendered release copies, their exact
manifest digests, and the real Buildish-managed signing key are not operationally published yet.

The repository also ships explicit `unsafe-dev-install.*` shortcuts for people who consciously want
a blind-trust development flow against the current main branch. Those scripts are intentionally
insecure, require an explicit acknowledgement flag, and refuse CI environments.

## Operator guidance

- Prefer the reviewed local-copy installer flow over any remote execution shortcut.
- Treat `--trusted-source-dir` as a trusted-caller-only input.
- Treat `unsafe-dev-install.*` as trusted-local-development-only scripts, never as CI or automation
  entrypoints.
- On Windows, use a native Windows GnuPG build for `gradlew.bat` verification. The helper
  intentionally rejects the Git-for-Windows bundled `gpg.exe`.
- Expect helper and release-bootstrap timeout failures to be explicit instead of waiting forever.

## Positive security properties

- `distributionUrl` is restricted to canonical `https://services.gradle.org/...` forms with
  numeric-only version parsing.
- The helper verifies detached signatures using a pinned public key fingerprint.
- GPG verification runs in a fresh temporary home and disables auto key retrieval.
- Corrupt cached JARs are deleted before redownload.
- Metadata and JAR downloads use temp files and move into place only after success.
- Runtime helper and release-bootstrap downloads fail within explicit time bounds instead of
  waiting indefinitely.
- Bootstrap downloads enforce byte limits while streaming, including when a response omits
  `Content-Length`.
- Installers reject symlinks / reparse points instead of following them.
- `install.sh` and `install.ps1` no longer download helper payloads from the network.
- `bootstrap-install.*` verifies a detached signature over a per-platform payload manifest in an
  isolated temporary GPG home and requires that manifest to match the release-pinned SHA-256 before
  handing off to `install.*`.
- Checked-in `bootstrap-install.*` copies fail closed until release rendering substitutes the
  hard-coded release URL, manifest SHA-256, and pinned signing-key material.
- `unsafe-dev-install.*` requires an explicit `--yes-i-know-this-is-unsafe` acknowledgement.
- `unsafe-dev-install.*` refuses to run in common CI environments.
- Windows helper execution rejects Git-for-Windows GPG and requires native Windows GnuPG.
- GitHub Actions are pinned by SHA and use `persist-credentials: false`.
- CI verifies the downloaded Gradle distribution against the official SHA-256 file.
- Windows CI verifies the fast direct GnuPG installer download against repo-pinned OpenPGP
  signature material before extraction.
- Workflow permissions are minimal (`contents: read` by default).

## Findings

### 1. Informational: secure remote bootstrap still needs release rendering and publishing

Affecting area:

- release/install bootstrap workflow
- release automation and signing operations

> [!NOTE]
> `install.sh` and `install.ps1` are already local-only stagers, and `bootstrap-install.*` verifier
> logic now exists in-repo. The remaining missing piece is release-time rendering/publishing with
> real URLs, exact per-platform manifest digests, and Buildish-managed signing-key material.

Impact:

- Users do not yet have published, release-rendered `bootstrap-install.*` scripts bound to immutable
  release URLs, the exact signed manifest, and the real signing key.
- Until that exists, users must either use the reviewed local-copy/manual-verification path or the
  explicitly unsafe `unsafe-dev-install.*` development shortcut.

Notes:

- This is no longer a missing verifier implementation inside the repository.
- The remaining gap is release rendering/publishing and signing-key operations, not a hidden
  download path inside `install.*`.
- The runtime helper itself remains substantially better protected than any bootstrap convenience
  path.

Recommendation:

- Wire release automation so it renders and publishes `bootstrap-install.*` with hard-coded release
  URLs, the exact per-platform manifest SHA-256, and the real signing-key material described in
  [site/pages/secure-installer-approach.md](site/pages/secure-installer-approach.md).
- Manage and publish the Buildish-controlled signing key and supporting `KEYS`
  material for operators.
- Keep `install.*` as trusted-local-only stagers.
- Keep `unsafe-dev-install.*` loudly unsafe, opt-in, and blocked in CI.

### 2. Informational: explicit unsafe development bootstrap remains dangerous outside trusted local development

Affected files:

- `unsafe-dev-install.sh`
- `unsafe-dev-install.ps1`

The repository intentionally ships development-only shortcuts that download and execute unverified
main-branch content.

Impact:

- If a caller uses `unsafe-dev-install.*` in CI, automation, or an environment with secrets, that is
  a deliberate arbitrary-code-execution risk in that environment.

Notes:

- The scripts require `--yes-i-know-this-is-unsafe`.
- The scripts refuse to run when common CI environment markers are present.
- They are intentionally separated from the secure installer story and should stay that way.

Recommendation:

- Keep the docs explicit that `unsafe-dev-install.*` is for trusted local development only.
- Keep the CI barrier and mandatory acknowledgement flag intact.

### 3. Informational: local write access to the project implies full compromise

Affected files:

- project-local helper scripts under `gradle/`
- `gradlew` / `gradlew.bat`
- `build.gradle*`, `settings.gradle*`, init scripts, and wrapper properties

This is not a bug in this repository; it is a trust-boundary statement.

If an attacker can already modify files in the checked-out project, they can cause arbitrary code
execution through ordinary Gradle or launcher mechanisms regardless of the wrapper-JAR verification
logic.

That means the relevant question is not whether a malicious local collaborator could eventually run
code, but whether they can do so *without* modifying obvious code or launcher files. In the
reviewed design, the answer appears to be no.

## Direct answers to the threat questions

### Are there issues that could lead to security incidents?

Yes.

The main realistic remaining issue is misuse of intentionally unsafe bootstrap shortcuts or of
trusted-local inputs. `install.*` itself no longer performs unverified helper downloads.

Outside those explicit bootstrap-trust choices, no direct vulnerability was found that would let a network attacker
bypass the helper's runtime JAR verification checks.

### Is it possible to poison the cache contents?

Partially, but not in the way that would silently subvert trust.

- An attacker with local write access can corrupt or replace cached files in `gradle/wrapper/`.
- The helper will reject malformed checksum files, malformed signature files, and wrapper JARs
  whose checksum disagrees with the reviewed project pin or whose detached signature verification
  fails.
- Therefore, persistent cache poisoning that results in an *accepted malicious* `gradle-wrapper.jar`
  does not appear feasible without one of these stronger assumptions:
  - compromise of the pinned Gradle signing key,
  - compromise of trusted helper code itself,
  - or compromise of the installer/bootstrap source before the trusted helper is in place.

So:

- **malicious accepted JAR via cache poisoning:** not found
- **local DoS by corrupting cache files:** yes

### Is arbitrary code execution possible?

Yes, under the following conditions:

1. if a caller intentionally uses the explicit `unsafe-dev-install.*` blind-trust path, or
2. if an attacker already has write access to the checked-out project or its local helper files, or
3. if a trusted execution environment intentionally provides an untrusted
   `--trusted-source-dir` override.

No arbitrary-code-execution path was found in the reviewed helper runtime logic that would allow an
untrusted cached/downloaded wrapper JAR to be accepted without passing the project pin, upstream
checksum, and detached-signature validation steps.

### Is secret / credential stealing possible?

Not through any built-in exfiltration path in the reviewed code.

However, any successful arbitrary code execution in the developer shell or CI job would make secret
theft possible, including:

- environment variables
- Git credentials
- Gradle repository credentials
- cloud credentials exposed to the current process
- files readable by the current user

So the answer is:

- **direct secret-stealing behavior in the current code:** not found
- **secret theft after compromise of bootstrap/install or local project files:** yes

## Overall conclusion

The runtime verification design for `gradle-wrapper.jar` binds the selected Gradle version to a
reviewed project-owned digest and appears to prevent silent acceptance of poisoned or replayed
cached JAR contents under the normal threat model.

The most important remaining work is operationalizing the secure release-based
`bootstrap-install.*` path by rendering and publishing release-specific copies with exact manifest
digests and real signing material. Outside that, the runtime helper, launcher patching, bootstrap
verifier implementation, CI bootstrap, and current operator guidance are in good shape, while
`unsafe-dev-install.*` stays an explicitly insecure development-only escape hatch.
