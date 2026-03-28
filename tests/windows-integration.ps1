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

[CmdletBinding()]
param(
  [ValidateSet('All', 'Runtime', 'Lifecycle', 'StableCopy')]
  [string]$Suite = 'All',

  [string]$BuildDirectory = 'build\wt',

  [string]$Gradle8145Home,

  [string]$Gradle961Home
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:Failures = @()
$script:NativeProcessTimeoutSeconds = 120
$script:CaseCounter = 0

$windowsLibraryRoot = Join-Path $PSScriptRoot 'windows\lib'
. (Join-Path $windowsLibraryRoot 'native-process.ps1')
. (Join-Path $windowsLibraryRoot 'tool-fixtures.ps1')
. (Join-Path $windowsLibraryRoot 'http-fixture.ps1')
. (Join-Path $windowsLibraryRoot 'consumer-fixture.ps1')
. (Join-Path $windowsLibraryRoot 'assertions.ps1')
. (Join-Path $windowsLibraryRoot 'gradle-harness.ps1')

$windowsSuiteRoot = Join-Path $PSScriptRoot 'windows\suites'
. (Join-Path $windowsSuiteRoot 'runtime.ps1')
. (Join-Path $windowsSuiteRoot 'lifecycle.ps1')
. (Join-Path $windowsSuiteRoot 'stable-copy.ps1')

if ($env:OS -ne 'Windows_NT') {
  if ($Suite -eq 'All') {
    [Console]::Error.WriteLine(
      'windows-integration: -Suite All requires native Windows cmd.exe and Windows PowerShell.'
    )
  } else {
    [Console]::Error.WriteLine(
      "windows-integration: -Suite $Suite requires native Windows cmd.exe and Windows PowerShell."
    )
  }
  exit 2
}

$resolvedBuildDirectory = Get-BuildishAbsolutePath `
  -Path $BuildDirectory `
  -BasePath $script:RepositoryRoot
$normalizedRepositoryRoot = [System.IO.Path]::GetFullPath($script:RepositoryRoot).TrimEnd(
  [System.IO.Path]::DirectorySeparatorChar,
  [System.IO.Path]::AltDirectorySeparatorChar
)
$normalizedBuildDirectory = $resolvedBuildDirectory.TrimEnd(
  [System.IO.Path]::DirectorySeparatorChar,
  [System.IO.Path]::AltDirectorySeparatorChar
)
$repositoryPrefix = $normalizedRepositoryRoot + [System.IO.Path]::DirectorySeparatorChar
if ($normalizedBuildDirectory.Equals(
    $normalizedRepositoryRoot,
    [System.StringComparison]::OrdinalIgnoreCase
  ) -or -not $normalizedBuildDirectory.StartsWith(
    $repositoryPrefix,
    [System.StringComparison]::OrdinalIgnoreCase
  )) {
  throw "Windows test build directory must remain inside the repository: $resolvedBuildDirectory"
}
$script:ResolvedBuildDirectory = $resolvedBuildDirectory
$script:SharedGradleUserHome = Join-Path $resolvedBuildDirectory 'shared-gradle-user-home'
$script:GradleHomes = @{}
New-Item -ItemType Directory -Path $resolvedBuildDirectory -Force | Out-Null
$script:WorkRoot = $null
for ($attempt = 0; $attempt -lt 100; $attempt += 1) {
  $runId = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
  $candidate = Join-Path -Path $resolvedBuildDirectory -ChildPath "r-$runId"
  if (Test-Path -LiteralPath $candidate) {
    continue
  }
  try {
    New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
    $script:WorkRoot = $candidate
    break
  } catch {
    if (-not (Test-Path -LiteralPath $candidate)) {
      throw
    }
  }
}
if ($null -eq $script:WorkRoot) {
  throw "Could not allocate a unique Windows test run under $resolvedBuildDirectory."
}

try {
  $manifestPath = Join-Path -Path $script:RepositoryRoot -ChildPath (
    'tests\fixtures\compatibility-manifest.json'
  )
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Compatibility manifest is missing: $manifestPath"
  }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $script:ManifestPath = $manifestPath
  $script:Manifest = $manifest
  $script:PythonPath = Get-BuildishPythonPath
  $stableCopyExitCodes = @($manifest.nativeWindows.stableCopyExitCodes | ForEach-Object { [int]$_ })
  if (($stableCopyExitCodes -join ',') -ne '0,37,83') {
    throw 'Compatibility manifest must declare native-Windows stable-copy exits 0,37,83.'
  }

  if (-not [string]::IsNullOrWhiteSpace($Gradle8145Home)) {
    Invoke-BuildishCase -Name 'validate-gradle-8.14.5-home' -Body {
      param($caseDirectory)
      $script:GradleHomes['8.14.5'] = Assert-BuildishGradleHome `
        -GradleHome $Gradle8145Home `
        -ExpectedVersion '8.14.5' `
        -CaseDirectory $caseDirectory
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($Gradle961Home)) {
    Invoke-BuildishCase -Name 'validate-gradle-9.6.1-home' -Body {
      param($caseDirectory)
      $script:GradleHomes['9.6.1'] = Assert-BuildishGradleHome `
        -GradleHome $Gradle961Home `
        -ExpectedVersion '9.6.1' `
        -CaseDirectory $caseDirectory
    }
  }

  Write-BuildishWindowsLog "starting suite $Suite (work root: $($script:WorkRoot))"
  switch ($Suite) {
    'Runtime' { Invoke-BuildishSuite -Name 'Runtime' -Body { Invoke-BuildishRuntimeSuite } }
    'Lifecycle' { Invoke-BuildishSuite -Name 'Lifecycle' -Body { Invoke-BuildishLifecycleSuite } }
    'StableCopy' {
      Invoke-BuildishSuite -Name 'StableCopy' -Body {
        Invoke-BuildishStableCopySuite -ExpectedExitCodes $stableCopyExitCodes
      }
    }
    'All' {
      Invoke-BuildishSuite -Name 'Runtime' -Body { Invoke-BuildishRuntimeSuite }
      Invoke-BuildishSuite -Name 'Lifecycle' -Body { Invoke-BuildishLifecycleSuite }
      Invoke-BuildishSuite -Name 'StableCopy' -Body {
        Invoke-BuildishStableCopySuite -ExpectedExitCodes $stableCopyExitCodes
      }
    }
  }
} catch {
  $script:Failures += [pscustomobject]@{
    Name = 'suite-setup'
    Message = $_.Exception.Message
    CaseDirectory = $script:WorkRoot
  }
} finally {
  Stop-BuildishGradleDaemons
}

if ($script:Failures.Count -ne 0) {
  $summaryPath = Join-Path -Path $script:WorkRoot -ChildPath 'failure-summary.txt'
  $summary = @('windows-integration: failures')
  foreach ($failure in $script:Failures) {
    $summary += "- $($failure.Name): $($failure.Message) [$($failure.CaseDirectory)]"
  }
  [System.IO.File]::WriteAllLines(
    $summaryPath,
    $summary,
    [System.Text.UTF8Encoding]::new($false)
  )
  foreach ($line in $summary) {
    [Console]::Error.WriteLine($line)
  }
  [Console]::Error.WriteLine("windows-integration: retained failure root: $($script:WorkRoot)")
  exit 1
}

Remove-Item -LiteralPath $script:WorkRoot -Recurse -Force
Write-BuildishWindowsLog "suite $Suite passed"
exit 0
