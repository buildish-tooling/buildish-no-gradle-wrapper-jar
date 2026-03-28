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

# Security Policy

## Supported versions

Buildish has not published a release of this component. The minimal Wrapper
bootstrap is implemented and validated in the development tree, but must not
be represented as a published component release.

Security reports affecting the current development branch are welcome. State
the exact revision and whether the report concerns implemented behavior or the
documented contract.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Report it privately
to [security@buildish.org](mailto:security@buildish.org), including the affected
component and revision, expected security property, impact, and reproduction
details where possible.

## Canonical threat model

The versioned [`docs/threat-model.md`](docs/threat-model.md) is the canonical
threat model for this component. It defines the actors, trust boundaries,
provided and disclaimed properties, deployment responsibilities, and triage
guidance. Read it before reporting or changing security-sensitive behavior.

The intended runtime boundary is deliberately narrow: a Wrapper JAR downloaded
by the Buildish bootstrap must match the committed project SHA-256 before it is
published to the executable path. The tracked checkout, committed pin, host
tools, generation environment, and an existing local ignored Wrapper JAR are
trusted state. Reports based only on modification of that trusted state may be
outside this component's claimed security boundary.

The short [site security summary](site/pages/security.md) is navigation and
operator guidance. If it differs from the versioned threat model, the threat
model controls.
