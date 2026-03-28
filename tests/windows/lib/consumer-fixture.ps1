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
function New-BuildishConsumer {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$BootstrapVersion,
    [Parameter(Mandatory = $true)][string]$TargetVersion,
    [switch]$IncludeBootstrapPair
  )

  $wrapper = Get-BuildishManifestEntry -Collection 'wrapperVersions' -Version $BootstrapVersion
  $target = Get-BuildishManifestEntry -Collection 'targetDistributions' -Version $TargetVersion
  $wrapperDirectory = Join-Path -Path $Directory -ChildPath 'gradle\wrapper'
  New-Item -ItemType Directory -Path $wrapperDirectory -Force | Out-Null
  Copy-Item `
    -LiteralPath (Join-Path $script:RepositoryRoot ([string]$wrapper.launchers.posix.path)) `
    -Destination (Join-Path $Directory 'gradlew')
  Copy-Item `
    -LiteralPath (Join-Path $script:RepositoryRoot ([string]$wrapper.launchers.windows.path)) `
    -Destination (Join-Path $Directory 'gradlew.bat')
  Copy-Item `
    -LiteralPath (Assert-BuildishCanonicalSource -Name 'buildish-wrapper-bootstrap.sh') `
    -Destination (Join-Path $Directory 'gradle\buildish-wrapper-bootstrap.sh')
  Copy-Item `
    -LiteralPath (Assert-BuildishCanonicalSource -Name 'buildish-wrapper-bootstrap.ps1') `
    -Destination (Join-Path $Directory 'gradle\buildish-wrapper-bootstrap.ps1')
  Copy-Item `
    -LiteralPath (Assert-BuildishCanonicalSource -Name 'buildish-wrapper.init.gradle.kts') `
    -Destination (Join-Path $Directory 'gradle\buildish-wrapper.init.gradle.kts')

  [System.IO.File]::WriteAllText(
    (Join-Path $Directory 'settings.gradle.kts'),
    "rootProject.name = `"buildish-windows-test`"`r`n",
    [System.Text.UTF8Encoding]::new($false)
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $Directory 'build.gradle.kts'),
    '',
    [System.Text.UTF8Encoding]::new($false)
  )
  $escapedUrl = ([string]$target.url).Replace(':', '\:')
  $propertyLines = @(
    'distributionBase=GRADLE_USER_HOME',
    'distributionPath=wrapper/dists',
    "distributionUrl=$escapedUrl",
    "distributionSha256Sum=$($target.sha256)",
    'networkTimeout=10000',
    'validateDistributionUrl=true',
    'zipStoreBase=GRADLE_USER_HOME',
    'zipStorePath=wrapper/dists'
  )
  if ($IncludeBootstrapPair) {
    $propertyLines += "buildishWrapperJarVersion=$BootstrapVersion"
    $propertyLines += "buildishWrapperJarSha256Sum=$($wrapper.wrapperJarSha256)"
  }
  [System.IO.File]::WriteAllLines(
    (Join-Path $wrapperDirectory 'gradle-wrapper.properties'),
    $propertyLines,
    [System.Text.Encoding]::GetEncoding('iso-8859-1')
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $Directory '.gitignore'),
    "/gradle/wrapper/gradle-wrapper.jar`r`n/.gradlew-buildish-update-*.bat`r`n",
    [System.Text.UTF8Encoding]::new($false)
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $Directory '.gitattributes'),
    "/gradlew text eol=lf`n/gradlew.bat -text`n" +
      "/gradle/buildish-wrapper-bootstrap.sh text eol=lf`n" +
      "/gradle/buildish-wrapper-bootstrap.ps1 text eol=lf`n" +
      "/gradle/buildish-wrapper.init.gradle.kts text eol=lf`n",
    [System.Text.UTF8Encoding]::new($false)
  )
  return $Directory
}

function Set-BuildishRuntimeRoute {
  param(
    [Parameter(Mandatory = $true)][string]$ConsumerDirectory,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$Route
  )

  $path = Join-Path $ConsumerDirectory 'gradle\buildish-wrapper-bootstrap.ps1'
  $text = [System.IO.File]::ReadAllText($path)
  $token = 'https://raw.githubusercontent.com/gradle/gradle/'
  $count = ([regex]::Matches($text, [regex]::Escape($token))).Count
  if ($count -ne 1) {
    throw "Runtime URL substitution expected one token, found ${count}: $path"
  }
  $replacement = "http://127.0.0.1:$Port$Route`?source="
  [System.IO.File]::WriteAllText(
    $path,
    $text.Replace($token, $replacement),
    [System.Text.UTF8Encoding]::new($false)
  )
}

function Invoke-BuildishPowerShellBootstrap {
  param(
    [Parameter(Mandatory = $true)][string]$ConsumerDirectory,
    [int]$TimeoutSeconds = 90
  )

  $helper = Join-Path $ConsumerDirectory 'gradle\buildish-wrapper-bootstrap.ps1'
  $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    (ConvertTo-BuildishCmdArgument -Value $helper)
  return Invoke-BuildishNativeProcess `
    -FilePath 'powershell.exe' `
    -ArgumentString $arguments `
    -WorkingDirectory $ConsumerDirectory `
    -TimeoutSeconds $TimeoutSeconds
}
