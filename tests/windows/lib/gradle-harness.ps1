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

function Invoke-BuildishGradleBatch {
  param(
    [Parameter(Mandatory = $true)][string]$GradleBatch,
    [Parameter(Mandatory = $true)][string]$ProjectDirectory,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$GradleUserHome,
    [int]$TimeoutSeconds = 300
  )

  $command = 'call ' + (ConvertTo-BuildishCmdArgument -Value $GradleBatch)
  foreach ($argument in $Arguments) {
    $command += ' ' + (ConvertTo-BuildishCmdArgument -Value $argument)
  }
  return Invoke-BuildishNativeProcess `
    -FilePath 'cmd.exe' `
    -ArgumentString ('/d /c ' + $command) `
    -WorkingDirectory $ProjectDirectory `
    -Environment @{ GRADLE_USER_HOME = $GradleUserHome } `
    -TimeoutSeconds $TimeoutSeconds
}

function Stop-BuildishGradleDaemons {
  if ([string]::IsNullOrWhiteSpace($script:SharedGradleUserHome)) {
    return
  }
  $gradleBatches = @(
    $script:GradleHomes.Values |
      ForEach-Object { Join-Path $_ 'bin\gradle.bat' } |
      Sort-Object -Unique
  )
  foreach ($gradleBatch in $gradleBatches) {
    $result = Invoke-BuildishGradleBatch `
      -GradleBatch $gradleBatch `
      -ProjectDirectory $script:RepositoryRoot `
      -Arguments @('--stop') `
      -GradleUserHome $script:SharedGradleUserHome `
      -TimeoutSeconds 60
    if ($result.TimedOut -or $result.ExitCode -ne 0) {
      Write-BuildishWindowsLog "WARN could not stop Gradle daemons with $gradleBatch"
    }
  }
}

function Invoke-BuildishAdoption {
  param(
    [Parameter(Mandatory = $true)][string]$ConsumerDirectory,
    [Parameter(Mandatory = $true)][string]$ExecutingVersion,
    [Parameter(Mandatory = $true)][string]$TargetVersion,
    [Parameter(Mandatory = $true)][string]$CaseDirectory,
    [string]$GradleUserHome,
    [switch]$UseExistingWrapper
  )

  $target = Get-BuildishManifestEntry -Collection 'targetDistributions' -Version $TargetVersion
  $userHome = if ([string]::IsNullOrWhiteSpace($GradleUserHome)) {
    $script:SharedGradleUserHome
  } else {
    $GradleUserHome
  }
  $arguments = @(
    '--daemon',
    '--init-script',
    (Join-Path $ConsumerDirectory 'gradle\buildish-wrapper.init.gradle.kts'),
    '--rerun-tasks',
    ':wrapper',
    '--gradle-version',
    $TargetVersion,
    '--distribution-type',
    'bin',
    '--gradle-distribution-sha256-sum',
    ([string]$target.sha256)
  )
  if ($UseExistingWrapper) {
    $result = Invoke-BuildishStableBatchCopy `
      -ProjectDirectory $ConsumerDirectory `
      -LauncherArguments $arguments `
      -GradleUserHome $userHome `
      -TimeoutSeconds 360
  } else {
    $gradleHome = Get-BuildishGradleHome `
      -Version $ExecutingVersion `
      -CaseDirectory $CaseDirectory
    $result = Invoke-BuildishGradleBatch `
      -GradleBatch (Join-Path $gradleHome 'bin\gradle.bat') `
      -ProjectDirectory $ConsumerDirectory `
      -Arguments $arguments `
      -GradleUserHome $userHome `
      -TimeoutSeconds 300
  }
  Assert-BuildishExitCode `
    -Result $result `
    -ExpectedExitCode 0 `
    -Label "adoption $ExecutingVersion to $TargetVersion"
  Invoke-BuildishLauncherContract `
    -ConsumerDirectory $ConsumerDirectory `
    -CaseDirectory $CaseDirectory
  Assert-BuildishWrapperPair -ConsumerDirectory $ConsumerDirectory -Version $ExecutingVersion
  return $result
}

function Invoke-BuildishCase {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Body
  )

  $script:CaseCounter += 1
  $safeName = ($Name -replace '[^A-Za-z0-9_.-]', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safeName)) {
    $safeName = 'case'
  }
  if ($safeName.Length -gt 16) {
    $safeName = $safeName.Substring(0, 16).TrimEnd('-')
  }
  $caseId = '{0:D3}' -f $script:CaseCounter
  $caseDirectory = Join-Path -Path $script:WorkRoot -ChildPath "$caseId-$safeName"
  New-Item `
    -ItemType Directory `
    -Path $caseDirectory `
    -ErrorAction Stop | Out-Null
  $caseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    & $Body $caseDirectory
    $caseStopwatch.Stop()
    Write-BuildishWindowsLog "PASS $Name ($($caseStopwatch.ElapsedMilliseconds)ms)"
  } catch {
    $caseStopwatch.Stop()
    $script:Failures += [pscustomobject]@{
      Name = $Name
      Message = $_.Exception.Message
      CaseDirectory = $caseDirectory
    }
    Write-BuildishWindowsLog (
      "FAIL $Name after $($caseStopwatch.ElapsedMilliseconds)ms: $($_.Exception.Message)"
    )
  }
}

function Invoke-BuildishSuite {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Body
  )

  $suiteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  Write-BuildishWindowsLog "START suite $Name"
  & $Body
  $suiteStopwatch.Stop()
  Write-BuildishWindowsLog "TIMING suite $Name $($suiteStopwatch.ElapsedMilliseconds)ms"
}

function Invoke-BuildishStableCopyControls {
  param([Parameter(Mandatory = $true)][int[]]$ExpectedExitCodes)

  foreach ($expectedExitCode in $ExpectedExitCodes) {
    Invoke-BuildishCase -Name "stable-copy-exit-$expectedExitCode" -Body {
      param($caseDirectory)

      $projectDirectory = Join-Path -Path $caseDirectory -ChildPath 'project with spaces'
      New-Item -ItemType Directory -Path $projectDirectory -Force | Out-Null
      $launcher = Join-Path -Path $projectDirectory -ChildPath 'gradlew.bat'
      $batch = "@echo off`r`nexit /b $expectedExitCode`r`n"
      [System.IO.File]::WriteAllText($launcher, $batch, [System.Text.Encoding]::ASCII)
      $gradleUserHome = Join-Path -Path $caseDirectory -ChildPath 'gradle-user-home'

      $result = Invoke-BuildishStableBatchCopy `
        -ProjectDirectory $projectDirectory `
        -GradleUserHome $gradleUserHome `
        -TimeoutSeconds 30
      Assert-BuildishExitCode `
        -Result $result `
        -ExpectedExitCode $expectedExitCode `
        -Label "stable-copy control $expectedExitCode"

      $remainingCopies = @(Get-ChildItem `
        -LiteralPath $projectDirectory `
        -Filter '.gradlew-buildish-update-*.bat' `
        -File `
        -ErrorAction SilentlyContinue)
      if ($remainingCopies.Count -ne 0) {
        throw "Stable-copy control left $($remainingCopies.Count) temporary launcher(s)."
      }
    }
  }
}
