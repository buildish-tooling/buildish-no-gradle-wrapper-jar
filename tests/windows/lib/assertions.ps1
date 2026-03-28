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

Set-StrictMode -Version Latest
function Assert-BuildishNoWrapperTemporaries {
  param([Parameter(Mandatory = $true)][string]$ConsumerDirectory)

  $wrapperDirectory = Join-Path $ConsumerDirectory 'gradle\wrapper'
  $temporaries = @(Get-ChildItem `
    -LiteralPath $wrapperDirectory `
    -Filter 'gradle-wrapper.jar.tmp.*' `
    -File `
    -ErrorAction SilentlyContinue)
  if ($temporaries.Count -ne 0) {
    throw "Wrapper bootstrap left $($temporaries.Count) temporary file(s)."
  }
}

function Assert-BuildishFailedDownloadClean {
  param([Parameter(Mandatory = $true)][string]$ConsumerDirectory)

  $jar = Join-Path $ConsumerDirectory 'gradle\wrapper\gradle-wrapper.jar'
  if (Test-Path -LiteralPath $jar) {
    throw "Failed download published a final Wrapper JAR: $jar"
  }
  Assert-BuildishNoWrapperTemporaries -ConsumerDirectory $ConsumerDirectory
}

function Assert-BuildishWrapperPair {
  param(
    [Parameter(Mandatory = $true)][string]$ConsumerDirectory,
    [Parameter(Mandatory = $true)][string]$Version
  )

  $entry = Get-BuildishManifestEntry -Collection 'wrapperVersions' -Version $Version
  $path = Join-Path $ConsumerDirectory 'gradle\wrapper\gradle-wrapper.properties'
  $lines = [System.IO.File]::ReadAllLines($path)
  $versionLines = @($lines | Where-Object { $_ -match '^buildishWrapperJarVersion=' })
  $digestLines = @($lines | Where-Object { $_ -match '^buildishWrapperJarSha256Sum=' })
  if (($versionLines -join '') -cne "buildishWrapperJarVersion=$Version") {
    throw "Unexpected canonical bootstrap-version line in $path."
  }
  if (($digestLines -join '') -cne "buildishWrapperJarSha256Sum=$($entry.wrapperJarSha256)") {
    throw "Unexpected canonical bootstrap-digest line in $path."
  }
}

function Assert-BuildishTargetDistribution {
  param(
    [Parameter(Mandatory = $true)][string]$ConsumerDirectory,
    [Parameter(Mandatory = $true)][string]$Version
  )

  $entry = Get-BuildishManifestEntry -Collection 'targetDistributions' -Version $Version
  $path = Join-Path $ConsumerDirectory 'gradle\wrapper\gradle-wrapper.properties'
  $lines = [System.IO.File]::ReadAllLines($path)
  $urlLines = @($lines | Where-Object { $_ -match '^distributionUrl=' })
  $digestLines = @($lines | Where-Object { $_ -match '^distributionSha256Sum=' })
  $escapedUrl = ([string]$entry.url).Replace(':', '\:')
  if (($urlLines -join '') -cne "distributionUrl=$escapedUrl") {
    throw "Unexpected canonical target-distribution URL in $path."
  }
  if (($digestLines -join '') -cne "distributionSha256Sum=$($entry.sha256)") {
    throw "Unexpected canonical target-distribution digest in $path."
  }
}

function Assert-BuildishUnpatchedWrapperOutputs {
  param([Parameter(Mandatory = $true)][string]$ProjectDirectory)

  foreach ($relative in @('gradlew', 'gradlew.bat')) {
    $path = Join-Path $ProjectDirectory $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Unpatched Wrapper output is missing: $path"
    }
    $text = [System.IO.File]::ReadAllText($path)
    if ($text.Contains('BUILDISH WRAPPER BOOTSTRAP') -or
        $text.Contains('buildish-wrapper.init.gradle.kts')) {
      throw "Non-root Wrapper task received Buildish launcher mutations: $path"
    }
  }
  $properties = Join-Path $ProjectDirectory 'gradle\wrapper\gradle-wrapper.properties'
  if (-not (Test-Path -LiteralPath $properties -PathType Leaf)) {
    throw "Unpatched Wrapper properties are missing: $properties"
  }
  if ([System.IO.File]::ReadAllText($properties).Contains('buildishWrapperJar')) {
    throw "Non-root Wrapper task received Buildish metadata mutations: $properties"
  }
}

function Invoke-BuildishLauncherContract {
  param(
    [Parameter(Mandatory = $true)][string]$ConsumerDirectory,
    [Parameter(Mandatory = $true)][string]$CaseDirectory
  )

  $checker = Join-Path $script:RepositoryRoot 'tests\fixtures\launcher-contract.py'
  $arguments = (ConvertTo-BuildishCmdArgument -Value $checker) +
    ' check-consumer --manifest ' + (ConvertTo-BuildishCmdArgument -Value $script:ManifestPath) +
    ' ' + (ConvertTo-BuildishCmdArgument -Value $ConsumerDirectory)
  $result = Invoke-BuildishNativeProcess `
    -FilePath $script:PythonPath `
    -ArgumentString $arguments `
    -WorkingDirectory $CaseDirectory `
    -TimeoutSeconds 30
  Assert-BuildishExitCode -Result $result -ExpectedExitCode 0 -Label 'launcher contract'
}
