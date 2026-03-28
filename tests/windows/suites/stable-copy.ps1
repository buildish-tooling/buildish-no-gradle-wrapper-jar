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

function Invoke-BuildishStableCopySuite {
  param([Parameter(Mandatory = $true)][int[]]$ExpectedExitCodes)

  Invoke-BuildishStableCopyControls -ExpectedExitCodes $ExpectedExitCodes
  Invoke-BuildishCase -Name 'stable-copy-real-cross-generation' -Body {
    param($caseDirectory)

    $consumer = New-BuildishConsumer `
      -Directory (Join-Path $caseDirectory 'cross generation consumer') `
      -BootstrapVersion '8.14.5' `
      -TargetVersion '8.14.5'
    Copy-Item `
      -LiteralPath (Get-BuildishWrapperPayload -Version '8.14.5') `
      -Destination (Join-Path $consumer 'gradle\wrapper\gradle-wrapper.jar')
    [void](Invoke-BuildishAdoption `
      -ConsumerDirectory $consumer `
      -ExecutingVersion '8.14.5' `
      -TargetVersion '8.14.5' `
      -CaseDirectory $caseDirectory `
      -UseExistingWrapper)

    $target = Get-BuildishManifestEntry -Collection 'targetDistributions' -Version '9.6.1'
    $userHome = $script:SharedGradleUserHome
    # The first pass still executes Wrapper JAR A and regenerates launcher A,
    # so the active batch control flow is unchanged and direct execution is the
    # documented supported path. Only the later B-to-B pass needs a stable copy.
    $firstPass = Invoke-BuildishGradleBatch `
      -GradleBatch (Join-Path $consumer 'gradlew.bat') `
      -ProjectDirectory $consumer `
      -Arguments @(
        '--daemon',
        '--rerun-tasks',
        ':wrapper',
        '--gradle-version',
        '9.6.1',
        '--distribution-type',
        'bin',
        '--gradle-distribution-sha256-sum',
        ([string]$target.sha256)
      ) `
      -GradleUserHome $userHome `
      -TimeoutSeconds 360
    Assert-BuildishExitCode `
      -Result $firstPass `
      -ExpectedExitCode 0 `
      -Label 'direct 8.14.5 to 9.6.1 first Wrapper pass'
    Assert-BuildishWrapperPair -ConsumerDirectory $consumer -Version '8.14.5'
    Assert-BuildishTargetDistribution -ConsumerDirectory $consumer -Version '9.6.1'
    Invoke-BuildishLauncherContract `
      -ConsumerDirectory $consumer `
      -CaseDirectory $caseDirectory

    $secondPass = Invoke-BuildishStableBatchCopy `
      -ProjectDirectory $consumer `
      -LauncherArguments @('--daemon', '--rerun-tasks', ':wrapper') `
      -GradleUserHome $userHome `
      -TimeoutSeconds 600
    Assert-BuildishExitCode `
      -Result $secondPass `
      -ExpectedExitCode 0 `
      -Label '9.6.1 second Wrapper pass through stable copy'
    Assert-BuildishWrapperPair -ConsumerDirectory $consumer -Version '9.6.1'
    Assert-BuildishTargetDistribution -ConsumerDirectory $consumer -Version '9.6.1'
    Invoke-BuildishLauncherContract `
      -ConsumerDirectory $consumer `
      -CaseDirectory $caseDirectory
    $remainingCopies = @(Get-ChildItem `
      -LiteralPath $consumer `
      -Filter '.gradlew-buildish-update-*.bat' `
      -File `
      -ErrorAction SilentlyContinue)
    if ($remainingCopies.Count -ne 0) {
      throw "Cross-generation update left $($remainingCopies.Count) stable launcher copies."
    }
  }
}
