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

"""Validate supported raw Gradle launchers and patched consumer launchers."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
from typing import Any


POSIX_ANCHOR = (
    'APP_HOME=$( cd -P "${APP_HOME:-./}" > /dev/null && '
    'printf \'%s\\n\' "$PWD" ) || exit'
)
WINDOWS_ANCHOR = 'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi'
POSIX_BEGIN = '# BEGIN BUILDISH WRAPPER BOOTSTRAP'
POSIX_END = '# END BUILDISH WRAPPER BOOTSTRAP'
WINDOWS_BEGIN = '@rem BEGIN BUILDISH WRAPPER BOOTSTRAP'
WINDOWS_END = '@rem END BUILDISH WRAPPER BOOTSTRAP'
POSIX_SOURCE = '. "$APP_HOME/gradle/buildish-wrapper-bootstrap.sh" || exit $?'
WINDOWS_BLOCK = (
    'if exist "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" '
    'goto buildishWrapperReady',
    'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass '
    '-File "%APP_HOME%\\gradle\\buildish-wrapper-bootstrap.ps1"',
    'if errorlevel 1 exit /b %ERRORLEVEL%',
    ':buildishWrapperReady',
)
WINDOWS_INIT_ARGUMENT = (
    '--init-script "%APP_HOME%\\gradle\\buildish-wrapper.init.gradle.kts"'
)
STABLE_VERSION = re.compile(
    r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$"
)
WINDOWS_JAVA_TOKENS = (
    '"%JAVA_EXE%"',
    "%DEFAULT_JVM_OPTS%",
    "%JAVA_OPTS%",
    "%GRADLE_OPTS%",
    '-jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar"',
    "%*",
)
OLD_TOKENS = (
    "buildish-no-gradle-wrapper-jar.sh",
    "buildish-no-gradle-wrapper-jar.ps1",
    "buildish-no-gradle-wrapper-jar.init.gradle.kts",
    "BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS",
    "BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS",
    'for /f "delims="',
)
POSIX_INIT_PATTERN = re.compile(
    r"set[ \t]+--[ \t]+(?:\\\r?\n[ \t]*)?--init-script[ \t]+"
    r'(?:\\\r?\n[ \t]*)?"\$APP_HOME/gradle/buildish-wrapper\.init\.gradle\.kts"'
    r"[ \t]+(?:\\\r?\n[ \t]*)?\"\$@\""
)

Diagnostic = tuple[str, str]


def _load_manifest(path: Path) -> tuple[dict[str, Any] | None, list[Diagnostic]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return None, [(path.as_posix(), f"cannot read JSON manifest: {exc}")]
    if not isinstance(value, dict):
        return None, [(path.as_posix(), "manifest root must be an object")]
    return value, []


def _repository_root(manifest_path: Path) -> Path:
    # The canonical location is <root>/tests/fixtures/compatibility-manifest.json.
    return manifest_path.absolute().parent.parent.parent


def _safe_fixture(
    repository_root: Path, relative: object, pointer: str
) -> tuple[Path | None, list[Diagnostic]]:
    if not isinstance(relative, str):
        return None, [(pointer, "fixture path must be a string")]
    logical = PurePosixPath(relative)
    if logical.is_absolute() or not logical.parts or any(
        part in ("", ".", "..") for part in logical.parts
    ):
        return None, [(pointer, "fixture path must be a normalized repository-relative path")]
    if "\\" in relative:
        return None, [(pointer, "fixture path must use forward slashes")]

    root = repository_root.resolve()
    candidate = repository_root.joinpath(*logical.parts)
    try:
        resolved = candidate.resolve(strict=False)
        resolved.relative_to(root)
    except (OSError, ValueError):
        return None, [(pointer, "fixture path escapes the repository root")]

    current = repository_root
    for part in logical.parts:
        current = current / part
        try:
            if current.is_symlink():
                return None, [(pointer, f"fixture path traverses symbolic link: {current}")]
        except OSError as exc:
            return None, [(pointer, f"cannot inspect fixture path: {exc}")]
    return candidate, []


def _decode(path: Path) -> tuple[bytes | None, str | None, list[Diagnostic]]:
    try:
        data = path.read_bytes()
    except OSError as exc:
        return None, None, [(path.as_posix(), f"cannot read launcher: {exc}")]
    try:
        return data, data.decode("utf-8"), []
    except UnicodeDecodeError as exc:
        return data, None, [(path.as_posix(), f"launcher is not UTF-8: {exc}")]


def _check_newlines(path: Path, data: bytes, kind: str) -> list[Diagnostic]:
    diagnostics: list[Diagnostic] = []
    if kind == "posix":
        if b"\r" in data:
            diagnostics.append((path.as_posix(), "POSIX launcher must use LF only"))
        if not data.endswith(b"\n"):
            diagnostics.append((path.as_posix(), "POSIX launcher must end with LF"))
    else:
        remainder = data.replace(b"\r\n", b"")
        if b"\r" in remainder or b"\n" in remainder:
            diagnostics.append((path.as_posix(), "Windows launcher must use CRLF only"))
        if not data.endswith(b"\r\n"):
            diagnostics.append((path.as_posix(), "Windows launcher must end with CRLF"))
    return diagnostics


def _git_index_mode(root: Path, path: Path) -> str | None:
    try:
        relative = path.absolute().relative_to(root.absolute()).as_posix()
    except ValueError:
        return None
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--stage", "--", relative],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return None
    fields = result.stdout.split()
    return fields[0] if result.returncode == 0 and len(fields) >= 4 else None


def _check_fixture_mode(path: Path, kind: str, repository_root: Path) -> list[Diagnostic]:
    index_mode = _git_index_mode(repository_root, path)
    if index_mode is not None:
        expected_index_mode = "100755" if kind == "posix" else "100644"
        if index_mode != expected_index_mode:
            return [
                (
                    path.as_posix(),
                    f"Git mode must be {expected_index_mode}, found {index_mode}",
                )
            ]
        return []
    if os.name == "nt":
        return []
    try:
        actual = stat.S_IMODE(path.stat().st_mode)
    except OSError as exc:
        return [(path.as_posix(), f"cannot inspect launcher mode: {exc}")]
    if kind == "posix" and actual & 0o111 != 0o111:
        return [(path.as_posix(), f"POSIX launcher must be executable, found mode {actual:04o}")]
    if kind == "windows" and actual & 0o111:
        return [(path.as_posix(), f"Windows launcher must not be executable, found mode {actual:04o}")]
    return []


def _count_line(lines: list[str], expected: str) -> int:
    return sum(line == expected for line in lines)


def _is_windows_java_invocation(line: str) -> bool:
    previous = -1
    for token in WINDOWS_JAVA_TOKENS:
        index = line.find(token, previous + 1)
        if index < 0:
            return False
        previous = index
    return True


def check_fixtures(manifest_path: Path) -> list[Diagnostic]:
    manifest_path = manifest_path.absolute()
    manifest, diagnostics = _load_manifest(manifest_path)
    if manifest is None:
        return diagnostics
    repository_root = _repository_root(manifest_path)
    wrappers = manifest.get("wrapperVersions")
    if not isinstance(wrappers, list):
        return diagnostics + [("/wrapperVersions", "must be an array")]

    for index, wrapper in enumerate(wrappers):
        pointer = f"/wrapperVersions/{index}"
        if not isinstance(wrapper, dict):
            diagnostics.append((pointer, "must be an object"))
            continue
        version = wrapper.get("version")
        launchers = wrapper.get("launchers")
        if not isinstance(version, str) or not STABLE_VERSION.fullmatch(version):
            diagnostics.append((f"{pointer}/version", "must be a canonical stable version"))
            continue
        if not isinstance(launchers, dict):
            diagnostics.append((f"{pointer}/launchers", "must be an object"))
            continue
        for kind in ("posix", "windows"):
            entry_pointer = f"{pointer}/launchers/{kind}"
            entry = launchers.get(kind)
            if not isinstance(entry, dict):
                diagnostics.append((entry_pointer, "must be an object"))
                continue
            path, path_diagnostics = _safe_fixture(
                repository_root, entry.get("path"), f"{entry_pointer}/path"
            )
            diagnostics.extend(path_diagnostics)
            if path is None:
                continue
            if not path.is_file():
                diagnostics.append((path.as_posix(), "launcher fixture is not a regular file"))
                continue
            data, text, read_diagnostics = _decode(path)
            diagnostics.extend(read_diagnostics)
            if data is None or text is None:
                continue
            diagnostics.extend(_check_newlines(path, data, kind))
            diagnostics.extend(_check_fixture_mode(path, kind, repository_root))
            lines = text.splitlines()
            for marker in (POSIX_BEGIN, POSIX_END, WINDOWS_BEGIN, WINDOWS_END):
                if marker in lines:
                    diagnostics.append((path.as_posix(), f"raw launcher contains marker: {marker}"))
            if any(token in text for token in OLD_TOKENS):
                diagnostics.append((path.as_posix(), "raw launcher contains removed integration text"))
            if kind == "posix":
                count = _count_line(lines, POSIX_ANCHOR)
                if count != 1:
                    diagnostics.append(
                        (path.as_posix(), f"expected one POSIX insertion anchor, found {count}")
                    )
            else:
                anchor_count = _count_line(lines, WINDOWS_ANCHOR)
                if anchor_count != 1:
                    diagnostics.append(
                        (path.as_posix(), f"expected one Windows insertion anchor, found {anchor_count}")
                    )
                java_count = sum(_is_windows_java_invocation(line) for line in lines)
                if java_count != 1:
                    diagnostics.append(
                        (path.as_posix(), f"expected one structural Windows Java invocation, found {java_count}")
                    )
    return diagnostics


def _consumer_bootstrap_version(root: Path) -> tuple[str | None, list[Diagnostic]]:
    path = root / "gradle/wrapper/gradle-wrapper.properties"
    try:
        text = path.read_text(encoding="iso-8859-1")
    except OSError as exc:
        return None, [(path.as_posix(), f"cannot read Wrapper properties: {exc}")]
    pattern = re.compile(r"buildishWrapperJarVersion=([^\r\n]*)")
    matches = [
        match.group(1)
        for line in text.splitlines()
        if (match := pattern.fullmatch(line))
    ]
    if len(matches) != 1:
        return None, [(path.as_posix(), f"expected one canonical buildishWrapperJarVersion, found {len(matches)}")]
    return matches[0], []


def check_consumer(manifest_path: Path, consumer_root: Path) -> list[Diagnostic]:
    manifest_path = manifest_path.absolute()
    consumer_root = consumer_root.absolute()
    manifest, diagnostics = _load_manifest(manifest_path)
    if manifest is None:
        return diagnostics
    version, version_diagnostics = _consumer_bootstrap_version(consumer_root)
    diagnostics.extend(version_diagnostics)
    if version is not None and not STABLE_VERSION.fullmatch(version):
        diagnostics.append(
            ((consumer_root / "gradle/wrapper/gradle-wrapper.properties").as_posix(),
             f"noncanonical bootstrap version for launcher validation: {version}")
        )

    launcher_specs = (
        ("posix", consumer_root / "gradlew"),
        ("windows", consumer_root / "gradlew.bat"),
    )
    existing_launchers = [path for _, path in launcher_specs if path.exists() or path.is_symlink()]
    if not existing_launchers:
        diagnostics.append((consumer_root.as_posix(), "consumer must contain at least one Gradle launcher"))
    for kind, path in launcher_specs:
        if not path.exists() and not path.is_symlink():
            continue
        if not path.is_file():
            diagnostics.append((path.as_posix(), "consumer launcher is not a regular file"))
            continue
        data, text, read_diagnostics = _decode(path)
        diagnostics.extend(read_diagnostics)
        if data is None or text is None:
            continue
        diagnostics.extend(_check_newlines(path, data, kind))
        lines = text.splitlines()
        if kind == "posix":
            sequence = [POSIX_ANCHOR, "", POSIX_BEGIN, POSIX_SOURCE, POSIX_END]
            anchor_indexes = [i for i, line in enumerate(lines) if line == POSIX_ANCHOR]
            if len(anchor_indexes) != 1 or lines[anchor_indexes[0]:anchor_indexes[0] + 5] != sequence:
                diagnostics.append((path.as_posix(), "POSIX bootstrap block is not immediately after APP_HOME resolution"))
            for marker in (POSIX_BEGIN, POSIX_END, POSIX_SOURCE):
                count = _count_line(lines, marker)
                if count != 1:
                    diagnostics.append((path.as_posix(), f"expected one line {marker!r}, found {count}"))
            if os.name != "nt" and version is not None and STABLE_VERSION.fullmatch(version):
                try:
                    actual_mode = stat.S_IMODE(path.stat().st_mode)
                    if actual_mode & 0o111 == 0:
                        diagnostics.append(
                            (path.as_posix(), f"POSIX launcher must be executable, found mode {actual_mode:04o}")
                        )
                except OSError as exc:
                    diagnostics.append((path.as_posix(), f"cannot inspect launcher mode: {exc}"))
        else:
            sequence = [WINDOWS_ANCHOR, "", WINDOWS_BEGIN, *WINDOWS_BLOCK, WINDOWS_END]
            anchor_indexes = [i for i, line in enumerate(lines) if line == WINDOWS_ANCHOR]
            if len(anchor_indexes) != 1 or lines[anchor_indexes[0]:anchor_indexes[0] + len(sequence)] != sequence:
                diagnostics.append((path.as_posix(), "Windows bootstrap block is not immediately after APP_HOME resolution"))
            for marker in (WINDOWS_BEGIN, WINDOWS_END, *WINDOWS_BLOCK):
                count = _count_line(lines, marker)
                if count != 1:
                    diagnostics.append((path.as_posix(), f"expected one line {marker!r}, found {count}"))
            java_lines = [line for line in lines if _is_windows_java_invocation(line)]
            if len(java_lines) != 1:
                diagnostics.append((path.as_posix(), f"expected one Windows Java invocation, found {len(java_lines)}"))
            else:
                java_line = java_lines[0]
                if java_line.count(WINDOWS_INIT_ARGUMENT) != 1:
                    diagnostics.append((path.as_posix(), "Windows Java invocation must contain one static init-script argument"))
                elif java_line.index(WINDOWS_INIT_ARGUMENT) > java_line.index("%*"):
                    diagnostics.append((path.as_posix(), "Windows init-script argument must precede %*"))

        for token in OLD_TOKENS:
            if token in text:
                diagnostics.append((path.as_posix(), f"contains removed integration token: {token}"))

    if (consumer_root / "gradlew").exists():
        helper = consumer_root / "gradle/buildish-wrapper-bootstrap.sh"
        try:
            helper_text = helper.read_text(encoding="utf-8")
        except OSError as exc:
            diagnostics.append((helper.as_posix(), f"cannot read POSIX bootstrap helper: {exc}"))
        else:
            count = len(POSIX_INIT_PATTERN.findall(helper_text))
            if count != 1:
                diagnostics.append((helper.as_posix(), f"expected one two-argument init-script insertion, found {count}"))
            for token in OLD_TOKENS:
                if token in helper_text:
                    diagnostics.append((helper.as_posix(), f"contains removed integration token: {token}"))
    return diagnostics


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    fixtures = subparsers.add_parser("check-fixtures")
    fixtures.add_argument("--manifest", type=Path, required=True)
    consumer = subparsers.add_parser("check-consumer")
    consumer.add_argument("--manifest", type=Path, required=True)
    consumer.add_argument("consumer_root", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    if args.command == "check-fixtures":
        diagnostics = check_fixtures(args.manifest)
    else:
        diagnostics = check_consumer(args.manifest, args.consumer_root)
    for path, reason in diagnostics:
        print(f"launcher-contract: {path}: {reason}", file=sys.stderr)
    return 1 if diagnostics else 0


if __name__ == "__main__":
    raise SystemExit(main())
