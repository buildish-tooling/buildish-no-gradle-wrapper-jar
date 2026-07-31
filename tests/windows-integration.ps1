<#
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
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ToolDirectory = Split-Path -Parent $PSScriptRoot
$BuildDirectory = Join-Path -Path $ToolDirectory -ChildPath 'build\tests'
$TwoSegmentGradleVersion = if ([string]::IsNullOrWhiteSpace($env:TWO_SEGMENT_GRADLE_VERSION)) { '8.14' } else { $env:TWO_SEGMENT_GRADLE_VERSION }

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

function Get-BuildishWrapperJarPin {
  param([string]$ProjectDirectory)

  $propertiesPath = Join-Path -Path $ProjectDirectory -ChildPath 'gradle\wrapper\gradle-wrapper.properties'
  $pinLine = (Select-String -Path $propertiesPath -CaseSensitive -Pattern '^buildishWrapperJarSha256Sum=' | Select-Object -First 1).Line
  if ([string]::IsNullOrWhiteSpace($pinLine)) {
    throw "Unable to read buildishWrapperJarSha256Sum from '$propertiesPath'."
  }
  return $pinLine.Substring('buildishWrapperJarSha256Sum='.Length)
}

function Set-BuildishWrapperJarPin {
  param(
    [string]$ProjectDirectory,
    [string]$Sha256
  )

  $propertiesPath = Join-Path -Path $ProjectDirectory -ChildPath 'gradle\wrapper\gradle-wrapper.properties'
  $found = $false
  $updatedLines = foreach ($line in Get-Content -LiteralPath $propertiesPath) {
    if ($line.StartsWith('buildishWrapperJarSha256Sum=')) {
      $found = $true
      "buildishWrapperJarSha256Sum=$Sha256"
    } else {
      $line
    }
  }
  if (-not $found) {
    $updatedLines += "buildishWrapperJarSha256Sum=$Sha256"
  }
  [System.IO.File]::WriteAllText($propertiesPath, (($updatedLines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Get-BuildishPublishedWrapperJarChecksum {
  param([string]$GradleVersion)

  $checksum = ([string](Invoke-RestMethod -Uri "https://services.gradle.org/distributions/gradle-$GradleVersion-wrapper.jar.sha256")).Trim().ToLowerInvariant()
  if ($checksum -cnotmatch '^[0-9a-f]{64}$') {
    throw "Gradle $GradleVersion returned a malformed Wrapper JAR checksum."
  }
  return $checksum
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
  Set-BuildishWrapperJarPin -ProjectDirectory $projectDirectory -Sha256 (Get-BuildishPublishedWrapperJarChecksum -GradleVersion (Get-BuildishWrapperVersion -ProjectDirectory $projectDirectory))

  Write-BuildishWindowsTestLog "installing helper into '$projectDirectory'"
  Invoke-BuildishExternal -Label 'install.ps1' -Command {
    & pwsh -NoLogo -NoProfile -File (Join-Path -Path $ToolDirectory -ChildPath 'install.ps1') --trusted-source-dir $ToolDirectory $projectDirectory
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

  $junctionProjectDirectory = Join-Path -Path $testRoot -ChildPath 'junction rejection project'
  $externalGradleDirectory = Join-Path -Path $testRoot -ChildPath 'junction external gradle'
  Copy-Item -LiteralPath $projectDirectory -Destination $junctionProjectDirectory -Recurse
  Move-Item -LiteralPath (Join-Path -Path $junctionProjectDirectory -ChildPath 'gradle') -Destination $externalGradleDirectory
  [void](New-Item -ItemType Junction -Path (Join-Path -Path $junctionProjectDirectory -ChildPath 'gradle') -Target $externalGradleDirectory)
  $externalWrapperJarPath = Join-Path -Path $externalGradleDirectory -ChildPath 'wrapper\gradle-wrapper.jar'
  $externalWrapperJarHash = (Get-FileHash -LiteralPath $externalWrapperJarPath -Algorithm SHA256).Hash

  Write-BuildishWindowsTestLog "rejecting junction-backed Gradle directory in '$junctionProjectDirectory'"
  $junctionOutput = & pwsh -NoLogo -NoProfile -File (Join-Path -Path $ToolDirectory -ChildPath 'install.ps1') --trusted-source-dir $ToolDirectory $junctionProjectDirectory 2>&1 | Out-String
  $junctionExitCode = $LASTEXITCODE
  if ($junctionExitCode -eq 0) {
    throw 'install.ps1 unexpectedly followed a junction-backed Gradle directory.'
  }
  if (-not $junctionOutput.Contains('Gradle directory must not be a symbolic link')) {
    throw "install.ps1 junction rejection did not identify the managed reparse point. Output: $junctionOutput"
  }
  if ((Get-FileHash -LiteralPath $externalWrapperJarPath -Algorithm SHA256).Hash -ne $externalWrapperJarHash) {
    throw 'install.ps1 changed the external wrapper JAR through a junction-backed Gradle directory.'
  }

  Write-BuildishWindowsTestLog "updating batch launcher in '$projectDirectory' to Gradle '$TwoSegmentGradleVersion'"
  $previousWrapperJarPin = Get-BuildishWrapperJarPin -ProjectDirectory $projectDirectory
  Invoke-BuildishWithGradleUserHome -ProjectDirectory $projectDirectory -Label 'cmd gradlew.bat wrapper upgrade' -Command {
    Push-Location $projectDirectory
    try { & cmd.exe /d /c "gradlew.bat --no-daemon wrapper --gradle-version $TwoSegmentGradleVersion --distribution-type bin" } finally { Pop-Location }
  }
  if ((Get-BuildishWrapperJarPin -ProjectDirectory $projectDirectory) -ne $previousWrapperJarPin) {
    throw 'Gradle init script did not preserve buildishWrapperJarSha256Sum during wrapper property regeneration.'
  }
  Set-BuildishWrapperJarPin -ProjectDirectory $projectDirectory -Sha256 (Get-BuildishPublishedWrapperJarChecksum -GradleVersion $TwoSegmentGradleVersion)
  Remove-Item -LiteralPath $wrapperJarPath, (Join-Path -Path $wrapperDirectory -ChildPath "gradle-wrapper-$TwoSegmentGradleVersion.sha256"), (Join-Path -Path $wrapperDirectory -ChildPath "gradle-wrapper-$TwoSegmentGradleVersion.asc") -Force -ErrorAction SilentlyContinue
  # This fresh download runs the helper through gradlew.bat's Windows PowerShell
  # 5.1 process. GPG creates a new temporary keybox and writes that successful
  # initialization diagnostic to stderr, which must not abort signature checks.
  Invoke-BuildishWithGradleUserHome -ProjectDirectory $projectDirectory -Label 'cmd gradlew.bat second wrapper upgrade pass' -Command {
    Push-Location $projectDirectory
    try { & cmd.exe /d /c "gradlew.bat --no-daemon wrapper --gradle-version $TwoSegmentGradleVersion --distribution-type bin" } finally { Pop-Location }
  }
  Assert-BuildishMetadataForVersion -ProjectDirectory $projectDirectory -GradleVersion $TwoSegmentGradleVersion

  Write-BuildishWindowsTestLog "re-running batch launcher recovery path in '$projectDirectory'"
  [System.IO.File]::WriteAllText($wrapperJarPath, "corrupted-wrapper-jar`n", [System.Text.Encoding]::ASCII)
  Invoke-BuildishWithGradleUserHome -ProjectDirectory $projectDirectory -Label 'cmd gradlew.bat help after jar corruption' -Command {
    Push-Location $projectDirectory
    try { & cmd.exe /d /c 'gradlew.bat --no-daemon help' } finally { Pop-Location }
  }
  Assert-BuildishMetadataForVersion -ProjectDirectory $projectDirectory -GradleVersion $TwoSegmentGradleVersion

  $noInitScriptProjectDirectory = Join-Path -Path $testRoot -ChildPath 'recovery without init script'
  Copy-Item -LiteralPath $projectDirectory -Destination $noInitScriptProjectDirectory -Recurse
  $noInitScriptJarPath = Join-Path -Path $noInitScriptProjectDirectory -ChildPath 'gradle\wrapper\gradle-wrapper.jar'
  Remove-Item -LiteralPath (Join-Path -Path $noInitScriptProjectDirectory -ChildPath 'gradle\buildish-no-gradle-wrapper-jar.init.gradle.kts') -Force
  $oversizedJarStream = [System.IO.File]::Open($noInitScriptJarPath, [System.IO.FileMode]::Create)
  try { $oversizedJarStream.SetLength(10485761) } finally { $oversizedJarStream.Dispose() }

  Write-BuildishWindowsTestLog "recovering through gradlew.bat without an init script in '$noInitScriptProjectDirectory'"
  Invoke-BuildishWithGradleUserHome -ProjectDirectory $noInitScriptProjectDirectory -Label 'cmd gradlew.bat recovery without init script' -Command {
    Push-Location $noInitScriptProjectDirectory
    try { & cmd.exe /d /c 'gradlew.bat --no-daemon help' } finally { Pop-Location }
  }
  Assert-BuildishMetadataForVersion -ProjectDirectory $noInitScriptProjectDirectory -GradleVersion $TwoSegmentGradleVersion

  $metacharProjectDirectory = Join-Path -Path $testRoot -ChildPath 'windows&launcher^(meta)%pct!bang'
  Copy-Item -LiteralPath $projectDirectory -Destination $metacharProjectDirectory -Recurse

  Write-BuildishWindowsTestLog "running batch launcher from metacharacter path '$metacharProjectDirectory'"
  Invoke-BuildishWithGradleUserHome -ProjectDirectory $metacharProjectDirectory -Label 'cmd gradlew.bat help from metacharacter path' -Command {
    Push-Location $metacharProjectDirectory
    try { & cmd.exe /d /c 'gradlew.bat --no-daemon help' } finally { Pop-Location }
  }
  Assert-BuildishMetadataForVersion -ProjectDirectory $metacharProjectDirectory -GradleVersion $TwoSegmentGradleVersion

  Write-BuildishWindowsTestLog 'all Windows launcher integration checks passed.'
} finally {
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
