---
title: "Security and trust model"
description: Security boundary and reporting guidance for the no-gradle-wrapper-jar blueprint.
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

# Security and trust model

Summary updated: 2026-08-02

> [!IMPORTANT]
> The minimal Wrapper bootstrap is implemented in the unreleased development
> tree. No component release has been published yet.

The [canonical threat model in the unreleased development
documentation](../development/threat-model/) defines this component's actors,
trust boundaries, security properties, non-goals, deployment responsibilities,
and report triage guidance. If this summary differs from that versioned model,
the versioned model controls.

## Runtime boundary

The runtime protects one cold network handoff:

> A Wrapper JAR downloaded by the Buildish bootstrap is not published to the
> executable Wrapper path until its SHA-256 equals the committed project pin.

The bootstrap downloads only when `gradle/wrapper/gradle-wrapper.jar` is
missing. It writes to a unique temporary sibling, bounds connection and total
request time, limits the response to 10 MiB, checks the exact supported
version/digest pair, and publishes only verified bytes. It does not download
checksum or signature sidecars and does not invoke GPG.

An existing local ignored JAR is trusted and is not reverified on the warm
path. The tracked checkout, committed pin, helpers, launchers, build logic,
generation environment, host tools, and reused local Gradle state are also
trusted. An actor able to replace that state already controls executable
project behavior; defending against that actor is outside this component's
runtime guarantee.

## Operator guidance

- Acquire and review the init script plus the bootstrap helper for each
  launcher the project maintains before copying them into a project. Initial
  adoption with neither launcher requires both helpers because it retains
  Gradle's generated pair. The current implementation has no automatic or
  remote installer.
- Keep the existing Wrapper JAR recoverable until init-script-driven adoption
  succeeds and the complete diff has been reviewed.
- Commit exactly one canonical `buildishWrapperJarVersion` and
  `buildishWrapperJarSha256Sum` written by the enhanced Wrapper task.
- Review the independent target `distributionUrl` and
  `distributionSha256Sum` in the same change. Gradle, not this bootstrap,
  provisions the target distribution.
- Delete an existing unusable local Wrapper JAR and rerun the command to take
  the verified cold path.
- Do not use bare `gradle wrapper` for adoption or recovery. Explicitly attach
  `gradle/buildish-wrapper.init.gradle.kts`, or run the already integrated
  project launcher.
- On native Windows, use the documented same-directory GUID-named stable copy
  when Wrapper execution may replace `gradlew.bat` across launcher
  generations.

No compiled Wrapper executable is tracked in Git. Keeping compiled bootstrap
executables out of a source release is still an objective rather than a shipped
claim. Release publication remains blocked until the actual source archive is
assembled and checked while ignored local binary state exists.

Suspected violations of the canonical claimed properties should be reported
privately through the [Buildish security process](https://buildish.org/community/security/)
or directly to [security@buildish.org](mailto:security@buildish.org).
