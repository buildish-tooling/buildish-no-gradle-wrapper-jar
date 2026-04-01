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
$TwoSegmentGradleVersion = if ([string]::IsNullOrWhiteSpace($env:TWO_SEGMENT_GRADLE_VERSION)) { '8.3' } else { $env:TWO_SEGMENT_GRADLE_VERSION }

function Write-BuildishWindowsTestLog {
  param([string]$Message)

  Write-Host "windows-integration-test: $Message"
}

function Invoke-BuildishExternal {
  param(
    [string]$Label,
    [scriptblock]$Command
  )

  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Label failed with exit code $LASTEXITCODE."
  }
}

function Get-BuildishGradleUserHome {
  param([string]$ProjectDirectory)

  return "$ProjectDirectory-gradle-user-home"
}

function Invoke-BuildishWithGradleUserHome {
  param(
    [string]$ProjectDirectory,
    [string]$Label,
    [scriptblock]$Command
  )

  $previousGradleUserHome = $env:GRADLE_USER_HOME
  $env:GRADLE_USER_HOME = Get-BuildishGradleUserHome -ProjectDirectory $ProjectDirectory
  try {
    Invoke-BuildishExternal -Label $Label -Command $Command
  } finally {
    if ($null -eq $previousGradleUserHome) {
      Remove-Item Env:GRADLE_USER_HOME -ErrorAction SilentlyContinue
    } else {
      $env:GRADLE_USER_HOME = $previousGradleUserHome
    }
  }
}

function Get-BuildishWrapperVersion {
  param([string]$ProjectDirectory)

  $propertiesPath = Join-Path -Path $ProjectDirectory -ChildPath 'gradle\wrapper\gradle-wrapper.properties'
  $distributionLine = (Select-String -Path $propertiesPath -Pattern '^distributionUrl=' | Select-Object -First 1).Line
  $distributionMatch = [regex]::Match($distributionLine, 'gradle-([0-9]+(?:\.[0-9]+){1,2})-(?:bin|all)\.zip$')
  if (-not $distributionMatch.Success) {
    throw "Unable to extract the Gradle version from '$propertiesPath'."
  }
  return $distributionMatch.Groups[1].Value
}

function Set-BuildishWrapperDistributionUrl {
  param(
    [string]$ProjectDirectory,
    [string]$GradleVersion
  )

  $propertiesPath = Join-Path -Path $ProjectDirectory -ChildPath 'gradle\wrapper\gradle-wrapper.properties'
  $updatedLines = foreach ($line in Get-Content -LiteralPath $propertiesPath) {
    if ($line.StartsWith('distributionUrl=')) {
      "distributionUrl=https\://services.gradle.org/distributions/gradle-$GradleVersion-bin.zip"
    } else {
      $line
    }
  }
  [System.IO.File]::WriteAllText($propertiesPath, (($updatedLines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Assert-BuildishMetadataForVersion {
  param(
    [string]$ProjectDirectory,
    [string]$GradleVersion
  )

  $wrapperDirectory = Join-Path -Path $ProjectDirectory -ChildPath 'gradle\wrapper'
  $jarPath = Join-Path -Path $wrapperDirectory -ChildPath 'gradle-wrapper.jar'
  $shaPath = Join-Path -Path $wrapperDirectory -ChildPath "gradle-wrapper-$GradleVersion.sha256"
  $ascPath = Join-Path -Path $wrapperDirectory -ChildPath "gradle-wrapper-$GradleVersion.asc"

  foreach ($path in @($jarPath, $shaPath, $ascPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Expected file was not found: '$path'."
    }
  }

  $expectedChecksum = (Get-Content -LiteralPath $shaPath -Raw).Trim().ToLowerInvariant()
  $actualChecksum = (Get-FileHash -LiteralPath $jarPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($expectedChecksum -ne $actualChecksum) {
    throw "Wrapper checksum mismatch for version '$GradleVersion'."
  }

  if ((Get-Content -LiteralPath $ascPath -TotalCount 1) -ne '-----BEGIN PGP SIGNATURE-----') {
    throw "Wrapper detached signature file for version '$GradleVersion' is malformed."
  }
}

$testRoot = Join-Path -Path $BuildDirectory -ChildPath "windows-integration.$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
$projectDirectory = Join-Path -Path $testRoot -ChildPath 'windows launcher smoke with spaces'
$wrapperDirectory = Join-Path -Path $projectDirectory -ChildPath 'gradle\wrapper'
$wrapperJarPath = Join-Path -Path $wrapperDirectory -ChildPath 'gradle-wrapper.jar'

try {
  New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null
  New-Item -ItemType Directory -Path $projectDirectory -Force | Out-Null
  Write-BuildishWindowsTestLog "starting Windows launcher integration suite (test_root='$testRoot')"

  Invoke-BuildishWithGradleUserHome -ProjectDirectory $projectDirectory -Label 'gradle init' -Command {
    & gradle -p $projectDirectory init --dsl groovy --type java-library --use-defaults --no-daemon
  }

  $env:BUILDISH_NO_GRADLE_WRAPPER_JAR_SOURCE_DIR = $ToolDirectory
  try {
    Write-BuildishWindowsTestLog "installing helper into '$projectDirectory'"
    Invoke-BuildishExternal -Label 'install.ps1' -Command {
      & pwsh -NoLogo -NoProfile -File (Join-Path -Path $ToolDirectory -ChildPath 'install.ps1') $projectDirectory
    }
  } finally {
    Remove-Item Env:BUILDISH_NO_GRADLE_WRAPPER_JAR_SOURCE_DIR -ErrorAction SilentlyContinue
  }

  if (Test-Path -LiteralPath $wrapperJarPath) {
    throw 'install.ps1 should remove the existing gradle-wrapper.jar.'
  }

  Write-BuildishWindowsTestLog "running POSIX launcher in '$projectDirectory'"
  Invoke-BuildishWithGradleUserHome -ProjectDirectory $projectDirectory -Label 'bash ./gradlew help' -Command {
    Push-Location $projectDirectory
    try { & bash ./gradlew --no-daemon help } finally { Pop-Location }
  }

  $installedVersion = Get-BuildishWrapperVersion -ProjectDirectory $projectDirectory
  Assert-BuildishMetadataForVersion -ProjectDirectory $projectDirectory -GradleVersion $installedVersion

  Write-BuildishWindowsTestLog "running batch launcher in '$projectDirectory' for Gradle '$TwoSegmentGradleVersion'"
  Set-BuildishWrapperDistributionUrl -ProjectDirectory $projectDirectory -GradleVersion $TwoSegmentGradleVersion
  Remove-Item -LiteralPath $wrapperJarPath, (Join-Path -Path $wrapperDirectory -ChildPath "gradle-wrapper-$TwoSegmentGradleVersion.sha256"), (Join-Path -Path $wrapperDirectory -ChildPath "gradle-wrapper-$TwoSegmentGradleVersion.asc") -Force -ErrorAction SilentlyContinue
  Invoke-BuildishWithGradleUserHome -ProjectDirectory $projectDirectory -Label 'cmd gradlew.bat help' -Command {
    Push-Location $projectDirectory
    try { & cmd.exe /d /c 'gradlew.bat --no-daemon help' } finally { Pop-Location }
  }
  Assert-BuildishMetadataForVersion -ProjectDirectory $projectDirectory -GradleVersion $TwoSegmentGradleVersion

  Write-BuildishWindowsTestLog "re-running batch launcher recovery path in '$projectDirectory'"
  [System.IO.File]::WriteAllText($wrapperJarPath, "corrupted-wrapper-jar`n", [System.Text.Encoding]::ASCII)
  Invoke-BuildishWithGradleUserHome -ProjectDirectory $projectDirectory -Label 'cmd gradlew.bat help after jar corruption' -Command {
    Push-Location $projectDirectory
    try { & cmd.exe /d /c 'gradlew.bat --no-daemon help' } finally { Pop-Location }
  }
  Assert-BuildishMetadataForVersion -ProjectDirectory $projectDirectory -GradleVersion $TwoSegmentGradleVersion

  Write-BuildishWindowsTestLog 'all Windows launcher integration checks passed.'
} finally {
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}