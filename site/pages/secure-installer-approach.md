---
title: "Secure installer bootstrap approach"
description: Current bootstrap verifier design plus the remaining release rendering and publishing work.
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

# Secure installer bootstrap approach

Date: 2026-04-07

This page describes the current bootstrap verifier design and the remaining release automation work
for installer delivery.

It is intentionally about the bootstrap/install trust boundary, not about the normal runtime helper
verification that happens later in `gradlew` / `gradlew.bat`.

## Goal

The goal is to make installer delivery both:

- strong enough to detect tampering before execution, and
- small enough that humans can still review the trust-establishing code in reasonable time.

## Why `bootstrap-install.*` is needed

`install.sh` and `install.ps1` have grown to handle real-world edge cases, platform differences,
and safety checks.

That is good for functionality, but it also means they are no longer the kind of scripts that most
users can quickly audit before running them.

The current answer is a two-tier model:

- `bootstrap-install.sh`
- `bootstrap-install.ps1`

These tiny bootstrap scripts only fetch, verify, and hand off to the real installer payloads.

The repository now contains both scripts as release templates. They already implement the signed
bootstrap logic, and they intentionally fail closed until a release step renders the hard-coded base
URL, exact signed-manifest SHA-256, and pinned signing-key material.

The handoff into the real installer should happen via `--trusted-source-dir`, not via a live
network fetch inside `install.sh` or `install.ps1`.

## Where the `KEYS` file lives

The project signing `KEYS` file should live at the stable,
non-release URL <https://buildish.org/KEYS>.

That matters because `KEYS` should not be treated as just another GitHub release asset downloaded
from the same channel as the installer payload.

For manual verification, that Buildish-hosted `KEYS` file is useful and expected.

For the automated bootstrap path, the safer design is still to pin the expected release-signing key
fingerprint or armored public key directly in the tiny bootstrap script. A runtime-downloaded
`KEYS` file should be supporting material, not the only root of trust.

## Why the bootstrap scripts have strict expectations

The bootstrap scripts should deliberately assume a tiny standard toolset and fail hard if it is not
available.

That keeps them quickly reviewable.

If they start handling every environment edge case, they become second installers, and the review
advantage is lost.

Users are not locked into the bootstrap scripts, though. If a bootstrap script fails because the
expected tools are missing, or if a user prefers to inspect every step directly, they can fall back
to the manual verification approach: download the installer payload set plus its matching signed
checksum manifest (`*.sha256` and `*.sha256.asc`), verify the manifest signature with the
Buildish-hosted `KEYS` material, verify each payload checksum from that manifest, and only then execute
the installer with `--trusted-source-dir` pointing at the verified local payload directory. The
bootstrap scripts are meant to automate those same steps in a small and reviewable form.

The `--trusted-source-dir` name is intentional. It reflects the actual trust model: if an attacker
can already execute code in the same user or CI context, or can already rewrite the checked-out
project and the files that Gradle will run, then the trust boundary for that checkout is already
gone. In that situation, a trusted local handoff argument is not creating a new class of
compromise. It is still not safe as an untrusted user-controlled input.

Expected prerequisites:

- POSIX: `curl` or `wget`, `gpg`, and `sha256sum` or `shasum`
- PowerShell: PowerShell, a native Windows `gpg.exe`, and built-in `Get-FileHash`

The Windows expectation is explicitly a native non-MSYS, non-Cygwin, non-Git-for-Windows
`gpg.exe`.

## Why the bootstrap scripts use hard-coded URLs

The bootstrap scripts should use hard-coded release and verification URLs.

That is deliberate:

- it keeps the trust path easy to read
- it avoids configuration branches that make review harder
- it reduces the chance of a subtle override changing the security model

The real installer may still support the explicit `--trusted-source-dir` trusted-local handoff. The
tiny bootstrap verifier should not support general remote override knobs.

Because those URLs are release-specific, the published `bootstrap-install.sh` and
`bootstrap-install.ps1` should be generated from a tiny shared template during the release process.

The exact generation mechanism does not matter much. It can be a small template renderer, `sed`, or
another simple release-time substitution step. What matters is the contract:

- the checked-in repository copies are templates and must fail closed until rendered
- generation happens before signing and publishing the release assets
- only a tiny set of values is substituted, such as version, asset URLs, the exact manifest
  SHA-256, and pinned signing fingerprint or key material
- the generated bootstrap scripts are the things users review and execute
- no runtime URL templating or environment-driven remote override logic is added back into the
  bootstrap scripts

That keeps the maintenance burden reasonable without giving up the core property we want: the final
published bootstrap scripts are still small, static, and easy to reason about.

## What should be pinned in the bootstrap scripts

The bootstrap scripts should pin release-signing trust material, not try to become a general
purpose update client.

The recommended pinned material is:

- the exact SHA-256 of the selected release's signed payload manifest, and
- the expected release-signing key fingerprint, or
- the armored release-signing public key

The current recommendation is **not** to embed every payload digest directly in the bootstrap
script. Instead, the bootstrap pins the one manifest digest that selects the release, verifies the
manifest's detached signature, uses that manifest to verify the complete installer payload set, and
then hands off the verified local directory to `install.*` via `--trusted-source-dir`.

The manifest digest and signature serve different purposes. The embedded digest prevents another
validly signed release manifest from being replayed at the selected release URL. The signature
proves that the selected manifest was authorized by the pinned Buildish release key.

The current implementation uses one signed payload manifest per platform:

- POSIX bootstrap verifies `install.sh` plus the shared helper files
- PowerShell bootstrap verifies `install.ps1` plus the shared helper files
- each platform uses a detached ASCII-armored signature over a SHA-256 manifest for that exact file
  set

The important contract is the same: the bootstrap script verifies a complete payload set, not just
the installer entrypoint, and then hands off a verified local directory.

## Why immutable GitHub releases are still useful

Immutable GitHub releases are still strongly recommended.

They are useful because they stop later modification of:

- the release tag
- the attached release assets

That blocks an important class of supply-chain attacks where an already-published artifact is later
swapped.

But immutable releases do not replace client-side verification. The bootstrap scripts still need to
verify what they downloaded before handing control to `install.sh` or `install.ps1`.

## Pseudocode: POSIX bootstrap installer

```
require_command gpg
require_command curl_or_wget
require_command sha256sum_or_shasum

key_fingerprint='PINNED_RELEASE_SIGNING_KEY'
expected_manifest_sha256='PINNED_RELEASE_MANIFEST_SHA256'
base_url='https://github.com/buildish-tooling/buildish-no-gradle-wrapper-jar/releases/download/vX.Y.Z'
manifest='bootstrap-install-posix.sha256'
payload_dir='./verified-payload'

download_payload_set "$base_url" "$payload_dir"
verify_sha256 "$manifest" "$expected_manifest_sha256"
verify_detached_signature "$manifest.asc" "$manifest" "$key_fingerprint"
verify_manifest_entries "$manifest" "$payload_dir"

exec sh "$payload_dir/install.sh" --trusted-source-dir "$payload_dir" "$@"
```

## Pseudocode: PowerShell bootstrap installer

```
Require-NativeWindowsGpg
Require-Command Invoke-WebRequest

$expectedFingerprint = 'PINNED_RELEASE_SIGNING_KEY'
$expectedManifestSha256 = 'PINNED_RELEASE_MANIFEST_SHA256'
$baseUrl = 'https://github.com/buildish-tooling/buildish-no-gradle-wrapper-jar/releases/download/vX.Y.Z'
$manifest = 'bootstrap-install-powershell.sha256'
$manifestSignature = "$manifest.asc"
$payloadDirectory = '.\verified-payload'

Get-PayloadSet $baseUrl $payloadDirectory
Assert-FileSha256 $manifest $expectedManifestSha256
Assert-DetachedSignature $manifestSignature $manifest $expectedFingerprint
Assert-ManifestEntries $manifest $payloadDirectory

& (Join-Path $payloadDirectory 'install.ps1') --trusted-source-dir $payloadDirectory @args
```

## Non-goals for `bootstrap-install.*`

The bootstrap scripts should not try to:

- repair broken environments
- support many override knobs
- carry full installer edge-case handling
- replace the real `install.*` scripts

Their only job is to establish trust in the downloaded installer payload and then hand off.

## Recommendation summary

- publish the real installers as immutable GitHub release assets
- keep `KEYS` at <https://buildish.org/KEYS>, not as a release asset
- keep `bootstrap-install.*` tiny and release-rendered
- pin the selected release manifest digest and release-signing trust material in those bootstrap
  scripts
- hand off from bootstrap into `install.*` via `--trusted-source-dir`
- use a detached per-platform SHA-256 manifest plus `.asc` signature that covers the complete payload set
- assume a minimal toolset and fail hard with actionable errors if it is missing
