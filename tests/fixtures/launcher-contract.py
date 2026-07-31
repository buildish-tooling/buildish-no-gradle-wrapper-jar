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

"""Materialize canonical Gradle launcher patch input/output fixtures."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path


CURRENT_UNIX_ANCHOR = (
    'APP_HOME=$( cd -P "${APP_HOME:-./}" > /dev/null && '
    'printf \'%s\\n\' "$PWD" ) || exit'
)
OLD_UNIX_ANCHOR = 'APP_HOME=$( cd "${APP_HOME:-./}" && pwd -P ) || exit'
UNIX_INSERTION = '. "${APP_HOME}/gradle/buildish-no-gradle-wrapper-jar.sh"'
BATCH_ANCHOR = 'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi'
BATCH_HELPER_BLOCK = (
    "set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=%*",
    "set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=",
    'for /f "delims=" %%a in (\'powershell -NoLogo -NoProfile '
    '-ExecutionPolicy Bypass -File "%APP_HOME%\\gradle\\buildish-no-gradle-wrapper-jar.ps1"\') '
    "do @set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=%%a",
    "set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=",
    "if errorlevel 1 goto fail",
)


@dataclass(frozen=True)
class LauncherCase:
    """One supported POSIX-anchor and Windows-execute-line combination."""

    name: str
    unix_anchor: str
    batch_execute_line: str
    patched_batch_execute_line: str


CASES = (
    LauncherCase(
        name="classpath-main",
        unix_anchor=OLD_UNIX_ANCHOR,
        batch_execute_line=(
            '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% '
            '"-Dorg.gradle.appname=%APP_BASE_NAME%" -classpath "%CLASSPATH%" '
            "org.gradle.wrapper.GradleWrapperMain %*"
        ),
        patched_batch_execute_line=(
            '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% '
            '"-Dorg.gradle.appname=%APP_BASE_NAME%" -classpath "%CLASSPATH%" '
            "org.gradle.wrapper.GradleWrapperMain %BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS% %*"
        ),
    ),
    LauncherCase(
        name="classpath-jar",
        unix_anchor=CURRENT_UNIX_ANCHOR,
        batch_execute_line=(
            '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% '
            '"-Dorg.gradle.appname=%APP_BASE_NAME%" -classpath "%CLASSPATH%" '
            '-jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" %*'
        ),
        patched_batch_execute_line=(
            '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% '
            '"-Dorg.gradle.appname=%APP_BASE_NAME%" -classpath "%CLASSPATH%" '
            '-jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" '
            "%BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS% %*"
        ),
    ),
    LauncherCase(
        name="direct-jar",
        unix_anchor=CURRENT_UNIX_ANCHOR,
        batch_execute_line=(
            '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% '
            '"-Dorg.gradle.appname=%APP_BASE_NAME%" '
            '-jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" %*'
        ),
        patched_batch_execute_line=(
            '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% '
            '"-Dorg.gradle.appname=%APP_BASE_NAME%" '
            '-jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" '
            "%BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS% %*"
        ),
    ),
    LauncherCase(
        name="endlocal-jar",
        unix_anchor=CURRENT_UNIX_ANCHOR,
        batch_execute_line=(
            'endlocal & "%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% '
            '"-Dorg.gradle.appname=%APP_BASE_NAME%" '
            '-jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" '
            "%* & call :exitWithErrorLevel"
        ),
        patched_batch_execute_line=(
            'endlocal & "%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% '
            '"-Dorg.gradle.appname=%APP_BASE_NAME%" '
            '-jar "%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar" '
            "%BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS% %* & call :exitWithErrorLevel"
        ),
    ),
)


def unix_content(anchor: str, *, patched: bool) -> bytes:
    """Return a minimal LF launcher around one exact supported anchor."""

    lines = ["#!/bin/sh", "echo before-unix-anchor", anchor]
    if patched:
        lines.append(UNIX_INSERTION)
    lines.extend(("echo after-unix-anchor", ""))
    return "\n".join(lines).encode()


def batch_content(case: LauncherCase, *, patched: bool) -> bytes:
    """Return a minimal CRLF launcher around one exact supported execute line."""

    lines = ["@echo off", "echo before-batch-anchor", BATCH_ANCHOR]
    if patched:
        lines.extend(BATCH_HELPER_BLOCK)
    lines.extend(
        (
            "echo after-batch-anchor",
            case.patched_batch_execute_line if patched else case.batch_execute_line,
            "exit /b %ERRORLEVEL%",
            "",
        )
    )
    return "\r\n".join(lines).encode()


def materialize(output_root: Path) -> None:
    """Write every canonical input and expected output below ``output_root``."""

    for case in CASES:
        for fixture_kind, patched in (("input", False), ("expected", True)):
            fixture_dir = output_root / case.name / fixture_kind
            fixture_dir.mkdir(parents=True, exist_ok=True)
            (fixture_dir / "gradlew").write_bytes(unix_content(case.unix_anchor, patched=patched))
            (fixture_dir / "gradlew.bat").write_bytes(batch_content(case, patched=patched))


def main() -> None:
    """List canonical cases or materialize them for the integration suite."""

    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true", help="print canonical case names")
    parser.add_argument("--output", type=Path, help="directory to receive materialized fixtures")
    arguments = parser.parse_args()
    if arguments.list == (arguments.output is not None):
        parser.error("choose exactly one of --list or --output")
    if arguments.list:
        print("\n".join(case.name for case in CASES))
    else:
        materialize(arguments.output)


if __name__ == "__main__":
    main()
