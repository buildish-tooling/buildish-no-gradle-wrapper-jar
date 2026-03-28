---
title: "Threat model"
description: Security boundaries and triage guidance for the minimal Gradle Wrapper bootstrap.
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

# Threat Model: Minimal Gradle Wrapper Bootstrap

> [!IMPORTANT]
> This document describes the implemented security contract in the unreleased
> development tree. No component release has been published yet. *(documented)*

This is the canonical threat model for this component. It is versioned with the
repository, and a report against a released version is assessed against the
model shipped with that version rather than a later development revision.
*(maintainer)*

Status: implemented and validated in the development tree, 2026-08-02; not yet
published as a component release. *(maintainer)*

Provenance: *(documented)* identifies current public repository documentation;
*(maintainer)* identifies the accepted security contract; *(inferred)* would
identify an unresolved interpretation. This reviewed model contains no inferred
claims. Draft confidence: 6 documented, 73 maintainer, 0 inferred. Counts are
approximate because one tagged statement may contain related clauses.

Suspected violations of [claimed properties](#claimed-security-properties)
should be reported through the
[Buildish security policy](https://buildish.org/community/security/). Reports
that depend on [out-of-scope capabilities](#out-of-scope-and-non-goals) or a
[disclaimed property](#disclaimed-properties-and-false-friends) are triaged
against those sections. Severity, advisory status, and CVE candidacy remain
case-specific, non-authoritative triage decisions. *(maintainer)*

## Scope And Intended Use

The component is a source-only blueprint for Gradle projects that want to keep
one or both ordinary `gradlew` and `gradlew.bat` entry points without tracking
`gradle/wrapper/gradle-wrapper.jar`. A missing Wrapper JAR is materialized in an
ignored project-local path on first use. *(documented)*

The consumer integration has three source components with distinct
roles. *(maintainer)*

| Component family | Consumer entry point | External effects | In scope |
| --- | --- | --- | --- |
| POSIX cold bootstrap | `gradle/buildish-wrapper-bootstrap.sh`, sourced by `gradlew` | Reads project configuration, downloads one missing JAR, hashes and publishes it, attaches the project init script | Yes |
| Windows cold bootstrap | `gradle/buildish-wrapper-bootstrap.ps1`, invoked by the missing-JAR branch in `gradlew.bat` | Reads project configuration, downloads one missing JAR, hashes and publishes it | Yes |
| Wrapper-task integration | `gradle/buildish-wrapper.init.gradle.kts`, attached explicitly with `--init-script` | Validates generated Wrapper outputs, preserves the pre-task launcher set, and rewrites maintained launcher and properties files after the root `:wrapper` task | Yes |
| Existing-JAR warm launch | maintained `gradlew` and/or `gradlew.bat` | Starts the already-present project-local JAR; POSIX also attaches the init script | Yes, with the local JAR trusted |
| Tests and repository checks | `tests/` and `scripts/` | Validate the contract in temporary workspaces | Evidence only; not a consumer security boundary |
| CI and release support | `.github/workflows/` and `buildish-release-tooling/` | Validate repository and release inputs | In scope only for the limited claims stated here |

The intended callers are developers, CI jobs, and maintainers who already trust
the checkout enough to execute its Gradle build. The blueprint is not a sandbox
for an untrusted repository. *(maintainer)*

The runtime boundary is deliberately narrow: it protects the handoff from an
untrusted cold network response to a newly published executable Wrapper JAR. It
does not attempt to create a second security boundary inside an already trusted
checkout. *(maintainer)*

## Assets

The assets protected or kept coherent by this design are: *(maintainer)*

- the integrity of a Wrapper JAR first obtained from the network;
- the committed Wrapper JAR version and SHA-256 authorization;
- the generated launchers, init-script attachment, and Wrapper properties as
  one reviewable tracked configuration;
- the availability of an existing final JAR when a cold download fails;
- the absence of a compiled Wrapper bootstrap executable from tracked Git
  contents; and
- the accuracy of any future source-release exclusion claim.

User credentials, secrets, Gradle build outputs, dependency integrity, and the
confidentiality of project source are not assets protected by this bootstrap.
*(maintainer)*

## Actors

- **Project maintainer or update automation.** Selects a stable Gradle version
  and distribution checksum, runs the enhanced root Wrapper task, reviews
  generated changes, and commits the resulting configuration. This actor is
  trusted. *(maintainer)*
- **Developer or CI caller.** Executes a trusted checkout through its launchers.
  This actor is trusted to run the project build and provide an appropriate host
  environment. *(maintainer)*
- **Network responder or network attacker.** Can return missing, truncated,
  oversized, delayed, corrupt, or substituted cold-download bytes. This actor
  is untrusted. *(maintainer)*
- **Gradle publisher.** Supplies the selected stable-version artifacts. Runtime
  trust comes from the committed Wrapper JAR digest, not from a fresh publisher
  authentication ceremony or membership in the repository test matrix.
  *(maintainer)*
- **Local actor with write access to the checkout or ignored JAR.** Can already
  alter executable project state and is outside this component's adversary
  model. *(maintainer)*
- **Release operator and archive tooling.** Are responsible for proving the
  contents of an assembled source archive before a release claim is enabled.
  This is a separate publication boundary. *(maintainer)*

## Trust Boundaries And Data Flows

### Cold network handoff

The committed, canonical Wrapper JAR version and SHA-256 pair is the
authorization for a cold download. The network response is untrusted even when
transported over HTTPS. *(maintainer)*

The cold flow is: *(maintainer)*

1. The launcher determines that `gradle/wrapper/gradle-wrapper.jar` is absent.
2. The bootstrap reads one canonical stable version and digest from the trusted
   project properties and derives that version's fixed upstream JAR URL.
3. It downloads only that version's JAR to a unique sibling temporary file with
   bounded time and a 10 MiB response limit.
4. It computes SHA-256 locally and compares the result with the committed pin.
5. Only matching bytes may be published to the executable final path.
6. A mismatch, incomplete response, limit violation, timeout, or unusable
   publication state returns nonzero without executing the downloaded bytes.

The digest comparison is an integrity and version-authorization boundary. The
remote server does not receive authority to select both the executable bytes
and their expected digest. *(maintainer)*

### Warm local handoff

If the final JAR already exists, it is trusted local checkout state. The warm
path does not hash it, contact the network, refresh metadata, or start the
Windows bootstrap helper. POSIX still attaches the project-local init script as
part of its launcher contract. *(maintainer)*

The change from cold to warm state is therefore a change in trust treatment:
new network bytes must match the committed pin before publication; an existing
local JAR is accepted without revalidation. *(maintainer)*

### Generation and update handoff

The explicitly attached init script enhances only the named top-level
`:wrapper` task. It treats the executing Gradle runtime, ambient Gradle init
scripts, reused Gradle user-home state, JDK, and host filesystem as trusted
generation inputs. *(maintainer)*

Before Buildish writes its tracked postprocessed forms, the task validates the
canonical executing version, hashes the generated Wrapper JAR, validates the
official binary target distribution URL and checksum, and locates one
unambiguous structural launcher invocation. Maintainer review and commit make
the resulting values trusted project configuration. *(maintainer)*

The bootstrap JAR version may legitimately differ from the target distribution
version during Gradle's two-pass update lifecycle. Equality between those
versions is not a security invariant. *(maintainer)*

### Source publication handoff

Git tracking, the ignored local working-tree JAR, and an assembled release
archive are three different inventories. A repository check can prove only the
first. The release assembler must independently inspect the real archive while
an ignored local JAR exists before the project may claim archive exclusion.
*(maintainer)*

For triage, a bootstrap finding is security-relevant only when untrusted cold
bytes can cross the committed-pin boundary under the trusted-host assumptions.
An init-script finding must be reachable from a supported root Wrapper
invocation and cause unsupported or incoherent generated state to be accepted.
A warm-path finding that requires prior modification of trusted local state is
out of model. *(maintainer)*

## Input And Environment Assumptions

The following classifications are part of the accepted contract.
*(maintainer)*

| Entry point | Input | Trust | Required treatment |
| --- | --- | --- | --- |
| Cold bootstrap | committed Wrapper JAR version and digest | Trusted project configuration | Require exactly one canonical stable version and lowercase SHA-256; derive the fixed upstream JAR URL from the version |
| Cold bootstrap | downloaded JAR bytes | Untrusted | Bound size/time, hash locally, and publish only on exact pin match |
| Warm launcher | existing ignored Wrapper JAR | Trusted local state | No runtime validation; delete manually to force a cold recovery |
| Init script | executing Gradle and generated Wrapper JAR | Trusted generation process, then constrained output | Require a canonical stable version, hash the actual generated JAR, and write that identity to tracked properties |
| Init script | generated `distributionUrl` and `distributionSha256Sum` | Operator-selected configuration | Require the exact official binary URL derived from a canonical stable target version and one lowercase SHA-256 |
| Init script | generated launcher contents | Generated by a stable Gradle version | Require one unambiguous structural invocation shape; do not guess on drift |
| Release validation | assembled source archive | Untrusted claim input | Inspect actual archive contents independently of Git ignores |

The product is version-agnostic within that contract. The finite compatibility
manifest records test evidence only; it does not authorize product versions or
digests. A generated launcher with an unfamiliar structure is rejected until
the structural matcher and matching evidence are reviewed together.
*(maintainer)*

The host shell, PowerShell, .NET runtime, JDK, hashing implementation, `curl`
8.4.0 or newer, filesystem semantics, process environment, and process
privileges are trusted.
The bootstrap does not defend against their compromise or substitution.
*(maintainer)*

Buildish-managed runtime publication and init-script postprocessing write only
to the four canonical paths inside the consumer checkout. Gradle's trusted
native `Wrapper` action runs before Buildish's final validation and may already
have written operator-configured custom task outputs; Buildish rejects those
noncanonical locations without postprocessing them. The design does not
establish persistent project integration under a user- or installation-wide
Gradle init directory. *(maintainer)*

`distributionSha256Sum` authorizes Gradle's provisioning of a missing target
distribution. Its presence does not prove that Gradle revalidated previously
cached distribution state. That reused state remains trusted. *(maintainer)*

## Concurrency And Filesystem Semantics

Cold bootstraps use unique sibling temporary files and do not intentionally
publish partial downloads. Same-pin concurrent first runs are intended to be
integrity-safe but best-effort; they are not serialized by a lock. *(maintainer)*

Each cold invocation snapshots one trusted version/digest pair. A competing
publisher may be accepted only when the destination satisfies that same pin;
otherwise the invocation fails. Concurrent edits to trusted configuration are
out of scope. *(maintainer)*

Wrapper-task postprocessing spans two launchers and the properties file. The
design does not claim an atomic multi-file transaction. A write failure can
leave a partially regenerated tracked tree, but the task remains unsuccessful
and the repository invariant check must remain red. *(maintainer)*

Shared writable caches, cross-user execution, symlink attacks by an actor who
can already modify the checkout, and privilege transitions are not supported
deployment models. *(maintainer)*

## Out Of Scope And Non-Goals

The component does not defend against: *(maintainer)*

- malicious or accidental modification of tracked project files, launchers,
  helpers, the init script, the committed pin, build logic, or dependencies;
- replacement, corruption, or staleness of an existing ignored local Wrapper
  JAR;
- compromise of the host, toolchain, installed or Wrapper-launched Gradle,
  ambient Gradle state, user-home caches, shell, PowerShell, JDK, network tool,
  or filesystem;
- execution as a privilege boundary or through a shared writable Wrapper cache;
- arbitrary custom Wrapper JAR sources, Gradle forks, mirrors, custom
  distributions, prereleases, snapshots, or launcher formats that do not expose
  the required unambiguous structural invocation;
- independently installed Gradle running `wrapper` without explicitly
  attaching the checked-in init script;
- a different component mutating the same generated outputs after the Buildish
  final action;
- automatic repair of launcher drift outside an enhanced Wrapper task;
- authentication or revalidation of a previously cached Gradle distribution;
  and
- confidentiality, sandboxing, dependency verification, or protection from
  malicious Gradle build logic.

Availability of the upstream host and bounded completion under hostile local
resource exhaustion are also not guaranteed. Network timeouts and response
limits bound the component's own cold request; they are not a general host
resource isolation mechanism. *(maintainer)*

## Claimed Security Properties

These properties apply to the implemented development tree under the stated
trusted environment. *(documented)*

| Target property | Conditions | Violation symptom | Triage class |
| --- | --- | --- | --- |
| Downloaded JAR bytes are not published to the executable final path until their SHA-256 equals the committed pin. *(maintainer)* | Trusted checkout, host, tools, configuration, and hashing implementation; final JAR initially absent | Mismatching network bytes become the final executable JAR | Security-critical integrity failure |
| Invalid Wrapper configuration on the cold path fails before a network download or execution of newly downloaded bytes. *(maintainer)* | Final JAR is absent; canonical parser and fixed upstream URL derivation are intact | Missing, duplicate, malformed, or noncanonical cold configuration reaches download or execution | Security-relevant validation failure |
| A failed, oversized, timed-out, or digest-mismatched cold response is not executed and does not replace a valid preexisting final JAR. *(maintainer)* | Failure occurs in the Buildish-managed cold path | Unverified bytes execute, or unrelated valid final state is destroyed | Security-critical integrity failure or correctness failure, depending on symptom |
| The cold response is limited to 10 MiB and bounded connection and total request time. *(maintainer)* | Host networking and timeout primitives behave as specified | Buildish accepts a larger response or waits beyond its configured bound | Availability hardening failure |
| Same-pin concurrent cold publishers cannot make mismatching or partial bytes executable. *(maintainer)* | Configuration is not edited concurrently; filesystem primitives meet supported assumptions | Race publishes bytes that do not match the snapshotted pin | Security-critical integrity failure |
| Generated tracked Wrapper state contains the executing stable Gradle identity, actual generated JAR digest, canonical official binary target, and one unambiguous launcher invocation shape. *(maintainer)* | Enhanced root Wrapper task is used through a supported entry point | Buildish reports success after writing malformed, incoherent, or structurally ambiguous tracked integration | Security-relevant generation failure |
| The repository invariant rejects tracked compiled bootstrap executables, incoherent integration state, and checkout attributes that can rewrite canonical executable source bytes. *(maintainer)* | The invariant check is run against the complete tracked tree | The check passes with a tracked Wrapper JAR/class, mismatched integration, or overridden canonical checkout attributes | Release/tracking correctness failure |

The project makes no confidentiality claim and does not classify every denial
of service or generation failure as a vulnerability. Exploitability, actor
capability, and the violated property must be assessed together. *(maintainer)*

## Disclaimed Properties And False Friends

- **An existing JAR is not authenticated.** Existence selects the trusted warm
  path; it is not evidence that the current bytes still match the committed
  digest. *(maintainer)*
- **SHA-256 is not publisher identity.** The committed digest authorizes exact
  bytes reviewed by the project. It does not independently attest who produced
  those bytes. *(maintainer)*
- **HTTPS is not the authorization root.** Transport protects a connection,
  while the committed digest decides which cold bytes may become executable.
  *(maintainer)*
- **`distributionSha256Sum` is not continuous cache validation.** It protects
  Gradle provisioning of missing distribution state, not every reuse of an
  existing user-home distribution. *(maintainer)*
- **A clean repository check is not a source-archive proof.** Git tracking and
  archive assembly are separate inventories. *(maintainer)*
- **A successful first update pass need not equalize versions.** A reviewed
  Wrapper JAR from version A may start a separately pinned distribution B.
  *(maintainer)*
- **Task failure is not transactional rollback.** The enhanced Wrapper task can
  fail after Gradle or Buildish has written only some generated files.
  *(maintainer)*
- **The bootstrap is not a sandbox or local tamper monitor.** Write access to
  the checkout or ignored JAR is already control over executable project state.
  *(maintainer)*

## Controls And Failure Behavior

- Missing, duplicate, or malformed Wrapper configuration returns
  nonzero and identifies the expected property form before download.
  *(maintainer)*
- Network failure, timeout, response-limit failure, and digest mismatch return
  nonzero, remove the invocation's temporary file, and do not execute the
  response. *(maintainer)*
- Publication failure returns nonzero unless a competing final JAR satisfies
  the invocation's snapshotted pin. *(maintainer)*
- An existing but unusable warm JAR is reported by Java or Gradle. Recovery is
  to delete only `gradle/wrapper/gradle-wrapper.jar` and retry the command so
  the cold controls run again. *(maintainer)*
- Unsupported or ambiguous launcher anchors fail the Wrapper task rather than
  guessing at a patch location. *(maintainer)*
- Postprocessing failure requires inspection of the tracked diff and restoration
  from version control or regeneration from a known-good launcher. Coherence is
  not claimed until the repository invariant passes. *(maintainer)*

## Downstream Responsibilities

Adopters and maintainers are responsible for: *(maintainer)*

- reviewing and committing the Wrapper JAR version, digest, target distribution
  URL, and distribution digest as trusted project configuration;
- preserving trusted control of the checkout, ignored project-local JAR, host,
  Gradle toolchain, and user-home state;
- running the enhanced top-level Wrapper task through a supported launcher or
  explicitly attaching the project init script for initial adoption/recovery;
- reviewing the complete generated diff and running the repository invariant
  before accepting an update;
- deleting an existing local JAR when corruption or provenance is in doubt, so
  a new cold download must pass the committed pin;
- using isolated project-local state rather than a shared writable Wrapper JAR
  path or a privilege transition;
- applying the documented native-Windows stable-launcher procedure when an
  update may replace the control-flow generation of the executing batch file;
  and
- establishing the provenance of any future source archive through the
  separately approved release process.

## Misuse Patterns And Known Non-Findings

Misuse patterns include treating this component as protection against an
untrusted checkout, copying only part of the generated integration, running a
bare installed `gradle wrapper` without the init script, or assuming an
existing ignored JAR is continuously verified. Those uses violate the trusted
state or supported-entrypoint contract. *(maintainer)*

Recurring findings that are not security vulnerabilities under this model
include: *(maintainer)*

- “The warm path does not hash the JAR”: by design, the existing JAR is trusted
  local state.
- “A local user can replace the helper, pin, launcher, or JAR”: that actor
  already controls executable checkout state.
- “The Wrapper JAR version differs from the target distribution”: the two-step
  update lifecycle intentionally permits a reviewed A-to-B state.
- “Wrapper postprocessing is not atomic”: task failure and a red invariant are
  the recovery boundary; atomic multi-file generation is not claimed.
- “A configured distribution digest does not recheck a cached distribution”:
  reused Gradle state is trusted and managed by Gradle, not this bootstrap.

## Residual Risks

The primary residual risk is compromise or corruption inside the trusted local
boundary. Because the warm path prioritizes normal startup cost and accepts an
existing JAR, local changes can persist until the JAR is deleted or the
checkout is recreated. *(maintainer)*

The committed digest transfers review responsibility to project maintainers.
Committing the digest of malicious or unintended bytes authorizes those exact
bytes; runtime hashing cannot correct a bad reviewed pin. *(maintainer)*

Structural launcher matching trades breadth for inspectability. A new upstream
launcher shape or behavior can make update tasks fail until explicit support
and fixtures are added. *(maintainer)*

Concurrency is integrity-safe only for the same snapshotted pin under supported
filesystem semantics. It does not provide fairness, lock-based coordination, or
defined behavior for concurrent configuration edits. *(maintainer)*

Network limits reduce component-controlled resource exposure but cannot prevent
host-level starvation, compromised tools, or upstream unavailability.
*(maintainer)*

## Release Claim Limitation

The repository claim is limited to Git tracking: no compiled Wrapper executable
is tracked. No component release has been published, and excluding compiled
bootstrap executables from a future source release is still an objective rather
than a release fact. *(documented)*

Release publication remains blocked until the real component archive path
assembles and inspects the source archive while a local ignored Wrapper JAR is
present. `.gitignore`, a clean index, or a source-tree scan alone cannot satisfy
that gate. *(maintainer)*

Until that gate exists and passes, documentation and release metadata must not
state unconditional source-archive exclusion. A violation of that limitation is
a release-process or documentation defect; it is not automatically a runtime
vulnerability. *(maintainer)*

## Triage Guidance

The following dispositions form the closed routing set for reports against this
component. *(maintainer)*

| Disposition | Use when | Boundary |
| --- | --- | --- |
| `VALID-SECURITY` | An in-scope network input violates a claimed cold-path integrity property under the trusted-environment assumptions | Claimed properties and cold network boundary |
| `VALID-HARDENING` | No claimed integrity property is violated, but supported behavior can be made safer or more diagnosable | Controls and residual risks |
| `OUT-OF-MODEL: trusted-state` | The report requires modification or compromise of the checkout, committed pin, existing JAR, toolchain, host, or reused Gradle state | Out-of-scope capabilities |
| `OUT-OF-MODEL: unsupported-use` | The report requires a custom distribution, structurally incompatible launcher, shared writable cache, privilege transition, or unsupported invocation | Scope and non-goals |
| `BY-DESIGN: disclaimed-property` | The report concerns warm-path revalidation, version equality, atomic multi-file generation, or another explicit non-property | Disclaimed properties |
| `RELEASE-PROCESS` | The report concerns archive assembly or an unproved source-release claim rather than runtime execution | Release claim limitation |
| `DEPENDENCY-OR-DEPLOYMENT` | The root cause is Gradle, the JDK, host tooling, filesystem, cached distribution, or operator-controlled environment rather than a Buildish invariant | Responsibility boundary |
| `MODEL-GAP` | The report cannot be routed to one disposition without inventing a new assumption or property | Revise this model before final disposition |

A test demonstrates a security violation only when it shows an in-scope actor
crossing the stated boundary without already controlling trusted project or
host state. Privileged fixtures, mocked trust decisions, and already-authorized
local writes are not proof of a vulnerability. *(documented)*

## Verification And Revision Triggers

Validation must cover canonical configuration parsing, derived fixed URLs,
valid non-matrix versions, size and timeout bounds, mismatched digests,
temporary-file cleanup, cold publication, warm-path non-validation, same-pin concurrency,
launcher drift, generated-state coherence, and the absence of tracked compiled
bootstrap files. Tests are evidence for the contract, not a substitute for its
trust assumptions. *(maintainer)*

This model must be reviewed when any of the following changes: *(maintainer)*

- the cold download URL, digest source, limits, or publication algorithm;
- the treatment of an existing local JAR;
- stable-version validation, structural launcher matching, or supported
  generation paths;
- concurrency or filesystem assumptions;
- the source-archive assembly and exclusion gate;
- the trusted host, Gradle, or user-home boundary;
- security-sensitive implementation, workflow, or trust-contract sources; or
- a report reaches `MODEL-GAP`.
