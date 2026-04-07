<#!
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

$BuildishUnsafeDevToolName = 'buildish-no-gradle-wrapper-jar unsafe-dev-install'
$BuildishUnsafeDevDefaultBaseUrl = 'https://raw.githubusercontent.com/apache/buildish/main/tools/buildish-no-gradle-wrapper-jar'
$BuildishUnsafeDevBaseUrl = if ([string]::IsNullOrWhiteSpace($env:BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL)) { $BuildishUnsafeDevDefaultBaseUrl } else { $env:BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL }

function Get-BuildishUnsafeDevCiMarker {
  foreach ($marker in @('CI', 'GITHUB_ACTIONS', 'GITLAB_CI', 'JENKINS_URL', 'JENKINS_HOME', 'BUILDKITE', 'TEAMCITY_VERSION', 'CIRCLECI', 'TRAVIS', 'TF_BUILD', 'BITBUCKET_BUILD_NUMBER', 'APPVEYOR', 'DRONE', 'SYSTEM_COLLECTIONURI')) {
    $value = [System.Environment]::GetEnvironmentVariable($marker)
    if ($marker -eq 'CI') {
      if ([string]::IsNullOrWhiteSpace($value)) {
        continue
      }
      if (@('0', 'false', 'no') -contains $value.Trim().ToLowerInvariant()) {
        continue
      }
      return $marker
    }
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $marker
    }
  }

  return ''
}

function Save-BuildishUnsafeDevDownloadedFile {
  param(
    [string]$Directory,
    [string]$FileName
  )

  $targetPath = Join-Path -Path $Directory -ChildPath $FileName
  try {
    Invoke-WebRequest -Uri "$BuildishUnsafeDevBaseUrl/$FileName" -OutFile $targetPath | Out-Null
  } catch {
    Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
    throw "Unable to download '$FileName' from '$BuildishUnsafeDevBaseUrl/$FileName'."
  }
}

$acknowledgedUnsafeMode = $false
$parsedPositionalArgs = [System.Collections.Generic.List[string]]::new()
$parsedArgIndex = 0
while ($parsedArgIndex -lt $args.Count) {
  $parsedArg = $args[$parsedArgIndex]
  if ($parsedArg -eq '--yes-i-know-this-is-unsafe') {
    $acknowledgedUnsafeMode = $true
    $parsedArgIndex++
  } elseif ($parsedArg -eq '--') {
    $parsedArgIndex++
    while ($parsedArgIndex -lt $args.Count) {
      [void]$parsedPositionalArgs.Add($args[$parsedArgIndex])
      $parsedArgIndex++
    }
    break
  } elseif ($parsedArg.StartsWith('-')) {
    Write-Error "${BuildishUnsafeDevToolName}: Unknown option '$parsedArg'."
    exit 1
  } else {
    [void]$parsedPositionalArgs.Add($parsedArg)
    $parsedArgIndex++
  }
}

if (-not $acknowledgedUnsafeMode) {
  Write-Error "${BuildishUnsafeDevToolName}: Refusing to run without --yes-i-know-this-is-unsafe. This script downloads and executes unverified content from the current development branch and is not suitable for CI, automation, or secret-bearing environments."
  exit 1
}

if ($parsedPositionalArgs.Count -gt 1) {
  Write-Error "${BuildishUnsafeDevToolName}: Expected zero or one positional argument: the target project directory."
  exit 1
}

$ciMarker = Get-BuildishUnsafeDevCiMarker
if (-not [string]::IsNullOrWhiteSpace($ciMarker)) {
  Write-Error "${BuildishUnsafeDevToolName}: Refusing to run because the CI marker '$ciMarker' is set. This script is not suitable for CI environments, automation, or secret-bearing environments."
  exit 1
}

Write-Warning "${BuildishUnsafeDevToolName}: This script downloads and executes unverified content from the current development branch."
Write-Warning "${BuildishUnsafeDevToolName}: Use it only when you intentionally trust the current branch contents."
Write-Warning "${BuildishUnsafeDevToolName}: It is not suitable for CI, automation, or environments with secrets."

$targetDirectory = if ($parsedPositionalArgs.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($parsedPositionalArgs[0])) { $parsedPositionalArgs[0] } else { (Get-Location).Path }
$temporaryDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "buildish-no-gradle-wrapper-jar-unsafe-dev-install.$([System.Guid]::NewGuid().ToString('N'))"

try {
  New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
  foreach ($fileName in @('install.ps1', 'buildish-no-gradle-wrapper-jar.sh', 'buildish-no-gradle-wrapper-jar.ps1', 'buildish-no-gradle-wrapper-jar.init.gradle.kts')) {
    Save-BuildishUnsafeDevDownloadedFile -Directory $temporaryDirectory -FileName $fileName
  }

  & (Join-Path -Path $temporaryDirectory -ChildPath 'install.ps1') --trusted-source-dir $temporaryDirectory $targetDirectory
  exit $LASTEXITCODE
} catch {
  Write-Error "${BuildishUnsafeDevToolName}: $($_.Exception.Message)"
  exit 1
} finally {
  Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}