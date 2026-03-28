#!/usr/bin/env python3
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

"""Check the Buildish Wrapper test matrix, repository, or consumer."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import Any, Iterable

sys.dont_write_bytecode = True

Diagnostic = tuple[str, str]
HEX_64 = re.compile(r"^[0-9a-f]{64}$")
STABLE_VERSION = re.compile(
    r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$"
)
OFFICIAL_DISTRIBUTION_URL = re.compile(
    r"^https://services\.gradle\.org/distributions/"
    r"gradle-((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\."
    r"(?:0|[1-9][0-9]*))-bin\.zip$"
)
LICENSE_TOKEN = "Licensed under the Apache License, Version 2.0"
CANONICAL_SOURCES = (
    "buildish-wrapper-bootstrap.sh",
    "buildish-wrapper-bootstrap.ps1",
    "buildish-wrapper.init.gradle.kts",
)
IGNORE_LINES = (
    "/gradle/wrapper/gradle-wrapper.jar",
    "/.gradlew-buildish-update-*.bat",
)
REPOSITORY_ATTRIBUTE_LINES = (
    "tests/fixtures/compatibility-manifest.json text eol=lf",
    "tests/fixtures/launchers/*/gradlew text eol=lf",
    "tests/fixtures/launchers/*/gradlew.bat -text",
    *(f"/{source} text eol=lf" for source in CANONICAL_SOURCES),
)
RAW_JAR_PREFIX = "https://raw.githubusercontent.com/gradle/gradle/"
EXPECTED_RENOVATE_CONFIG = {
    "enabledManagers": ["gradle-wrapper"],
}


class DuplicateJsonKey(ValueError):
    pass


def _object_without_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJsonKey(f"duplicate object key: {key}")
        result[key] = value
    return result


def _read_json(path: Path, label: str) -> tuple[Any | None, list[Diagnostic]]:
    try:
        data = json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=_object_without_duplicates
        )
    except (OSError, UnicodeError, json.JSONDecodeError, DuplicateJsonKey) as exc:
        return None, [(label, f"cannot read JSON: {exc}")]
    return data, []


def _compare_exact(actual: Any, expected: Any, pointer: str) -> list[Diagnostic]:
    diagnostics: list[Diagnostic] = []
    if type(actual) is not type(expected):
        return [(pointer or "/", f"expected {type(expected).__name__}, found {type(actual).__name__}")]
    if isinstance(expected, dict):
        for key in expected.keys() - actual.keys():
            diagnostics.append((f"{pointer}/{key}", "required key is missing"))
        for key in actual.keys() - expected.keys():
            diagnostics.append((f"{pointer}/{key}", "unexpected key"))
        for key in expected.keys() & actual.keys():
            diagnostics.extend(_compare_exact(actual[key], expected[key], f"{pointer}/{key}"))
    elif isinstance(expected, list):
        if len(actual) != len(expected):
            diagnostics.append((pointer or "/", f"expected {len(expected)} entries, found {len(actual)}"))
        for index, (actual_item, expected_item) in enumerate(zip(actual, expected)):
            diagnostics.extend(_compare_exact(actual_item, expected_item, f"{pointer}/{index}"))
    elif actual != expected:
        diagnostics.append((pointer or "/", f"expected {expected!r}, found {actual!r}"))
    return diagnostics


def _safe_repository_path(
    root: Path, relative: object, pointer: str
) -> tuple[Path | None, list[Diagnostic]]:
    if not isinstance(relative, str):
        return None, [(pointer, "path must be a string")]
    logical = PurePosixPath(relative)
    if logical.is_absolute() or not logical.parts or any(
        part in ("", ".", "..") for part in logical.parts
    ):
        return None, [(pointer, "path must be normalized and repository-relative")]
    if "\\" in relative:
        return None, [(pointer, "path must use forward slashes")]
    canonical_root = root.resolve()
    candidate = root.joinpath(*logical.parts)
    try:
        candidate.resolve(strict=False).relative_to(canonical_root)
    except (OSError, ValueError):
        return None, [(pointer, "path escapes the repository root")]
    current = root
    for part in logical.parts:
        current = current / part
        if current.is_symlink():
            return None, [(pointer, f"path traverses symbolic link: {current.relative_to(root)}")]
    return candidate, []


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _display(root: Path, path: Path) -> str:
    try:
        return path.absolute().relative_to(root.absolute()).as_posix()
    except ValueError:
        return path.as_posix()


def _load_launcher_checker(root: Path) -> tuple[Any | None, list[Diagnostic]]:
    path = root / "tests/fixtures/launcher-contract.py"
    if not path.is_file():
        return None, [(_display(root, path), "launcher contract checker is missing")]
    spec = importlib.util.spec_from_file_location("buildish_launcher_contract", path)
    if spec is None or spec.loader is None:
        return None, [(_display(root, path), "cannot load launcher contract checker")]
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:  # The checker is an implementation input, not user data.
        return None, [(_display(root, path), f"cannot load launcher contract checker: {exc}")]
    return module, []


def _check_keys(value: object, expected: set[str], pointer: str) -> list[Diagnostic]:
    if not isinstance(value, dict):
        return [(pointer, "must be an object")]
    diagnostics: list[Diagnostic] = []
    for key in expected - value.keys():
        diagnostics.append((f"{pointer}/{key}", "required key is missing"))
    for key in value.keys() - expected:
        diagnostics.append((f"{pointer}/{key}", "unexpected key"))
    return diagnostics


def _validate_test_matrix(manifest: object) -> list[Diagnostic]:
    root_keys = {
        "schemaVersion",
        "wrapperVersions",
        "targetDistributions",
        "transitions",
        "installedGradleCases",
        "nativeWindows",
        "renovate",
    }
    diagnostics = _check_keys(manifest, root_keys, "")
    if not isinstance(manifest, dict):
        return diagnostics
    if manifest.get("schemaVersion") != 1:
        diagnostics.append(("/schemaVersion", "must equal 1"))

    wrappers = manifest.get("wrapperVersions")
    wrapper_versions: set[str] = set()
    if not isinstance(wrappers, list) or not wrappers:
        diagnostics.append(("/wrapperVersions", "must be a non-empty array"))
        wrappers = []
    for index, wrapper in enumerate(wrappers):
        pointer = f"/wrapperVersions/{index}"
        diagnostics.extend(
            _check_keys(
                wrapper,
                {
                    "version",
                    "rawTag",
                    "rawJarUrl",
                    "wrapperJarSha256",
                    "publishedChecksumUrl",
                    "launchers",
                },
                pointer,
            )
        )
        if not isinstance(wrapper, dict):
            continue
        version = wrapper.get("version")
        if not isinstance(version, str) or not STABLE_VERSION.fullmatch(version):
            diagnostics.append((f"{pointer}/version", "must be a canonical stable version"))
            continue
        if version in wrapper_versions:
            diagnostics.append((f"{pointer}/version", f"duplicate tested version: {version}"))
        wrapper_versions.add(version)
        expected_values = {
            "rawTag": f"v{version}",
            "rawJarUrl": f"{RAW_JAR_PREFIX}v{version}/gradle/wrapper/gradle-wrapper.jar",
            "publishedChecksumUrl": (
                f"https://services.gradle.org/distributions/"
                f"gradle-{version}-wrapper.jar.sha256"
            ),
        }
        for key, expected in expected_values.items():
            if wrapper.get(key) != expected:
                diagnostics.append((f"{pointer}/{key}", f"must equal {expected!r}"))
        if not isinstance(wrapper.get("wrapperJarSha256"), str) or not HEX_64.fullmatch(
            wrapper["wrapperJarSha256"]
        ):
            diagnostics.append((f"{pointer}/wrapperJarSha256", "must be 64 lowercase hexadecimal characters"))
        launchers = wrapper.get("launchers")
        diagnostics.extend(_check_keys(launchers, {"posix", "windows"}, f"{pointer}/launchers"))
        if isinstance(launchers, dict):
            for kind, basename in (("posix", "gradlew"), ("windows", "gradlew.bat")):
                entry = launchers.get(kind)
                entry_pointer = f"{pointer}/launchers/{kind}"
                diagnostics.extend(_check_keys(entry, {"path", "sha256"}, entry_pointer))
                if not isinstance(entry, dict):
                    continue
                expected_path = f"tests/fixtures/launchers/{version}/{basename}"
                if entry.get("path") != expected_path:
                    diagnostics.append((f"{entry_pointer}/path", f"must equal {expected_path!r}"))
                if not isinstance(entry.get("sha256"), str) or not HEX_64.fullmatch(entry["sha256"]):
                    diagnostics.append((f"{entry_pointer}/sha256", "must be 64 lowercase hexadecimal characters"))

    targets = manifest.get("targetDistributions")
    target_versions: set[str] = set()
    if not isinstance(targets, list) or not targets:
        diagnostics.append(("/targetDistributions", "must be a non-empty array"))
        targets = []
    for index, target in enumerate(targets):
        pointer = f"/targetDistributions/{index}"
        diagnostics.extend(_check_keys(target, {"version", "url", "sha256"}, pointer))
        if not isinstance(target, dict):
            continue
        version = target.get("version")
        if not isinstance(version, str) or not STABLE_VERSION.fullmatch(version):
            diagnostics.append((f"{pointer}/version", "must be a canonical stable version"))
            continue
        if version in target_versions:
            diagnostics.append((f"{pointer}/version", f"duplicate tested target: {version}"))
        target_versions.add(version)
        expected_url = f"https://services.gradle.org/distributions/gradle-{version}-bin.zip"
        if target.get("url") != expected_url:
            diagnostics.append((f"{pointer}/url", f"must equal {expected_url!r}"))
        if not isinstance(target.get("sha256"), str) or not HEX_64.fullmatch(target["sha256"]):
            diagnostics.append((f"{pointer}/sha256", "must be 64 lowercase hexadecimal characters"))

    for collection, source_key in (
        ("transitions", "bootstrapVersion"),
        ("installedGradleCases", "installedVersion"),
    ):
        entries = manifest.get(collection)
        if not isinstance(entries, list):
            diagnostics.append((f"/{collection}", "must be an array"))
            continue
        seen: set[tuple[str, str]] = set()
        for index, entry in enumerate(entries):
            pointer = f"/{collection}/{index}"
            diagnostics.extend(_check_keys(entry, {source_key, "targetVersion"}, pointer))
            if not isinstance(entry, dict):
                continue
            source = entry.get(source_key)
            target = entry.get("targetVersion")
            if isinstance(source, str) and isinstance(target, str):
                pair = (source, target)
                if pair in seen:
                    diagnostics.append((pointer, f"duplicate test case: {source} -> {target}"))
                seen.add(pair)
            if not isinstance(source, str) or source not in wrapper_versions:
                diagnostics.append((f"{pointer}/{source_key}", "must reference a tested Wrapper version"))
            if not isinstance(target, str) or target not in target_versions:
                diagnostics.append((f"{pointer}/targetVersion", "must reference a tested target version"))

    native = manifest.get("nativeWindows")
    diagnostics.extend(_check_keys(native, {"launcherVersions", "stableCopyExitCodes"}, "/nativeWindows"))
    if isinstance(native, dict):
        launcher_versions = native.get("launcherVersions")
        if not isinstance(launcher_versions, list) or not launcher_versions:
            diagnostics.append(("/nativeWindows/launcherVersions", "must be a non-empty array"))
        elif any(not isinstance(version, str) for version in launcher_versions) or any(
            launcher_versions.count(version) != 1 or version not in wrapper_versions
            for version in launcher_versions
        ):
            diagnostics.append(("/nativeWindows/launcherVersions", "must uniquely reference tested Wrapper versions"))
        exit_codes = native.get("stableCopyExitCodes")
        if not isinstance(exit_codes, list) or any(type(code) is not int for code in exit_codes):
            diagnostics.append(("/nativeWindows/stableCopyExitCodes", "must be an integer array"))

    renovate = manifest.get("renovate")
    renovate_keys = {
        "version",
        "manager",
        "fromVersion",
        "toVersion",
        "binarySource",
        "allowedUnsafeExecutions",
    }
    diagnostics.extend(_check_keys(renovate, renovate_keys, "/renovate"))
    if isinstance(renovate, dict):
        if (
            not isinstance(renovate.get("fromVersion"), str)
            or renovate.get("fromVersion") not in wrapper_versions
        ):
            diagnostics.append(("/renovate/fromVersion", "must reference a tested Wrapper version"))
        if (
            not isinstance(renovate.get("toVersion"), str)
            or renovate.get("toVersion") not in target_versions
        ):
            diagnostics.append(("/renovate/toVersion", "must reference a tested target version"))
        if renovate.get("manager") != "gradle-wrapper":
            diagnostics.append(("/renovate/manager", "must equal 'gradle-wrapper'"))
        if renovate.get("binarySource") != "global":
            diagnostics.append(("/renovate/binarySource", "must equal 'global'"))
        if renovate.get("allowedUnsafeExecutions") != ["gradleWrapper"]:
            diagnostics.append(("/renovate/allowedUnsafeExecutions", "must equal ['gradleWrapper']"))
    return diagnostics


def check_manifest(root: Path) -> tuple[dict[str, Any] | None, list[Diagnostic]]:
    path = root / "tests/fixtures/compatibility-manifest.json"
    manifest, diagnostics = _read_json(path, "tests/fixtures/compatibility-manifest.json")
    if manifest is None:
        return None, diagnostics
    diagnostics.extend(_validate_test_matrix(manifest))

    wrappers = manifest.get("wrapperVersions") if isinstance(manifest, dict) else None
    if isinstance(wrappers, list):
        for wrapper_index, wrapper in enumerate(wrappers):
            if not isinstance(wrapper, dict):
                continue
            launchers = wrapper.get("launchers")
            if not isinstance(launchers, dict):
                continue
            for kind in ("posix", "windows"):
                entry = launchers.get(kind)
                pointer = f"/wrapperVersions/{wrapper_index}/launchers/{kind}"
                if not isinstance(entry, dict):
                    continue
                fixture, path_diagnostics = _safe_repository_path(
                    root, entry.get("path"), f"{pointer}/path"
                )
                diagnostics.extend(path_diagnostics)
                if fixture is None:
                    continue
                if not fixture.is_file():
                    diagnostics.append((_display(root, fixture), "fixture is not a regular file"))
                    continue
                expected_digest = entry.get("sha256")
                if not isinstance(expected_digest, str) or not HEX_64.fullmatch(expected_digest):
                    diagnostics.append((f"{pointer}/sha256", "must be 64 lowercase hexadecimal characters"))
                    continue
                try:
                    actual_digest = _sha256(fixture)
                except OSError as exc:
                    diagnostics.append((_display(root, fixture), f"cannot hash fixture: {exc}"))
                else:
                    if actual_digest != expected_digest:
                        diagnostics.append(
                            (_display(root, fixture), f"SHA-256 mismatch: expected {expected_digest}, found {actual_digest}")
                        )

    checker, checker_diagnostics = _load_launcher_checker(root)
    diagnostics.extend(checker_diagnostics)
    if checker is not None:
        for launcher_path, reason in checker.check_fixtures(path):
            launcher = Path(launcher_path)
            diagnostics.append((_display(root, launcher), reason))
    return manifest if isinstance(manifest, dict) else None, diagnostics


def _git_paths(root: Path, include_untracked: bool = False) -> tuple[list[str], list[Diagnostic]]:
    command = ["git", "-C", str(root), "ls-files", "-z"]
    if include_untracked:
        command.extend(["--cached", "--others", "--exclude-standard"])
    try:
        result = subprocess.run(command, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        return [], [(".git", f"cannot invoke Git: {exc}")]
    if result.returncode != 0:
        reason = result.stderr.decode("utf-8", errors="replace").strip()
        return [], [(".git", f"cannot enumerate files: {reason or f'exit {result.returncode}'}")]
    return [os.fsdecode(item) for item in result.stdout.split(b"\0") if item], []


def _check_regular(root: Path, relative: str, required: bool = True) -> list[Diagnostic]:
    path = root / relative
    if path.is_symlink():
        return [(relative, "must be a regular file, not a symbolic link")]
    if not path.is_file():
        return [(relative, "required file is missing")] if required else []
    return []


def _check_product_contract(root: Path, manifest: dict[str, Any]) -> list[Diagnostic]:
    diagnostics: list[Diagnostic] = []
    paths = {name: root / name for name in CANONICAL_SOURCES}
    if not all(path.is_file() and not path.is_symlink() for path in paths.values()):
        return diagnostics
    try:
        texts = {name: path.read_text(encoding="utf-8") for name, path in paths.items()}
    except (OSError, UnicodeError) as exc:
        return [(".", f"cannot read canonical source for version-agnostic validation: {exc}")]
    for helper_name in (CANONICAL_SOURCES[0], CANONICAL_SOURCES[1]):
        text = texts[helper_name]
        prefix_count = text.count(RAW_JAR_PREFIX)
        if prefix_count != 1:
            diagnostics.append(
                (helper_name, f"expected one fixed raw JAR URL prefix, found {prefix_count}")
            )
    forbidden_symbols = ("wrapperDigests", "targetDistributions", "windowsJavaAnchors")
    tested_literals: set[str] = set()
    for wrapper in manifest.get("wrapperVersions", []):
        if isinstance(wrapper, dict):
            tested_literals.update(
                value
                for key in ("version", "rawTag", "rawJarUrl", "wrapperJarSha256")
                if isinstance((value := wrapper.get(key)), str)
            )
    for target in manifest.get("targetDistributions", []):
        if isinstance(target, dict):
            tested_literals.update(
                value
                for key in ("version", "url", "sha256")
                if isinstance((value := target.get(key)), str)
            )
    for source, text in texts.items():
        for symbol in forbidden_symbols:
            if symbol in text:
                diagnostics.append((source, f"contains product allowlist symbol: {symbol}"))
        for literal in tested_literals:
            if literal in text:
                diagnostics.append((source, f"contains tested-version literal: {literal}"))
    return diagnostics


def _check_attribute_contract(
    root: Path,
    required_lines: tuple[str, ...],
    expected: dict[str, dict[str, str]],
) -> list[Diagnostic]:
    relative = ".gitattributes"
    try:
        lines = (root / relative).read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return [(relative, f"cannot read checkout attributes: {exc}")]
    diagnostics: list[Diagnostic] = []
    for required in required_lines:
        count = lines.count(required)
        if count != 1:
            diagnostics.append(
                (relative, f"expected one canonical checkout rule {required!r}, found {count}")
            )
    if not (root / ".git").exists():
        return diagnostics
    command = ["git", "-C", str(root), "check-attr", "-z", "text", "eol", "--", *expected]
    try:
        result = subprocess.run(command, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        diagnostics.append((relative, f"cannot invoke Git to resolve checkout attributes: {exc}"))
        return diagnostics
    if result.returncode != 0:
        reason = result.stderr.decode("utf-8", errors="replace").strip()
        diagnostics.append((relative, f"cannot resolve checkout attributes: {reason or f'exit {result.returncode}'}"))
        return diagnostics
    fields = result.stdout.split(b"\0")
    if fields and not fields[-1]:
        fields.pop()
    if len(fields) % 3 != 0:
        diagnostics.append((relative, "Git returned malformed checkout-attribute output"))
        return diagnostics
    actual: dict[str, dict[str, str]] = {}
    for index in range(0, len(fields), 3):
        path = os.fsdecode(fields[index])
        attribute = fields[index + 1].decode("ascii", errors="replace")
        value = fields[index + 2].decode("ascii", errors="replace")
        actual.setdefault(path, {})[attribute] = value
    for path, attributes in expected.items():
        for attribute, value in attributes.items():
            found = actual.get(path, {}).get(attribute, "unspecified")
            if found != value:
                diagnostics.append(
                    (relative, f"effective {attribute} for {path!r} must be {value!r}, found {found!r}")
                )
    return diagnostics


def _repository_attribute_contract(manifest: dict[str, Any]) -> dict[str, dict[str, str]]:
    expected = {
        source: {"text": "set", "eol": "lf"} for source in CANONICAL_SOURCES
    }
    expected["tests/fixtures/compatibility-manifest.json"] = {"text": "set", "eol": "lf"}
    for wrapper in manifest.get("wrapperVersions", []):
        if not isinstance(wrapper, dict) or not isinstance(wrapper.get("launchers"), dict):
            continue
        for kind, attributes in (
            ("posix", {"text": "set", "eol": "lf"}),
            ("windows", {"text": "unset", "eol": "unspecified"}),
        ):
            entry = wrapper["launchers"].get(kind)
            if isinstance(entry, dict) and isinstance(entry.get("path"), str):
                expected[entry["path"]] = attributes
    return expected


def _consumer_attribute_contract(
    has_posix_launcher: bool, has_windows_launcher: bool
) -> dict[str, dict[str, str]]:
    expected = {
        "gradle/buildish-wrapper.init.gradle.kts": {"text": "set", "eol": "lf"},
    }
    if has_posix_launcher:
        expected.update(
            {
                "gradlew": {"text": "set", "eol": "lf"},
                "gradle/buildish-wrapper-bootstrap.sh": {"text": "set", "eol": "lf"},
            }
        )
    if has_windows_launcher:
        expected.update(
            {
                "gradlew.bat": {"text": "unset", "eol": "unspecified"},
                "gradle/buildish-wrapper-bootstrap.ps1": {"text": "set", "eol": "lf"},
            }
        )
    return expected


def _consumer_attribute_lines(
    has_posix_launcher: bool, has_windows_launcher: bool
) -> tuple[str, ...]:
    lines = ["/gradle/buildish-wrapper.init.gradle.kts text eol=lf"]
    if has_posix_launcher:
        lines.extend(
            (
                "/gradlew text eol=lf",
                "/gradle/buildish-wrapper-bootstrap.sh text eol=lf",
            )
        )
    if has_windows_launcher:
        lines.extend(
            (
                "/gradlew.bat -text",
                "/gradle/buildish-wrapper-bootstrap.ps1 text eol=lf",
            )
        )
    return tuple(lines)


STALE_LITERAL_TOKENS = (
    "bootstrap-install.sh",
    "bootstrap-install.ps1",
    "unsafe-dev-install.sh",
    "unsafe-dev-install.ps1",
    "install.sh",
    "install.ps1",
    "SECURITY-ASSESSMENT.md",
    "secure-installer-approach.md",
    "release-work.md",
    ".github/signatures",
    "BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS",
    "BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS",
    'for /f "delims="',
    "stage-bootstrap-assets",
    "publish-immutable-github-release-assets",
    "gradle-wrapper.jar.asc",
    "gradle-wrapper.jar.sha256",
)
STALE_SCAN_EXEMPT = {
    "scripts/check-repository-invariants.py",
    "tests/fixtures/launcher-contract.py",
    "tests/suites/integration-invariants.sh",
    "buildish-release-tooling/RELEASE-PROCESS.md",
    "buildish-release-tooling/release-tooling.sh",
    ".github/workflows/releasey-10-create-release-branch.yml",
    ".github/workflows/releasey-40-verify-rc.yml",
}


def _check_stale_references(root: Path, paths: Iterable[str]) -> list[Diagnostic]:
    diagnostics: list[Diagnostic] = []
    for relative in sorted(set(paths)):
        if relative in STALE_SCAN_EXEMPT or relative.startswith((".agents/", "build/", ".git/")):
            continue
        path = root / relative
        if not path.is_file() or path.is_symlink():
            continue
        try:
            data = path.read_bytes()
        except OSError as exc:
            diagnostics.append((relative, f"cannot scan for removed references: {exc}"))
            continue
        if b"\0" in data:
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        for token in STALE_LITERAL_TOKENS:
            if token in text:
                diagnostics.append((relative, f"contains removed active reference: {token}"))
    return diagnostics


def _check_text_contract(root: Path) -> list[Diagnostic]:
    diagnostics: list[Diagnostic] = []
    licensed = (
        *CANONICAL_SOURCES,
        "scripts/check-repository-invariants.py",
        "tests/integration.sh",
        "tests/lib/integration-common.sh",
        "tests/lib/integration-fixtures.sh",
        "tests/fixtures/http-server.py",
        "tests/fixtures/init-transform-check.gradle.kts",
        "tests/fixtures/launcher-contract.py",
        "tests/suites/integration-init-script.sh",
        "tests/suites/integration-invariants.sh",
        "tests/suites/integration-runtime.sh",
        "tests/fixtures/renovate/run-artifact-update.mjs",
        "tests/suites/integration-renovate.sh",
        "tests/windows-integration.ps1",
        "tests/windows/lib/assertions.ps1",
        "tests/windows/lib/consumer-fixture.ps1",
        "tests/windows/lib/gradle-harness.ps1",
        "tests/windows/lib/http-fixture.ps1",
        "tests/windows/lib/native-process.ps1",
        "tests/windows/lib/tool-fixtures.ps1",
        "tests/windows/suites/lifecycle.ps1",
        "tests/windows/suites/runtime.ps1",
        "tests/windows/suites/stable-copy.ps1",
        "tests/windows/unit/fixtures.tests.ps1",
    )
    commentless_json = (
        "tests/fixtures/compatibility-manifest.json",
        "tests/fixtures/renovate/config.json",
    )
    for relative in licensed:
        path = root / relative
        if not path.exists():
            continue
        try:
            data = path.read_bytes()
        except OSError as exc:
            diagnostics.append((relative, f"cannot read text file: {exc}"))
            continue
        if not data.endswith(b"\n"):
            diagnostics.append((relative, "text file must end with a newline"))
        if LICENSE_TOKEN.encode() not in data:
            diagnostics.append((relative, "Apache-2.0 license header is missing"))
    for relative in commentless_json:
        path = root / relative
        if not path.exists():
            continue
        try:
            data = path.read_bytes()
        except OSError as exc:
            diagnostics.append((relative, f"cannot read JSON fixture: {exc}"))
            continue
        if not data.endswith(b"\n"):
            diagnostics.append((relative, "JSON fixture must end with a newline"))
        if data.lstrip().startswith((b"//", b"/*", b"#")):
            diagnostics.append((relative, "JSON fixture must remain commentless; license header is exempt"))
    return diagnostics


def _check_renovate_config(root: Path) -> list[Diagnostic]:
    path = root / "tests/fixtures/renovate/config.json"
    if not path.exists():
        return []
    value, diagnostics = _read_json(path, "tests/fixtures/renovate/config.json")
    if value is not None:
        diagnostics.extend(_compare_exact(value, EXPECTED_RENOVATE_CONFIG, "/renovateFixture"))
    return diagnostics


def check_repository(root: Path) -> list[Diagnostic]:
    root = root.absolute()
    diagnostics: list[Diagnostic] = []
    for source in CANONICAL_SOURCES:
        diagnostics.extend(_check_regular(root, source))
    manifest, manifest_diagnostics = check_manifest(root)
    diagnostics.extend(manifest_diagnostics)
    if manifest is not None:
        diagnostics.extend(_check_product_contract(root, manifest))
        diagnostics.extend(
            _check_attribute_contract(
                root, REPOSITORY_ATTRIBUTE_LINES, _repository_attribute_contract(manifest)
            )
        )
    diagnostics.extend(_check_renovate_config(root))
    diagnostics.extend(_check_text_contract(root))

    tracked, git_diagnostics = _git_paths(root)
    diagnostics.extend(git_diagnostics)
    for relative in tracked:
        if relative.lower().endswith((".jar", ".class")):
            diagnostics.append((relative, "compiled bootstrap executable must not be tracked"))
    active, active_diagnostics = _git_paths(root, include_untracked=True)
    diagnostics.extend(active_diagnostics)
    diagnostics.extend(_check_stale_references(root, active))
    return diagnostics


def _property_definitions(
    text: str, key: str, value_pattern: str
) -> tuple[list[str], int]:
    canonical = re.compile(rf"{re.escape(key)}=({value_pattern})")
    any_definition = re.compile(rf"^[ \t]*{re.escape(key)}(?=[ \t:=\\]|$)")
    values: list[str] = []
    noncanonical = 0
    pending = ""
    was_continued = False
    logical_lines: list[tuple[str, bool]] = []
    for physical_line in text.splitlines():
        line = pending + (physical_line.lstrip(" \t\f") if pending else physical_line)
        trailing_backslashes = len(line) - len(line.rstrip("\\"))
        if trailing_backslashes % 2 == 1:
            pending = line[:-1]
            was_continued = True
            continue
        logical_lines.append((line, was_continued))
        pending = ""
        was_continued = False
    if pending:
        logical_lines.append((pending + "\\", True))

    for line, continued in logical_lines:
        match = canonical.fullmatch(line)
        if match is not None and not continued:
            values.append(match.group(1))
            continue
        decoded = _decode_java_property_escapes(line)
        if any_definition.match(decoded):
            noncanonical += 1
    return values, noncanonical


def _decode_java_property_escapes(value: str) -> str:
    """Decode the escape forms Java Properties.load accepts."""
    decoded: list[str] = []
    index = 0
    simple = {"t": "\t", "n": "\n", "r": "\r", "f": "\f"}
    while index < len(value):
        if value[index] != "\\":
            decoded.append(value[index])
            index += 1
            continue
        index += 1
        if index == len(value):
            decoded.append("\\")
            break
        escaped = value[index]
        if escaped == "u" and index + 4 < len(value):
            digits = value[index + 1 : index + 5]
            if re.fullmatch(r"[0-9A-Fa-f]{4}", digits):
                decoded.append(chr(int(digits, 16)))
                index += 5
                continue
        decoded.append(simple.get(escaped, escaped))
        index += 1
    return "".join(decoded)


def _check_consumer_properties(root: Path) -> tuple[str | None, str | None, list[Diagnostic]]:
    relative = "gradle/wrapper/gradle-wrapper.properties"
    path = root / relative
    try:
        text = path.read_text(encoding="iso-8859-1")
    except OSError as exc:
        return None, None, [(relative, f"cannot read Wrapper properties: {exc}")]
    diagnostics: list[Diagnostic] = []
    version_matches, version_noncanonical = _property_definitions(
        text,
        "buildishWrapperJarVersion",
        r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)",
    )
    digest_matches, digest_noncanonical = _property_definitions(
        text, "buildishWrapperJarSha256Sum", r"[0-9a-f]{64}"
    )
    url_matches, url_noncanonical = _property_definitions(
        text,
        "distributionUrl",
        r"https\\://services\.gradle\.org/distributions/"
        r"gradle-(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\."
        r"(?:0|[1-9][0-9]*)-bin\.zip",
    )
    target_digest_matches, target_digest_noncanonical = _property_definitions(
        text, "distributionSha256Sum", r"[0-9a-f]{64}"
    )
    for key, matches, noncanonical in (
        ("buildishWrapperJarVersion", version_matches, version_noncanonical),
        ("buildishWrapperJarSha256Sum", digest_matches, digest_noncanonical),
        ("distributionUrl", url_matches, url_noncanonical),
        ("distributionSha256Sum", target_digest_matches, target_digest_noncanonical),
    ):
        if len(matches) != 1:
            diagnostics.append((relative, f"expected one canonical {key}, found {len(matches)}"))
        if noncanonical:
            diagnostics.append(
                (relative, f"found {noncanonical} noncanonical {key} definition(s)")
            )

    bootstrap_version = version_matches[0] if len(version_matches) == 1 else None
    target_version = None
    if len(url_matches) == 1:
        logical_url = url_matches[0].replace("\\:", ":")
        target_match = OFFICIAL_DISTRIBUTION_URL.fullmatch(logical_url)
        if target_match is not None:
            target_version = target_match.group(1)
    return bootstrap_version, target_version, diagnostics


def _check_consumer_ignores(root: Path, has_windows_launcher: bool) -> list[Diagnostic]:
    path = root / ".gitignore"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return [(".gitignore", f"cannot read ignore rules: {exc}")]
    diagnostics: list[Diagnostic] = []
    expected_lines = IGNORE_LINES if has_windows_launcher else IGNORE_LINES[:1]
    for expected in expected_lines:
        count = lines.count(expected)
        if count != 1:
            diagnostics.append((".gitignore", f"expected one exact root-scoped rule {expected!r}, found {count}"))
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "gradle-wrapper.jar" in stripped and stripped != IGNORE_LINES[0]:
            diagnostics.append((".gitignore", f"noncanonical Wrapper JAR ignore rule: {line}"))
        if "gradlew-buildish-update-" in stripped and stripped != IGNORE_LINES[1]:
            diagnostics.append((".gitignore", f"noncanonical stable-launcher ignore rule: {line}"))
    return diagnostics


def check_consumer(root: Path, checker_root: Path) -> list[Diagnostic]:
    root = root.absolute()
    diagnostics: list[Diagnostic] = []
    manifest, manifest_diagnostics = check_manifest(checker_root)
    diagnostics.extend(manifest_diagnostics)
    if manifest is None:
        return diagnostics
    posix_path = root / "gradlew"
    windows_path = root / "gradlew.bat"
    has_posix_launcher = posix_path.exists() or posix_path.is_symlink()
    has_windows_launcher = windows_path.exists() or windows_path.is_symlink()
    if not has_posix_launcher and not has_windows_launcher:
        diagnostics.append((".", "consumer must contain at least one Gradle launcher"))
    diagnostics.extend(_check_regular(root, "gradle/buildish-wrapper.init.gradle.kts"))
    if has_posix_launcher:
        diagnostics.extend(_check_regular(root, "gradlew"))
        diagnostics.extend(_check_regular(root, "gradle/buildish-wrapper-bootstrap.sh"))
    if has_windows_launcher:
        diagnostics.extend(_check_regular(root, "gradlew.bat"))
        diagnostics.extend(_check_regular(root, "gradle/buildish-wrapper-bootstrap.ps1"))
    _, _, property_diagnostics = _check_consumer_properties(root)
    diagnostics.extend(property_diagnostics)
    diagnostics.extend(_check_consumer_ignores(root, has_windows_launcher))
    diagnostics.extend(
        _check_attribute_contract(
            root,
            _consumer_attribute_lines(has_posix_launcher, has_windows_launcher),
            _consumer_attribute_contract(has_posix_launcher, has_windows_launcher),
        )
    )

    checker, checker_diagnostics = _load_launcher_checker(checker_root)
    diagnostics.extend(checker_diagnostics)
    if checker is not None:
        manifest_path = checker_root / "tests/fixtures/compatibility-manifest.json"
        for launcher_path, reason in checker.check_consumer(manifest_path, root):
            diagnostics.append((_display(root, Path(launcher_path)), reason))

    if (root / ".git").exists():
        tracked, git_diagnostics = _git_paths(root)
        diagnostics.extend(git_diagnostics)
        if "gradle/wrapper/gradle-wrapper.jar" in tracked:
            diagnostics.append(("gradle/wrapper/gradle-wrapper.jar", "ignored Wrapper JAR must not be tracked"))
        for relative in tracked:
            if fnmatch.fnmatchcase(relative, ".gradlew-buildish-update-*.bat"):
                diagnostics.append((relative, "transient stable launcher must not be tracked"))
    return diagnostics


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--manifest", action="store_true", help="validate the canonical manifest and fixtures")
    modes.add_argument("--repository", type=Path, metavar="ROOT", help="validate a blueprint repository")
    modes.add_argument("--consumer", type=Path, metavar="ROOT", help="validate an adopting consumer")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    checker_root = Path(__file__).absolute().parent.parent
    if args.manifest:
        _, diagnostics = check_manifest(checker_root)
    elif args.repository is not None:
        diagnostics = check_repository(args.repository)
    else:
        diagnostics = check_consumer(args.consumer, checker_root)
    for path, reason in diagnostics:
        print(f"invariant-check: {path}: {reason}", file=sys.stderr)
    return 1 if diagnostics else 0


if __name__ == "__main__":
    raise SystemExit(main())
