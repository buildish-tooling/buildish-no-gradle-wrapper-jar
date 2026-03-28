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

# No Gradle® Wrapper JAR

No Gradle Wrapper JAR is a source-only blueprint for projects that want to use
the ordinary Gradle Wrapper launchers without tracking
`gradle/wrapper/gradle-wrapper.jar` in Git.

It is a Buildish tooling component for maintainers whose repository policy
avoids committed compiled binaries. The trade-off is a network- and
host-tool-dependent first run that creates an ignored executable local JAR;
later runs trust that checkout-local state.

The minimal bootstrap is implemented in the unreleased development tree. No
component release has been published. It is a three-source, project-local
integration whose only cold-network guarantee is that a downloaded Wrapper JAR
must match a committed SHA-256 before it is moved into the executable
`gradle-wrapper.jar` path. Existing checkout-local
state remains trusted.

No compiled Wrapper executable is tracked in Git. Source-release exclusion is
still an objective, and release publication remains blocked until the real
component archive path proves that exclusion.

Read the [security and trust summary](security/) or open the explicitly
unreleased development documentation for the adoption, lifecycle,
compatibility, recovery, and canonical threat-model contract.

{{< buildish-component-link kind="development" label="Open Unreleased Development Docs" appearance="primary" >}}
