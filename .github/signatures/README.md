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

# GitHub workflow signature assets

This directory contains repo-pinned signature material used by `.github/workflows/ci.yml`
to verify the fast Windows GnuPG bootstrap download before extraction.

## Files

- `gnupg-w32-2.5.21_20260702.exe.sig`
  - Detached OpenPGP signature for the exact Windows installer downloaded by CI.
  - This file is intentionally stored in the upstream binary `.sig` form.
  - Binary detached signatures are standard OpenPGP artifacts; they are not less trusted
    than ASCII-armored signatures.
- `signature_key.asc`
  - ASCII-armored minimal export of the exact allowed signer public key
    `6DAA6E64A76D2840571B4902528897B826403ADA`.
  - Derived from the upstream `https://gnupg.org/signature_key.asc` key bundle, but reduced
    to the single signer actually accepted by CI.
  - Imported into a temporary keyring during CI bootstrap verification.

## Why keep the `.sig` file in binary form?

The upstream project publishes this detached signature as `.sig`, not as an armored `.asc`
file. Keeping the exact upstream artifact in-repo is preferable to re-encoding it locally,
because the workflow then verifies against the same bytes upstream published.

Trust comes from the combination of:

- the repo-pinned allowed signer public key in `signature_key.asc`
- the repo-pinned detached signature in `.sig` format
- the workflow check that requires the expected valid signer fingerprint
  `6DAA6E64A76D2840571B4902528897B826403ADA`

Keeping a minimal single-key export here is deliberate:

- it narrows trust to the one signer the workflow already requires
- it avoids bootstrap compatibility problems with older Git-for-Windows `gpg` builds that do
  not need to understand unrelated newer keys just to verify this installer

## Update procedure

When bumping the Windows GnuPG installer version:

1. Download the new installer `.exe` from `https://gnupg.org/ftp/gcrypt/binary/`.
2. Download the matching upstream detached signature `.sig`.
3. Export the expected signer from the upstream `signature_key.asc` bundle as a minimal armored
   public key, and replace `signature_key.asc` in this directory with that single-key export.
4. Verify the signature manually against the repo-pinned `signature_key.asc` before committing.
5. Replace the pinned `.sig` file in this directory.
6. Update the installer URL and signer expectations in `.github/workflows/ci.yml`.
7. Run `make check`.
