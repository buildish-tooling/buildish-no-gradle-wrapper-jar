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

# Release bootstrap signing approach

## Goal

Move the installer bootstrap trust model away from unsigned raw file downloads and
toward a signed release artifact that both `install.sh` and `install.ps1` can
verify before installing helper files.

## Key assumption

We already rely on `gpg` / `gpg.exe` to validate the Gradle wrapper JAR
signature. Because of that, it is reasonable to reuse GPG for bootstrap release
verification instead of introducing a second crypto stack.

## Recommended shape

Do **not** embed arbitrary signed payload data at the end of the shell or
PowerShell installer scripts.

Instead:

1. build one bootstrap archive containing the helper files,
2. create a detached ASCII-armored GPG signature for that archive,
3. publish both as release assets,
4. make the installers download and verify the archive before extraction.

This is simpler to audit, easier to test, and avoids PowerShell self-parsing or
trailing-data tricks.

## Proposed release artifacts

For each release, publish something like:

- `buildish-no-gradle-wrapper-jar-bootstrap-<version>.zip`
- `buildish-no-gradle-wrapper-jar-bootstrap-<version>.zip.asc`
- optionally `buildish-no-gradle-wrapper-jar-bootstrap-<version>.zip.sha256`

The archive should contain exactly:

- `buildish-no-gradle-wrapper-jar.sh`
- `buildish-no-gradle-wrapper-jar.ps1`
- `buildish-no-gradle-wrapper-jar.init.gradle.kts`

## Trust model

The trust root becomes:

- the checked-in installer script (`install.sh` or `install.ps1`), and
- an embedded trusted public key plus pinned fingerprint.

The installer should treat the release archive as untrusted until:

1. it is downloaded within the configured size limit,
2. its detached signature is downloaded within the configured size limit,
3. the signature verifies with the pinned key in an isolated temporary GPG home.

Only then should the installer extract and move files into place.

## Conceptual steps to get there

### 1. Create and manage a signing key

- Create an ASF-controlled release signing key for this bootstrap content.
- Export the public key in ASCII-armored form.
- Store the private key and passphrase in GitHub secrets for the release job.
- Document who is allowed to rotate the key and how fingerprint changes are
  rolled out.

### 2. Add a release packaging step

- Create a deterministic bootstrap archive during release.
- Include only the three installer-managed helper files.
- Keep archive layout flat and predictable.
- Prefer a single archive over signing each helper file individually.

### 3. Sign the archive in CI

- Import the private key into a temporary `GNUPGHOME` inside the release job.
- Generate a detached ASCII-armored signature for the archive.
- Optionally emit a SHA-256 checksum file too, mainly as an operator aid.
- Publish the archive and signature as release assets.

### 4. Decide the installer default download location

- Stop defaulting bootstrap downloads to raw files under `raw.githubusercontent.com`.
- Default to GitHub release assets instead.
- Keep the existing source-directory override for tests and trusted local
  development.
- Keep the base-URL override, but clearly treat it as trusted-input-only.

### 5. Embed the trusted public key in both installers

- Add the ASCII-armored public key to `install.sh`.
- Add the same ASCII-armored public key to `install.ps1`.
- Pin the expected fingerprint in both installers.
- Verify in an isolated temporary `GNUPGHOME`, mirroring the current wrapper JAR
  validation pattern.

### 6. Change installers to fetch archive + detached signature

- Download the bootstrap archive to a temp path.
- Download the detached signature to a temp path.
- Apply explicit size limits to both downloads.
- Fail hard if either limit is exceeded.

### 7. Verify before extraction

- Import only the embedded trusted public key into the temporary GPG home.
- Disable network key retrieval.
- Verify the detached signature for the downloaded archive.
- Confirm the signing key fingerprint matches the pinned fingerprint.
- Abort immediately if verification fails.

### 8. Extract only after successful verification

- Extract into a temporary directory.
- Verify the expected file set is present and no extra unexpected files matter.
- Optionally reject archives with path traversal, symlinks, or nested layout.
- Move the verified helper files into place atomically.

### 9. Preserve current safe-install behavior

- Keep symlink / reparse-point rejection.
- Keep temp-file downloads and temp-directory extraction.
- Keep fail-closed behavior on partial downloads or verification errors.
- Keep the local source copy path for tests so integration coverage remains fast.

### 10. Add verification coverage

Add tests for at least these cases:

- valid signed archive installs successfully,
- oversized archive download fails,
- oversized signature download fails,
- bad signature fails,
- wrong signing key fails,
- missing `gpg` / `gpg.exe` fails with a clear message,
- malformed archive contents fail,
- local trusted source-directory override still works.

## Why this is better than script trailer payloads

- works the same way for POSIX and PowerShell,
- avoids making the installer parse its own file contents,
- keeps signature handling conventional and auditable,
- makes release assets explicit and reusable,
- reduces the chance of format-specific parser surprises.

## Migration idea

A practical rollout can happen in stages:

1. implement signed archive production in release automation,
2. add installer support for archive verification behind the default release URL,
3. keep local override paths for tests,
4. once stable, remove reliance on raw unsigned bootstrap file downloads.

## Open design questions

- Whether to use `.zip` for both platforms or platform-specific archive formats.
- Whether to keep publishing individual helper files in addition to the signed
  archive for manual inspection.
- How key rotation should be handled when the pinned installer key changes.
- Whether releases should be channel-based (`latest`) or fully version-addressed.