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

# Release bootstrap publishing approach

## Current status

The repository now contains:

- `bootstrap-install.sh`
- `bootstrap-install.ps1`

Those scripts are tiny release templates. They already implement the secure bootstrap verifier logic,
but they intentionally fail closed until a release step renders the hard-coded release URL and the
pinned signing-key material.

## Goal

Operationalize the secure bootstrap path so end users can execute release-rendered
`bootstrap-install.*` scripts that verify a signed installer payload set before handing off to
`install.* --trusted-source-dir`.

## Key assumption

The project already relies on `gpg` / native `gpg.exe` for detached-signature verification in other
paths. Reusing GPG for the release bootstrap keeps the trust model conventional and avoids adding a
second crypto stack.

## Implemented verifier shape

The current bootstrap implementation does all of the following:

1. downloads a platform-specific installer payload set into a temporary directory,
2. downloads a detached ASCII-armored signature plus a SHA-256 manifest for that payload set,
3. verifies the signature in an isolated temporary GPG home against pinned trust material,
4. verifies that the manifest contains exactly the expected files,
5. verifies the downloaded payload checksums against that signed manifest,
6. hands off to `install.* --trusted-source-dir <verified-dir>` only after all checks pass.

The payload sets are intentionally explicit:

- POSIX bootstrap: `install.sh` plus the three shared helper files
- PowerShell bootstrap: `install.ps1` plus the same three shared helper files

## Release artifacts to publish

For each release, publish at least these assets:

- rendered `bootstrap-install.sh`
- rendered `bootstrap-install.ps1`
- `install.sh`
- `install.ps1`
- `buildish-no-gradle-wrapper-jar.sh`
- `buildish-no-gradle-wrapper-jar.ps1`
- `buildish-no-gradle-wrapper-jar.init.gradle.kts`
- `bootstrap-install-posix.sha256`
- `bootstrap-install-posix.sha256.asc`
- `bootstrap-install-powershell.sha256`
- `bootstrap-install-powershell.sha256.asc`

Supporting operator material should still include the ASF-hosted `KEYS` file outside the GitHub
release asset channel.

## Release-time rendering inputs

Each rendered bootstrap script needs only a tiny set of substituted values:

- the immutable release base URL
- the pinned signing-key fingerprint
- the pinned ASCII-armored public key

No runtime URL override or alternate remote source knob should be added back into the bootstrap
scripts.

## Release signing key management

- Create an ASF-controlled signing key for bootstrap release payloads.
- Export the public key in ASCII-armored form for embedding into the rendered bootstrap scripts.
- Publish the public key via ASF-managed `KEYS` material for manual verification.
- Document how key rotation updates the pinned fingerprint and embedded key material.

## Release automation steps

1. Stage the release payload files listed above.
2. Generate `bootstrap-install-posix.sha256` covering the POSIX payload set.
3. Generate `bootstrap-install-powershell.sha256` covering the PowerShell payload set.
4. Create detached ASCII-armored signatures for both manifests.
5. Render `bootstrap-install.sh` and `bootstrap-install.ps1` with the release URL and pinned key.
6. Publish the rendered scripts, payload files, and signed manifests as immutable release assets.

## Validation expectations

Keep verification coverage for at least these cases:

- unrendered template fails closed,
- valid signed payload set installs successfully,
- bad detached signature fails,
- incomplete signed manifest fails,
- missing `gpg` / `gpg.exe` fails with a clear message,
- local trusted-source handoff in `install.*` keeps working.

## Why this shape was chosen

- works the same way for POSIX and PowerShell,
- avoids embedding opaque binary/archive payloads into the bootstrap script,
- keeps signature handling conventional and auditable,
- verifies the complete installer payload set instead of only the entrypoint,
- keeps the trust-establishing code in `bootstrap-install.*`, not in `install.*`.

## Remaining work

- create and manage the real ASF-controlled bootstrap signing key,
- wire release automation to render and publish the bootstrap assets,
- decide how key rotation and release URL versioning are documented for operators.