#
# Copyright 2026 The Buildish Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

.DEFAULT_GOAL := check

HELP_TARGETS := $(MAKEFILE_LIST)

.PHONY: check clean help invariant-check invariant-self-check manifest-check
.PHONY: posix-runtime-check rat-check release-check
.PHONY: powershell-unit-check renovate-check syntax-check test windows-check
.PHONY: wrapper-lifecycle-check

help: ## Show available Make targets.
	@awk 'BEGIN {FS = ":.*## "; printf "Available targets:\n"} /^[a-zA-Z0-9_.-]+:.*## / {printf "  %-24s %s\n", $$1, $$2}' $(HELP_TARGETS)

syntax-check: ## Parse all shipped and test source files without executing product behavior.
	@test -f buildish-wrapper-bootstrap.sh || { echo 'syntax-check: missing canonical product source: buildish-wrapper-bootstrap.sh' >&2; exit 1; }
	@test -f buildish-wrapper-bootstrap.ps1 || { echo 'syntax-check: missing canonical product source: buildish-wrapper-bootstrap.ps1' >&2; exit 1; }
	@test -f buildish-wrapper.init.gradle.kts || { echo 'syntax-check: missing canonical product source: buildish-wrapper.init.gradle.kts' >&2; exit 1; }
	sh -n buildish-wrapper-bootstrap.sh scripts/rat-check.sh
	@for file in tests/integration.sh tests/lib/*.sh tests/suites/*.sh; do bash -n "$$file" || exit 1; done
	PYTHONPYCACHEPREFIX=build/pycache python3 -m py_compile scripts/check-repository-invariants.py tests/fixtures/http-server.py tests/fixtures/launcher-contract.py
	pwsh -NoLogo -NoProfile -Command '$$files=@("buildish-wrapper-bootstrap.ps1","tests/windows-integration.ps1"); $$files += @(Get-ChildItem tests/windows -Filter *.ps1 -Recurse -File).FullName; foreach($$file in $$files){ $$tokens=$$null; $$errors=$$null; [void][System.Management.Automation.Language.Parser]::ParseFile([System.IO.Path]::GetFullPath($$file), [ref]$$tokens, [ref]$$errors); if($$errors.Count -gt 0){ $$errors | ForEach-Object { $$_.ToString() }; exit 1 } }'

powershell-unit-check: ## Run platform-neutral PowerShell harness unit checks.
	pwsh -NoLogo -NoProfile -File tests/windows/unit/fixtures.tests.ps1

manifest-check: ## Validate the offline test matrix and exact raw launcher fixtures.
	python3 scripts/check-repository-invariants.py --manifest

invariant-self-check: ## Exercise focused repository and consumer invariant failures.
	bash tests/integration.sh invariants

invariant-check: ## Validate this repository's complete integration offline.
	python3 scripts/check-repository-invariants.py --repository .

posix-runtime-check: ## Run focused POSIX cold/warm bootstrap tests.
	bash tests/integration.sh runtime

wrapper-lifecycle-check: ## Run adoption and Wrapper lifecycle tests.
	bash tests/integration.sh lifecycle

renovate-check: ## Run the pinned Renovate task-execution fixture.
	bash tests/integration.sh renovate

test: invariant-self-check posix-runtime-check wrapper-lifecycle-check renovate-check ## Run the non-Windows integration suites.

windows-check: ## Run the native-Windows entry point (requires native Windows).
	powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests/windows-integration.ps1 -Suite All

rat-check: ## Run Apache RAT against this component (requires Java 21+).
	sh scripts/rat-check.sh

check: syntax-check powershell-unit-check manifest-check invariant-check test rat-check ## Run the complete non-Windows validation suite.

release-check: check ## Run the release-oriented repository checks without claiming Windows/archive proof.

clean: ## Remove generated build outputs for this component.
	rm -rf build
