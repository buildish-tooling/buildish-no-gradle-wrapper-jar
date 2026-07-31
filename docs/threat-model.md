---
title: "Threat model"
description: Threat boundaries, security properties, and triage dispositions for the no-gradle-wrapper-jar blueprint.
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

# Threat Model: Buildish no-gradle-wrapper-jar

Authority and version binding: this is the canonical threat model for this component. It is versioned
alongside the repository and must be included with project releases. A report against project
version N is triaged against the model shipped with N, not against later `main` branch content.
*(maintainer)*

Implementation review baseline: `2748f332c2b1de75f8a42b18ee71fcb69e63ab2a`. *(maintainer)*

Security-sensitive content digest: `4715bb92c2885f12c2b7c9d5a0f2c19e390b57db`. The digest covers the paths declared in
`scripts/security-model-inputs.txt` and is enforced by `make security-model-check`. *(documented)*

Last maintainer review: 2026-07-31. *(maintainer)*

Status: ratified. Changes to declared security-sensitive surfaces require this model to be reviewed
and its content digest updated. *(maintainer)*

Reporting cross-reference: suspected findings that violate the claimed properties in [§8](#8-security-properties-the-project-provides) should be reported per the [Buildish security policy](https://buildish.org/community/security/); findings that fall under [§3](#3-out-of-scope-explicit-non-goals) or [§9](#9-security-properties-the-project-does-not-provide) may be closed citing this document. *(documented)*

Provenance legend: *(documented)* means verified in repository code, tests, or documentation;
*(maintainer)* means an explicit scope, policy, or design decision; *(inferred)* means contextual
analysis derived from the implementation rather than a separately enforced security property. The
model is ratified as a whole; provenance labels preserve the basis for each statement.

Review coverage: the component scope, trust boundaries, claimed and disclaimed properties, triage
dispositions, and former open questions were reviewed on the date above. *(maintainer)*

Buildish no-gradle-wrapper-jar is a copyable helper blueprint for Gradle projects that want to keep
using `gradlew` / `gradlew.bat` without committing `gradle/wrapper/gradle-wrapper.jar`. It installs
project-local helper scripts, patches generated Gradle launchers, recreates the wrapper JAR at
runtime from Gradle-controlled upstream sources, verifies the JAR with checksum and detached OpenPGP
signature material plus a project-owned version-to-artifact digest pin, and keeps that pin and the
launcher patches present when the Gradle `Wrapper` task regenerates project files. *(documented)*

## 2 Scope And Intended Use

Primary intended use cases:

- Install the helper into an existing Gradle project from a reviewed local copy or verified bootstrap payload. *(documented)*
- Run `gradlew` / `gradlew.bat` without a checked-in `gradle/wrapper/gradle-wrapper.jar`. *(documented)*
- Recreate and verify `gradle-wrapper.jar` before Gradle starts. *(documented)*
- Re-patch generated `gradlew` and `gradlew.bat` files after the Gradle `Wrapper` task runs. *(documented)*
- Provide explicitly unsafe development shortcuts for users who intentionally accept unverified current-branch code. *(documented)*

Deployment contexts:

- Project-local POSIX shell helper sourced by `gradlew`. *(documented)*
- Project-local PowerShell helper invoked by `gradlew.bat`. *(documented)*
- POSIX and PowerShell installer scripts run manually or by a verified bootstrap script. *(documented)*
- Release-rendered POSIX and PowerShell bootstrap verifier scripts. *(documented)*
- Gradle init script run inside the target Gradle process. *(documented)*
- Repository CI and release support files used by maintainers. *(inferred)*

Caller expectations:

- The developer, release engineer, or CI job running an installed `gradlew` / `gradlew.bat` is trusted to execute the target project's Gradle build. *(documented)*
- The installer operator is trusted to choose a trustworthy `--trusted-source-dir`; this parameter is not safe for untrusted user control. *(documented)*
- A release-rendered bootstrap user is not expected to trust the network payload before the bootstrap verifier checks the release-pinned manifest digest, signed manifest, and payload checksums. *(documented)*
- A caller who uses `unsafe-dev-install.*` is explicitly accepting unverified remote code execution from the development branch. *(documented)*
- A network peer serving Gradle metadata, signatures, or JAR bytes is untrusted until artifacts satisfy the helper's validation steps. *(documented)*

Component-family table:

| Family | Representative entry point | External effects | In model? |
| --- | --- | --- | --- |
| Runtime POSIX helper | `buildish-no-gradle-wrapper-jar.sh`, sourced by `gradlew` | Reads wrapper properties and cache files; downloads checksum, signature, and JAR; writes cache files; invokes `gpg`; emits stderr; prepends Gradle init-script args | Yes |
| Runtime Windows helper | `buildish-no-gradle-wrapper-jar.ps1`, invoked by `gradlew.bat` | Reads wrapper properties and cache files; downloads checksum, signature, and JAR; writes cache files; invokes native Windows `gpg.exe`; emits command fragment to stdout and errors to stderr | Yes |
| Local-copy installers | `install.sh`, `install.ps1` | Reads trusted source directory; copies helper files; removes wrapper JAR; patches launchers; edits `.gitignore`; rejects symlink/reparse-point targets | Yes |
| Release bootstrap templates | `bootstrap-install.sh`, `bootstrap-install.ps1` | Download release payloads and signed manifests; verify the release-pinned manifest digest, pinned signing key, and payload checksums; hand off to installer via `--trusted-source-dir` | Yes, for template behavior and release-rendered intended behavior |
| Unsafe development installers | `unsafe-dev-install.sh`, `unsafe-dev-install.ps1` | Download current-branch helper payloads without verification; execute installer; refuse common CI environments; support remote base URL override | In model only as intentionally unsafe / disclaimed behavior |
| Gradle init script | `buildish-no-gradle-wrapper-jar.init.gradle.kts` | Hooks Gradle `Wrapper` task; preserves the reviewed wrapper-JAR pin; reads/writes generated launchers; warns on version changes and missing `distributionSha256Sum` | Yes |
| Site/docs/security assessment | `site/`, `docs/`, `SECURITY-ASSESSMENT.md`, `SECURITY.md` | Documentation only | Yes, as security contract and operator guidance |
| Tests and test fixtures | `tests/`, `scripts/rat-check.sh` | Local test execution; filesystem mutations under test workspaces | Out of scope for product security, in scope for validation evidence |
| Maintainer CI/release workflows | `.github/`, `buildish-release-tooling/` | GitHub Actions, release preparation, external tool downloads | Partially in scope for supply-chain assumptions; not an end-user runtime surface |
| Generated/local build outputs | `build/` | Generated artifacts and downloaded test/check tooling | Out of scope |

## 3 Out Of Scope: Explicit Non-Goals

- This project is not a sandbox for untrusted Gradle builds. If the target project's build files or launcher scripts are malicious, Gradle execution can run arbitrary code. *(documented)*
- This project does not protect a checkout after an attacker can modify project-local helper scripts, `gradlew`, `gradlew.bat`, Gradle build files, or wrapper properties. *(documented)*
- This project does not authenticate or validate the Gradle distribution ZIP itself beyond warning when `distributionSha256Sum` is absent; distribution ZIP pinning remains a target-project responsibility. *(documented)*
- This project does not make `--trusted-source-dir` safe for untrusted input. *(documented)*
- This project does not make `unsafe-dev-install.*` safe for CI, automation, or secret-bearing environments. *(documented)*
- This project does not defend against compromise of the pinned Gradle signing key or a correctly signed malicious Gradle wrapper JAR. *(documented)*
- This project does not defend against compromise of release-signing keys used to sign bootstrap payload manifests. *(inferred)*
- This project does not defend against a malicious or compromised `gpg`, `curl`, `wget`, `sha256sum`, `shasum`, PowerShell runtime, JVM, shell, or operating system on the caller's host. *(inferred)*
- This project does not provide network confidentiality or availability for downloads from Gradle, GitHub, or release hosting endpoints. *(inferred)*
- This project does not guarantee launcher patching for arbitrary future Gradle launcher shapes; unsupported shapes fail closed until explicitly supported. *(documented)*
- This project does not treat tests, fixtures, generated files, or local build outputs as product surfaces with independent security guarantees. *(inferred)*
- Repository files under `build/` are generated/local outputs and are not covered by this model. *(documented)*

## 4 Trust Boundaries And Data Flow

Primary trust boundary:

- The runtime helper boundary is between untrusted local cache/downloaded bytes and the accepted `gradle/wrapper/gradle-wrapper.jar`. The helper accepts the JAR only after its digest matches the project-owned `buildishWrapperJarSha256Sum`, the Gradle-published checksum agrees with that pin, and the detached signature verifies against the pinned Gradle public key in an isolated temporary GPG home. *(documented)*

Runtime helper data flow:

1. `gradlew` / `gradlew.bat` resolves `APP_HOME` / `%APP_HOME%` and invokes the helper. *(documented)*
2. The helper reads `gradle/wrapper/gradle-wrapper.properties`. *(documented)*
3. The helper accepts only canonical `https://services.gradle.org/distributions/gradle-<numeric-version>-bin.zip` or `...-all.zip` distribution URLs. *(documented)*
4. The helper derives the Gradle version from that validated URL. *(documented)*
5. The helper requires exactly one canonical lowercase `buildishWrapperJarSha256Sum` in the reviewed project configuration. *(documented)*
6. The helper downloads or reuses per-version checksum and detached-signature files. *(documented)*
7. The upstream checksum must equal the project-owned pin before wrapper-JAR acceptance continues. *(documented)*
8. The helper downloads or reuses `gradle-wrapper.jar`. *(documented)*
9. The helper rejects malformed, oversized, symlinked, pin-mismatched, checksum-mismatched, or signature-mismatched artifacts. *(documented)*
10. Only after validation does the launcher continue to Java/Gradle with the wrapper JAR in place. *(documented)*

Installer data flow:

1. The operator invokes `install.sh` or `install.ps1` with `--trusted-source-dir`. *(documented)*
2. The installer resolves the target project and trusted source directory. *(documented)*
3. It requires one canonical project-owned wrapper-JAR pin before mutation. *(documented)*
4. It copies helper files from the trusted local directory into `gradle/`. *(documented)*
5. It removes an existing regular `gradle/wrapper/gradle-wrapper.jar`. *(documented)*
6. It patches `gradlew` / `gradlew.bat` at exact known anchors and edits `.gitignore`. *(documented)*
7. It rejects symlink/reparse-point paths rather than following them. *(documented)*

Bootstrap data flow:

1. A release-rendered bootstrap script downloads the platform payload set and checksum manifest. *(documented)*
2. It checks strict byte limits for payloads and metadata. *(documented)*
3. It requires the downloaded manifest to match the exact SHA-256 embedded during release rendering. *(documented)*
4. It downloads the detached manifest signature and verifies the pinned signing-key fingerprint/key material and signature in an isolated GPG home. *(documented)*
5. It verifies each downloaded payload against the release-selected signed manifest. *(documented)*
6. It invokes the local installer with `--trusted-source-dir` pointing at the verified payload directory. *(documented)*

Reachability preconditions:

| Component family | In-model finding must be reachable through |
| --- | --- |
| Runtime POSIX helper | A `gradlew` execution path where attacker-controlled cache/download/wrapper-property data influences acceptance of `gradle-wrapper.jar`, helper resource use, or launcher arguments |
| Runtime Windows helper | A `gradlew.bat` execution path where attacker-controlled cache/download/wrapper-property data influences acceptance of `gradle-wrapper.jar`, helper resource use, or emitted batch arguments |
| Local-copy installers | A caller invoking installer scripts against a target project with attacker-influenced target files or source-directory paths, excluding attacker control of `--trusted-source-dir` when marked trusted |
| Release bootstrap templates | A release-rendered bootstrap execution path where attacker-controlled network bytes are accepted before signed-manifest and checksum verification |
| Unsafe development installers | Only the explicit safety barriers and warnings, not the intentionally unverified download/execute behavior |
| Gradle init script | A Gradle `Wrapper` task execution where launcher patching, unsupported launcher shapes, or missing checksum warnings are affected |
| CI/release workflows | Maintainer-controlled workflows insofar as they establish trust in repository release or CI validation artifacts |

## 5 Assumptions About The Environment

Operating system and runtime assumptions:

- POSIX helper and installer assume a POSIX shell plus required commands. *(documented)*
- POSIX runtime helper requires `curl`, `gpg`, `mktemp`, and either `sha256sum` or `shasum`. *(documented)*
- POSIX bootstrap requires `curl` or `wget`, `gpg`, and either `sha256sum` or `shasum`. *(documented)*
- PowerShell helper requires PowerShell, `Invoke-WebRequest` / .NET HTTP support, `Get-FileHash`, and native Windows GnuPG for Windows batch verification. *(documented)*
- The PowerShell helper resolves the conventional `gpg` application directly
  on non-Windows hosts. On Windows it considers `gpg.exe` and `gpg` application
  candidates while applying the Git-for-Windows rejection below. *(documented)*
- The Windows helper intentionally rejects Git-for-Windows bundled GPG for `gradlew.bat` verification. *(documented)*
- The host OS, shell, PowerShell runtime, GnuPG, checksum tools, network stack, filesystem, and JVM are trusted to behave according to their documented semantics. *(inferred)*

Concurrency assumptions:

- The helper validates or normalizes downloaded metadata on unpublished
  temporary paths before moving it into place; later cached checksum validation
  is read-only. *(documented)*
- Concurrent `gradlew` executions in the same checkout are not documented as a supported synchronization scenario. *(inferred)*
- Installer patching is intended to be idempotent, but concurrent installer runs against the same checkout are not documented as supported. *(inferred)*

Filesystem assumptions:

- Target project files are ordinary files/directories unless explicitly absent; symlinks/reparse points at managed paths are rejected. *(documented)*
- Temporary files are created in the wrapper directory, target directory, or OS temp directory, depending on the component. *(documented)*
- Atomicity relies on same-filesystem moves where the scripts create temporary files adjacent to destinations. *(documented)*
- The caller's user account has permission to read/write the target project and create temporary files. *(inferred)*

Network assumptions:

- Gradle metadata and signatures are downloaded from `services.gradle.org`. *(documented)*
- Runtime wrapper JAR bytes are downloaded from the matching Gradle source tag on GitHub raw content. *(documented)*
- Release bootstrap payload URLs are hard-coded in release-rendered bootstrap scripts. *(documented)*
- Network responses are untrusted until cryptographic and checksum validation succeeds. *(documented)*
- Network availability is not guaranteed; failed or stalled downloads are expected to fail explicitly. *(documented)*

No-surprise side effects:

- Runtime helpers read environment variables needed by launchers and
  `BUILDISH_NO_GRADLE_WRAPPER_JAR_HTTP_TIMEOUT_SECONDS`; bootstrap installers read
  `BUILDISH_BOOTSTRAP_INSTALL_HTTP_TIMEOUT_SECONDS`. *(documented)*
- Unsafe development installers read `BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL` and CI marker environment variables. *(documented)*
- Helpers and installers write to stdout/stderr for command fragments, warnings, and errors. *(documented)*
- Runtime helpers and bootstraps spawn `gpg`; shell variants spawn common utilities such as `curl`, `wget`, `sed`, `awk`, `grep`, `wc`, `tr`, `mktemp`, and checksum commands. *(documented)*
- The project does not intentionally open listening sockets, install signal handlers beyond shell traps for cleanup, mutate global locale/FPU state, or modify files outside the target project and temporary directories. *(inferred)*

## 5a Build-Time And Configuration Variants

| Knob / variant | Default | Effect on model | Maintainer stance |
| --- | --- | --- | --- |
| `BUILDISH_NO_GRADLE_WRAPPER_JAR_HTTP_TIMEOUT_SECONDS` | `60` seconds | Changes POSIX and Windows helper network timeouts. Invalid or non-positive values fail. Larger values extend time before availability failure. | Supported runtime configuration. *(documented)* |
| `BUILDISH_BOOTSTRAP_INSTALL_HTTP_TIMEOUT_SECONDS` | `60` seconds | Changes release-bootstrap download timeouts. Invalid or non-positive values fail. Larger values extend time before availability failure. | Supported bootstrap configuration. *(documented)* |
| `BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL` | Buildish `main` branch raw URL | Changes the remote source for unsafe development installers. This can redirect blind-trust execution. | Development-only unsafe escape hatch; not for CI, automation, or secrets. *(documented)* |
| Checked-in `bootstrap-install.*` placeholders | Placeholder URL/manifest-digest/key material with hard fail | Repository templates intentionally fail closed until release rendering substitutes immutable URLs, the exact manifest digest, and signing trust material. | Template copies are not intended for direct execution. *(documented)* |
| Release-rendered `bootstrap-install.*` | Not yet operationally published in this repository copy | Establishes verified remote installer delivery if rendered with pinned release URL, exact signed-manifest digest, and signing key material. | Planned/hardened path; publication is remaining release work. *(documented)* |
| Native Windows GPG vs Git-for-Windows GPG | Native Windows GPG required | Git-for-Windows GPG is rejected; without native GPG, Windows helper verification fails. | Required for Windows `gradlew.bat`. *(documented)* |
| Gradle wrapper `distributionSha256Sum` | Target-project dependent | Missing value weakens Gradle distribution ZIP pinning, but not wrapper-JAR verification. The init script warns if absent. | Caller responsibility; warning only. *(documented)* |
| Buildish wrapper JAR `buildishWrapperJarSha256Sum` | Required project-owned lowercase SHA-256 | Binds the requested Gradle version to the exact accepted wrapper JAR. Missing, duplicate, malformed, or mismatched values fail closed. | Required reviewed project configuration. *(documented)* |
| Future Gradle launcher shapes | Exact known anchors only | Unsupported shapes cause installer/init patch failures rather than best-effort mutation. | Fail closed pending explicit support. *(documented)* |

No compile-time build flags change security properties; this project is distributed as scripts and documentation. *(inferred)*

## 6 Assumptions About Inputs

The project accepts these inputs:

- Target project files: `gradlew`, `gradlew.bat`, `gradle/wrapper/gradle-wrapper.properties` including the project-owned wrapper-JAR pin, `.gitignore`, and `gradle/` contents. *(documented)*
- Trusted local source-directory payloads passed to `install.*`. *(documented)*
- Network payloads from Gradle, GitHub, and release asset hosting. *(documented)*
- Environment variables for timeout, unsafe dev base URL, CI detection, and normal launcher state. *(documented)*
- Gradle `Wrapper` task-generated launcher files. *(documented)*

Per-parameter trust table:

| Entry point | Parameter / input | Attacker-controllable? | Caller must enforce |
| --- | --- | --- | --- |
| `buildish-no-gradle-wrapper-jar.sh` | `APP_HOME` inherited from `gradlew` | No, trusted launcher state after `gradlew` resolution | Do not let untrusted users replace launchers or helper files |
| `buildish-no-gradle-wrapper-jar.sh` | `gradle-wrapper.properties` `distributionUrl` | Partially; target project maintainers can edit it, network attackers cannot | Treat project-file write access as trusted; use canonical Gradle distribution URLs |
| POSIX and PowerShell runtime helpers | `gradle-wrapper.properties` `buildishWrapperJarSha256Sum` | No under the local-cache/network attacker model; it is reviewed project configuration | Update atomically with `distributionUrl`; use the Gradle-published Wrapper JAR checksum, not the distribution ZIP checksum |
| `buildish-no-gradle-wrapper-jar.sh` | Cached `.sha256`, `.asc`, and `.jar` files under `gradle/wrapper/` | Yes for local cache corruption scenarios | Helper validates or rejects; caller must protect checkout from untrusted writers |
| `buildish-no-gradle-wrapper-jar.sh` | Downloaded checksum and signature metadata | Yes, network bytes are untrusted | Helper enforces shape, size, checksum, and signature validation |
| `buildish-no-gradle-wrapper-jar.sh` | Downloaded wrapper JAR | Yes, network bytes are untrusted | Helper enforces 10 MiB limit, expected checksum, and detached signature validation |
| `buildish-no-gradle-wrapper-jar.ps1` | `%APP_HOME%` / current launcher context | No, trusted launcher state after `gradlew.bat` resolution | Do not let untrusted users replace launchers or helper files |
| `buildish-no-gradle-wrapper-jar.ps1` | `BUILDISH_NO_GRADLE_WRAPPER_JAR_HTTP_TIMEOUT_SECONDS` | Maybe, if environment is attacker-controlled | Keep environment trusted; helper rejects invalid values |
| `buildish-no-gradle-wrapper-jar.ps1` | Downloaded/cached checksum, signature, and JAR files | Yes | Helper enforces size, checksum, and detached signature validation |
| `install.sh` / `install.ps1` | `--trusted-source-dir` | No; explicitly trusted caller input | Point only to reviewed local copy or verified bootstrap payload directory |
| `install.sh` / `install.ps1` | Target project directory | Trusted operator chooses target, but target files may be attacker-influenced in local-collaboration scenarios | Run only in checkouts where modifying Gradle launchers is intended |
| `install.sh` / `install.ps1` | Existing launcher contents | Partially; generated by Gradle or edited by project maintainers | Unsupported shapes fail; review nonstandard launchers before install |
| `bootstrap-install.sh` / `bootstrap-install.ps1` | Release base URL, exact manifest SHA-256, and signing material | No at runtime in release-rendered scripts | Release process must render correct immutable URLs, selected manifest digest, and pinned key material before signing/publishing |
| `bootstrap-install.sh` / `bootstrap-install.ps1` | Downloaded payload files, manifests, signatures | Yes | Bootstrap verifies the release-pinned manifest digest, manifest signature, and payload checksums before handoff |
| `unsafe-dev-install.sh` / `unsafe-dev-install.ps1` | `--yes-i-know-this-is-unsafe` | Trusted user acknowledgement | Do not use unless blind-trust development flow is intended |
| `unsafe-dev-install.sh` / `unsafe-dev-install.ps1` | `BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL` | Yes if environment is attacker-controlled | Do not use unsafe installers in untrusted or secret-bearing environments |
| `unsafe-dev-install.sh` / `unsafe-dev-install.ps1` | Downloaded current-branch payloads | Yes | No validation is provided by design; do not use as secure path |
| `buildish-no-gradle-wrapper-jar.init.gradle.kts` | Generated properties and launcher files from `Wrapper` task | Partially; Gradle version controls content/shape | Existing pin is preserved, never recalculated; update it in the same reviewed change when `distributionUrl` changes |

Size, shape, and rate assumptions:

- Runtime metadata files are limited to 65,536 bytes. *(documented)*
- Runtime wrapper JAR files are limited to 10 MiB. *(documented)*
- Bootstrap payload files are limited to 262,144 bytes each. *(documented)*
- Bootstrap metadata/signature files are limited to 65,536 bytes each. *(documented)*
- POSIX and PowerShell runtime-helper downloads use a configurable timeout with a 60-second default. *(documented)*
- Request rate limiting is not provided; callers control how often helpers/installers run. *(inferred)*

## 7 Adversary Model

In-scope adversaries:

- A network attacker, proxy, mirror, or compromised download path that can return corrupt or malicious checksum, signature, manifest, or wrapper JAR bytes. *(documented)*
- A local attacker who can corrupt cached files under `gradle/wrapper/` but cannot alter trusted helper code, launchers, build files, or signing keys. *(documented)*
- A project collaborator or tool that changes `gradle-wrapper.properties` within the limits of ordinary project review. *(inferred)*
- A scanner, fuzzer, or AI tool producing findings against in-scope code paths. *(inferred)*

Out-of-scope adversaries:

- An attacker who can modify the checked-out project files that Gradle will execute. *(documented)*
- An attacker who can modify this helper's installed scripts before execution. *(documented)*
- An attacker who controls the process environment, PATH, shell, PowerShell runtime, `gpg`, checksum tools, or operating system. *(inferred)*
- An attacker who controls the pinned Gradle signing key or release signing key. *(documented)*
- An attacker who can persuade the operator to run `unsafe-dev-install.*` or provide an untrusted `--trusted-source-dir`; those are misuse cases, not bypasses. *(documented)*

Attacker goals:

- Cause a malicious `gradle-wrapper.jar` to be accepted and executed. *(documented)*
- Poison local cache contents so future runs execute attacker-controlled code. *(documented)*
- Cause denial of service by corrupting cache files, stalling downloads, exhausting resource limits, or forcing unsupported launcher shapes. *(documented)*
- Smuggle malicious bootstrap/installer payloads through the release bootstrap path. *(documented)*
- Convert an explicitly unsafe development flow into CI or secret-bearing execution. *(documented)*

## 8 Security Properties The Project Provides

| Property | Conditions | Violation symptom | Severity tier | Provenance |
| --- | --- | --- | --- | --- |
| Runtime helper accepts `gradle-wrapper.jar` only after project-owned pin match, agreement with the Gradle-published checksum, and detached signature verification against the pinned Gradle key | Helper code, reviewed project configuration, and host tools are trusted; distribution URL is canonical; pinned key remains valid | Wrong-version, malicious, or corrupted JAR is accepted and Gradle starts | Security-critical | documented |
| Project-owned wrapper-JAR pin is required and unambiguous | Exactly one lowercase 64-hex `buildishWrapperJarSha256Sum` is committed beside `distributionUrl` | Missing/malformed configuration or alternate parser interpretation bypasses version binding | Security-critical | documented |
| Canonical Gradle distribution URL restriction | `distributionUrl` must match `https://services.gradle.org/distributions/gradle-<numeric-version>-(bin|all).zip` | Noncanonical URL controls metadata/JAR derivation | Security-critical | documented |
| Gradle version is derived only from validated distribution URL | Wrapper properties are read by helper; regex accepts numeric versions only | Attacker controls version/source derivation independently of validated URL | Security-critical | documented |
| Runtime metadata and JAR downloads fail closed on malformed, oversized, checksum-mismatched, or signature-mismatched content | Host tools operate correctly; limits are enforced | Build fails before Gradle starts | Security-critical | documented |
| Existing corrupt cached wrapper JAR is deleted/replaced and not silently accepted | Local cache corruption does not include helper-code modification | Accepted malicious JAR from cache | Security-critical | documented |
| Runtime GPG verification uses an isolated temporary GPG home and disables auto key retrieval | `gpg` honors options | Ambient GPG trust or auto key retrieval causes acceptance of untrusted signature | Security-critical | documented |
| Runtime-managed wrapper paths reject symlink/reparse-point indirection | Managed paths are checked before read/write operations | Helper reads from or writes to attacker-chosen path through indirection | Security-critical | documented |
| Installer-managed target/source paths reject symlink/reparse-point indirection | Installer runs on supported OS and managed paths are ordinary files | Installer follows link and overwrites unexpected file | Security-critical | documented |
| Installer copies helper payloads only from `--trusted-source-dir`, never by fetching network content itself | Caller treats `--trusted-source-dir` as trusted | Installer downloads unverified remote helper payloads | Security-critical | documented |
| Bootstrap templates fail closed while checked-in placeholders remain unreplaced | Repository template is run directly | Placeholder bootstrap downloads from attacker-controlled default or proceeds without pinned key | Security-critical | documented |
| Release-rendered bootstrap verifies the exact release-pinned manifest digest, its detached signature, and payload checksums before invoking installer | Release process renders immutable URLs, exact manifest SHA-256, and pinned key material correctly | Tampered or replayed release payload executes before verification | Security-critical | documented |
| Unsafe development installers require explicit acknowledgement | User invokes unsafe script | Accidental execution without `--yes-i-know-this-is-unsafe` | Hardening / misuse prevention | documented |
| Unsafe development installers refuse common CI markers | CI marker environment is present and not set to a false value | Unsafe current-branch code executes in CI despite marker | Hardening / misuse prevention | documented |
| Windows helper rejects Git-for-Windows GPG for batch launcher verification | Running on Windows and only unsupported Git GPG is found | Verification uses unsupported MSYS-flavored GPG path behavior | Security-critical | documented |
| PowerShell helper download operations fail within explicit timeout bounds | Timeout env var is valid; .NET waits honor deadline | Hung helper waits indefinitely | Availability / hardening | documented |
| POSIX helper and release-rendered POSIX bootstrap downloads fail within explicit timeout bounds | Timeout env vars are positive integers; downloader and watchdog behavior operate correctly | Hung helper/bootstrap waits indefinitely | Availability / hardening | documented |
| Bootstrap download streams stop at the documented byte limits even without Content-Length | Host streaming primitives and .NET streams operate correctly | Unknown-length response consumes unbounded temporary storage | Availability / hardening | documented |
| Valid-looking corrupt runtime sidecars receive at most one paired refresh before full re-verification | Cached JAR is absent or already matches the project pin; upstream remains reachable | Repeated downloads persist indefinitely or a replayed JAR authorizes metadata replacement | Recovery / hardening | documented |
| Runtime helper prepends init-script arguments only when project-local init script exists | Launcher helper runs before Gradle | Missing/incorrect init injection prevents wrapper repatching | Correctness / hardening | documented |
| Init script re-patches generated launchers after `Wrapper` task | Gradle launcher shape matches supported anchors | Wrapper regeneration silently removes helper invocation | Security-critical for sustained protection | documented |
| Init script preserves but never recalculates `buildishWrapperJarSha256Sum` | Wrapper task starts from one valid reviewed pin | Gradle silently removes the pin or a network-derived replacement becomes trusted project configuration | Security-critical for sustained protection | documented |
| Init script warns when `distributionSha256Sum` is missing | `Wrapper` task writes readable properties file | Missing distribution ZIP pin goes unnoticed | Hardening / operator warning | documented |
| CI validation pins GitHub Actions by SHA and uses minimal permissions | Maintainer CI workflows are used as written | CI supply-chain or token exposure risk increases | Supply-chain hardening | documented |
| CI verifies downloaded Gradle distribution ZIP against official SHA-256 file | CI bootstrap path uses repository workflow | CI runs with unverified Gradle distribution ZIP | Supply-chain hardening | documented |
| Windows CI verifies direct GnuPG installer download against repo-pinned signature material | Repo-pinned signer material is trustworthy | CI runs with unverified downloaded GnuPG installer | Supply-chain hardening | documented |

Resource thresholds:

- Runtime metadata: files larger than 65,536 bytes fail validation. *(documented)*
- Runtime wrapper JAR: files larger than 10 MiB fail validation. *(documented)*
- Bootstrap metadata/signature: files larger than 65,536 bytes fail validation. *(documented)*
- Bootstrap payloads: files larger than 262,144 bytes fail validation. *(documented)*
- Runtime helper download timeout: default 60 seconds, configurable only to a positive integer through `BUILDISH_NO_GRADLE_WRAPPER_JAR_HTTP_TIMEOUT_SECONDS`. *(documented)*
- Release-rendered POSIX bootstrap download timeout: default 60 seconds, configurable only to a positive integer through `BUILDISH_BOOTSTRAP_INSTALL_HTTP_TIMEOUT_SECONDS`. *(documented)*

## 9 Security Properties The Project Does Not Provide

Disclaimed properties:

- No protection after local project compromise: if an attacker can modify files in the checkout, ordinary Gradle and launcher mechanisms can run arbitrary code. *(documented)*
- No guarantee that the Gradle distribution ZIP is authentic unless the target project configures `distributionSha256Sum` or equivalent verification. *(documented)*
- No safety for untrusted `--trusted-source-dir`; it is trusted-local-only. *(documented)*
- No secure behavior for `unsafe-dev-install.*`; blind-trust remote execution is intentional. *(documented)*
- No protection against compromised pinned Gradle or release signing keys. *(documented)*
- No guarantee that network endpoints are reachable or performant. *(inferred)*
- No guarantee of concurrent install/helper execution safety in the same checkout. *(inferred)*
- No support for arbitrary custom Gradle distribution URL schemes, mirrors, nightly builds, or nonnumeric version naming in the secure runtime helper path. *(documented)*
- No guarantee that future Gradle launcher formats are patched until support is added and tested. *(documented)*
- No general-purpose software update client behavior; bootstrap scripts are intended to be small, static verifiers with hard-coded release URLs. *(documented)*

False-friend properties:

- `distributionUrl` validation authenticates the wrapper metadata source shape; it does not authenticate the Gradle distribution ZIP itself. Use `distributionSha256Sum` for that. *(documented)*
- Retained `.sha256` files are expected checksums, not independent trust roots. The wrapper JAR must still pass detached-signature verification. *(documented)*
- The Gradle-published `.sha256` side file does not establish the requested-version binding by itself. It must agree with the reviewed `buildishWrapperJarSha256Sum`. *(documented)*
- `--trusted-source-dir` sounds like a safety control, but it is a statement about caller trust, not a validator for arbitrary directories. *(documented)*
- The unsafe development installers contain acknowledgement and CI refusal checks, but those are guardrails, not cryptographic verification. *(documented)*
- GitHub immutable releases are useful supply-chain hardening, but they do not replace client-side signature and checksum verification. *(documented)*
- A successful `gpg --verify` result is meaningful only with the pinned expected key/fingerprint, not with arbitrary ambient user keyring trust. *(documented)*

Well-known attack classes left to callers/operators:

- Malicious Gradle build logic: protect repository write access and review build files before execution. *(documented)*
- Compromised developer/CI environment: protect PATH, shell, PowerShell, GPG, JVM, credentials, and environment variables. *(inferred)*
- Social engineering into unsafe install flows: do not run `unsafe-dev-install.*` in CI, automation, or secret-bearing environments. *(documented)*
- Distribution ZIP tampering when `distributionSha256Sum` is absent: configure Gradle's distribution checksum pinning. *(documented)*
- Release-signing key compromise: manage Buildish release signing keys and
  revocation/rotation outside this helper. *(inferred)*

## 10 Downstream Responsibilities

- Run `install.*` only from a reviewed local copy or from a bootstrap-verified payload directory. *(documented)*
- Treat `--trusted-source-dir` as trusted caller input only. *(documented)*
- Protect the target checkout, launcher scripts, helper scripts, Gradle build files, wrapper properties, and CI job workspace from untrusted writes. *(documented)*
- Install a native Windows GnuPG for `gradlew.bat`; do not rely on Git-for-Windows bundled GPG. *(documented)*
- Configure `distributionSha256Sum` for the Gradle distribution ZIP where distribution ZIP authenticity matters. *(documented)*
- Commit exactly one reviewed `buildishWrapperJarSha256Sum` and update it in the same change as `distributionUrl`. *(documented)*
- Treat checksum/signature mismatch errors as security failures unless independently explained. *(documented)*
- Use release-rendered `bootstrap-install.*` scripts only after release automation has filled real URLs, exact manifest SHA-256 values, and pinned signing-key material. *(documented)*
- Do not use `unsafe-dev-install.*` in CI, automation, or environments with secrets. *(documented)*
- Review nonstandard or newly generated launcher shapes when installer/init patching fails closed. *(documented)*
- Keep host tools such as shell, PowerShell, GPG, checksum utilities, JVM, and network stack trustworthy and patched. *(inferred)*

## 11 Known Misuse Patterns

- Passing an untrusted directory to `--trusted-source-dir`. This lets attacker-controlled helper payloads be copied and run. Use only reviewed or bootstrap-verified local payloads. *(documented)*
- Running `unsafe-dev-install.*` in CI or secret-bearing automation. This executes unverified current-branch content. Use reviewed local-copy or release-bootstrap flows instead. *(documented)*
- Treating local cache corruption as impossible because the helper verifies downloads. Local corruption can still cause denial of service, even if accepted malicious JAR execution should fail. *(documented)*
- Assuming this project protects against malicious Gradle build files. It does not; repository write access remains execution authority. *(documented)*
- Treating missing `distributionSha256Sum` as covered by wrapper-JAR verification. The helper verifies `gradle-wrapper.jar`, not the distribution ZIP. *(documented)*
- Treating a preserved `buildishWrapperJarSha256Sum` as automatically updated after a Wrapper version change. The init script preserves the old reviewed value and warns; maintainers must replace it explicitly. *(documented)*
- Bypassing helper failure after a checksum/signature mismatch by manually dropping in a wrapper JAR. Investigate the mismatch or use independently verified artifacts. *(inferred)*
- Running checked-in `bootstrap-install.*` template copies directly. They intentionally fail closed until release rendering. *(documented)*

## 11a Known Non-Findings: Recurring False Positives

- "Installer follows symlinks while patching target files" is not a finding for managed paths where `install.*` rejects symlinks/reparse points before writes. *(documented)*
- "Wrapper cache can be locally corrupted" is not, by itself, an accepted-malicious-JAR vulnerability; the in-model security property is that corrupted cache contents fail validation before Gradle starts. *(documented)*
- "An older correctly signed Gradle wrapper triplet can be renamed as a newer version" is not an accepted-JAR path when the reviewed project pin is intact; the upstream checksum disagrees with `buildishWrapperJarSha256Sum` and the helper fails before JAR acceptance. *(documented)*
- "`--trusted-source-dir` allows arbitrary code if attacker-controlled" is `OUT-OF-MODEL: trusted-input` unless the report shows the project treats that argument as untrusted. *(documented)*
- "`unsafe-dev-install.*` downloads unverified code" is `BY-DESIGN: property-disclaimed`; those scripts are intentionally unsafe and require acknowledgement. *(documented)*
- "Checked-in `bootstrap-install.*` contains placeholder URLs/key material" is not executable insecure default behavior because the templates fail closed before use. *(documented)*
- "A different validly signed release manifest can be replayed at the selected release URL" is not an accepted-payload path when the rendered bootstrap's exact manifest SHA-256 remains intact. *(documented)*
- "Helper downloads from the network" is not a finding unless downloaded bytes are accepted without the claimed checksum/signature validation. *(documented)*
- "The helper does not verify the Gradle distribution ZIP" is `BY-DESIGN: property-disclaimed`; the init script warns and downstream projects must configure `distributionSha256Sum`. *(documented)*
- "GPG uses the user's keyring" is not a finding for runtime helper verification because it creates an isolated temporary GPG home and disables auto key retrieval. *(documented)*
- "Runtime helper or release-rendered bootstrap may hang forever on network operations" should cite the explicit timeout logic unless the report identifies a path not governed by the deadline. *(documented)*
- "Unsupported future Gradle launcher shapes fail installation or wrapper updates" is expected fail-closed behavior, not silent bypass. *(documented)*

## 12 Conditions That Would Change This Model

Revise this model when any of these occur:

- A new public installer, helper, bootstrap, or runtime entry point is added. *(inferred)*
- The helper accepts new URL schemes, mirrors, version formats, or artifact sources. *(inferred)*
- The project starts verifying Gradle distribution ZIPs directly rather than only warning on missing `distributionSha256Sum`. *(inferred)*
- Release-rendered bootstrap scripts become operationally published with real
  manifest digests and Buildish signing-key material. *(documented)*
- The unsafe development installer behavior, acknowledgement gate, CI refusal, or base URL override changes. *(inferred)*
- Default size limits, timeout behavior, GPG trust roots, or supported launcher anchors change. *(inferred)*
- Tests, fixtures, generated outputs, or release tooling are promoted into an end-user runtime surface. *(inferred)*
- Maintainers make a new security commitment in docs, tests, release notes, or `SECURITY.md`. *(inferred)*
- A vulnerability report cannot be routed to one of the [§13](#13-triage-dispositions) dispositions; classify it as `MODEL-GAP` and update this model rather than making an ad-hoc decision. *(inferred)*

## 13 Triage Dispositions

| Disposition | Meaning | Licensed by |
| --- | --- | --- |
| `VALID` | Violates a security property the project claims, via an in-scope adversary and input. | §6, §7, §8 |
| `VALID-HARDENING` | No §8 property is violated, but the API or docs make a §11 misuse easy enough that the project elects to harden it. | §11 |
| `OUT-OF-MODEL: trusted-input` | Requires attacker control of a parameter the model marks trusted, such as `--trusted-source-dir`. | §6 |
| `OUT-OF-MODEL: adversary-not-in-scope` | Requires attacker capability the model excludes, such as modifying helper code or controlling host tools. | §7 |
| `OUT-OF-MODEL: unsupported-component` | Lands only in tests, generated outputs, local build outputs, or other components placed out of product scope. | §3 |
| `OUT-OF-MODEL: non-default-build` | Only manifests under a discouraged or non-default variant. | §5a |
| `BY-DESIGN: property-disclaimed` | Concerns a property the project explicitly does not provide, such as distribution ZIP verification. | §9 |
| `KNOWN-NON-FINDING` | Matches a documented recurring false positive. | §11a |
| `MODEL-GAP` | Cannot be cleanly routed to any disposition above. The model must be revised. | §12 |

## 14 Ratified Maintainer Decisions

- `docs/threat-model.md` is canonical. Site pages and `SECURITY-ASSESSMENT.md` may summarize it but
  must identify themselves as subordinate material. *(maintainer)*
- Each release carries the model current for that release. *(maintainer)*
- Release-rendered `bootstrap-install.*` is in-scope security functionality once published;
  checked-in templates remain fail-closed placeholders until rendering. *(maintainer)*
- Release-signing-key operations are a release-management responsibility outside the protection
  this helper can enforce. Compromise of the pinned key remains out of scope. *(maintainer)*
- POSIX helper and bootstrap downloads claim only their documented byte and timeout bounds; no
  broader CPU, memory, rate, reachability, or performance guarantee is made. *(maintainer)*
- Concurrent helper or installer executions in one checkout are unsupported. Atomic moves reduce
  partial-write risk but do not provide cross-process locking. *(maintainer)*
- Host tools and runtimes are trusted dependencies. Tests and generated/local build outputs are
  validation artifacts, not independently secured product surfaces. *(maintainer)*
- A report believed to be security-impacting may be reported privately even if triage later assigns
  `VALID-HARDENING`; advisory and CVE decisions remain maintainer decisions. *(maintainer)*
- An `unsafe-dev-install.*` report is `VALID` only when it bypasses a documented guardrail; its
  unverified download is otherwise explicitly disclaimed behavior. *(maintainer)*
- CI and release workflows are only partially modeled here. Detailed release-process modeling
  belongs to the release tooling; that deferred work remains open. *(maintainer)*
- A machine-readable companion is deferred until recurring model changes justify its maintenance
  cost. *(maintainer)*

## 15 Optional Machine-Readable Companion

No machine-readable companion is currently maintained. If recurring model changes justify one,
derive it from this canonical prose model rather than creating a second independent authority.
*(maintainer)*
