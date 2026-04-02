<#
 Copyright 2026 The Apache Software Foundation

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ToolDirectory = Split-Path -Parent $PSScriptRoot
$BuildDirectory = Join-Path -Path $ToolDirectory -ChildPath 'build\tests'

function Write-BuildishWindowsTestLog {
  param([string]$Message)

  Write-Host "windows-git-gpg-test: $Message"
}

function Assert-BuildishOutputContains {
  param(
    [string]$Output,
    [string]$ExpectedText,
    [string]$FailureMessage
  )

  if ($Output.IndexOf($ExpectedText, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw "$FailureMessage Output: $Output"
  }
}

function Get-BuildishGradleUserHome {
  param([string]$ProjectDirectory)

  return "$ProjectDirectory-gradle-user-home"
}

$testRoot = Join-Path -Path $BuildDirectory -ChildPath "windows-git-gpg-rejection.$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
$projectDirectory = Join-Path -Path $testRoot -ChildPath 'windows launcher git gpg rejection with spaces'
$wrapperJarPath = Join-Path -Path $projectDirectory -ChildPath 'gradle\wrapper\gradle-wrapper.jar'

try {
  New-Item -ItemType Directory -Path $BuildDirectory, $projectDirectory -Force | Out-Null
  Write-BuildishWindowsTestLog "starting Git-for-Windows GPG rejection test (test_root='$testRoot')"

  $gpgCommand = Get-Command gpg.exe -ErrorAction SilentlyContinue
  if ($null -eq $gpgCommand) {
    $gpgCommand = Get-Command gpg -ErrorAction SilentlyContinue
  }
  if ($null -eq $gpgCommand) {
    throw 'gpg.exe or gpg was not found on PATH.'
  }

  $gpgCommandPath = $gpgCommand.Source
  $normalizedGpgPath = $gpgCommandPath.Replace('/', '\').ToLowerInvariant()
  if ((-not $normalizedGpgPath.Contains('\git\usr\bin\')) -and (-not $normalizedGpgPath.Contains('\git\mingw64\bin\'))) {
    throw "This rejection test expects Git for Windows GPG to be selected, but got '$gpgCommandPath'."
  }

  $env:GRADLE_USER_HOME = Get-BuildishGradleUserHome -ProjectDirectory $projectDirectory
  try {
    & gradle -p $projectDirectory init --dsl groovy --type java-library --use-defaults --no-daemon
    if ($LASTEXITCODE -ne 0) {
      throw "gradle init failed with exit code $LASTEXITCODE."
    }

    $env:BUILDISH_NO_GRADLE_WRAPPER_JAR_SOURCE_DIR = $ToolDirectory
    try {
      & pwsh -NoLogo -NoProfile -File (Join-Path -Path $ToolDirectory -ChildPath 'install.ps1') $projectDirectory
      if ($LASTEXITCODE -ne 0) {
        throw "install.ps1 failed with exit code $LASTEXITCODE."
      }
    } finally {
      Remove-Item Env:BUILDISH_NO_GRADLE_WRAPPER_JAR_SOURCE_DIR -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $wrapperJarPath) {
      throw 'install.ps1 should remove the existing gradle-wrapper.jar before the rejection-path run.'
    }

    Push-Location -LiteralPath $projectDirectory
    try {
      $output = (& cmd.exe /d /c 'gradlew.bat --no-daemon help' 2>&1 | Out-String)
      $exitCode = $LASTEXITCODE
    } finally {
      Pop-Location
    }
  } finally {
    Remove-Item Env:GRADLE_USER_HOME -ErrorAction SilentlyContinue
  }

  if ($exitCode -eq 0) {
    throw 'gradlew.bat unexpectedly succeeded while Git for Windows GPG was selected.'
  }

  Assert-BuildishOutputContains -Output $output -ExpectedText "Unsupported Git for Windows GnuPG detected at '$gpgCommandPath'." -FailureMessage 'Rejection output did not identify the unsupported Git GPG path.'
  Assert-BuildishOutputContains -Output $output -ExpectedText 'Gpg4win' -FailureMessage 'Rejection output did not mention Gpg4win.'
  Assert-BuildishOutputContains -Output $output -ExpectedText 'choco install gnupg' -FailureMessage 'Rejection output did not mention the Chocolatey installation command.'
  Assert-BuildishOutputContains -Output $output -ExpectedText 'scoop install gpg' -FailureMessage 'Rejection output did not mention the Scoop installation command.'
  Write-BuildishWindowsTestLog 'Git for Windows GPG rejection path produced the expected message.'
} finally {
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}