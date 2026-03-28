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

function Invoke-BuildishRuntimeSuite {
  $runtimeGradleUserHome = $script:SharedGradleUserHome

  foreach ($version in @('8.14.5', '9.6.1')) {
    Invoke-BuildishCase -Name "runtime-cold-$version-path-with-spaces" -Body {
      param($caseDirectory)

      $payload = Get-BuildishWrapperPayload -Version $version
      $fixture = Start-BuildishHttpFixture -Payload $payload -CaseDirectory $caseDirectory
      try {
        $consumer = New-BuildishConsumer `
          -Directory (Join-Path $caseDirectory 'consumer with spaces') `
          -BootstrapVersion $version `
          -TargetVersion $version `
          -IncludeBootstrapPair
        Set-BuildishRuntimeRoute `
          -ConsumerDirectory $consumer `
          -Port $fixture.Port `
          -Route '/jar'
        $result = Invoke-BuildishPowerShellBootstrap -ConsumerDirectory $consumer
        Assert-BuildishExitCode `
          -Result $result `
          -ExpectedExitCode 0 `
          -Label "cold PowerShell bootstrap $version"
        if ($result.StandardOutput.Length -ne 0 -or $result.StandardError.Length -ne 0) {
          throw "Cold PowerShell bootstrap $version must emit neither stdout nor stderr."
        }
        $jar = Join-Path $consumer 'gradle\wrapper\gradle-wrapper.jar'
        $entry = Get-BuildishManifestEntry -Collection 'wrapperVersions' -Version $version
        if ((Get-BuildishSha256 -Path $jar) -cne [string]$entry.wrapperJarSha256) {
          throw "Cold PowerShell bootstrap $version published unexpected bytes."
        }
        Assert-BuildishNoWrapperTemporaries -ConsumerDirectory $consumer
      } finally {
        Stop-BuildishHttpFixture -Fixture $fixture
      }
    }
  }

  Invoke-BuildishCase -Name 'runtime-property-comments' -Body {
    param($caseDirectory)

    $payload = Get-BuildishWrapperPayload -Version '8.14.5'
    $fixture = Start-BuildishHttpFixture -Payload $payload -CaseDirectory $caseDirectory
    try {
      $consumer = New-BuildishConsumer `
        -Directory (Join-Path $caseDirectory 'commented-properties') `
        -BootstrapVersion '8.14.5' `
        -TargetVersion '8.14.5' `
        -IncludeBootstrapPair
      $properties = Join-Path $consumer 'gradle\wrapper\gradle-wrapper.properties'
      $text = [System.IO.File]::ReadAllText($properties)
      $text = "# buildishWrapperJarVersion is maintained by Buildish`r`n" +
        "! buildishWrapperJarSha256Sum is reviewed configuration`r`n" +
        "unrelatedProperty=buildishWrapperJarVersion`r`n" + $text
      [System.IO.File]::WriteAllText($properties, $text, [System.Text.Encoding]::ASCII)
      Set-BuildishRuntimeRoute `
        -ConsumerDirectory $consumer `
        -Port $fixture.Port `
        -Route '/jar'
      $result = Invoke-BuildishPowerShellBootstrap -ConsumerDirectory $consumer
      Assert-BuildishExitCode `
        -Result $result `
        -ExpectedExitCode 0 `
        -Label 'commented-property PowerShell bootstrap'
      if ($result.StandardOutput.Length -ne 0 -or $result.StandardError.Length -ne 0) {
        throw 'Commented-property PowerShell bootstrap emitted output.'
      }
      Assert-BuildishHttpRequestCount -Fixture $fixture -Route '/jar' -ExpectedCount 1
      Assert-BuildishNoWrapperTemporaries -ConsumerDirectory $consumer
    } finally {
      Stop-BuildishHttpFixture -Fixture $fixture
    }
  }

  Invoke-BuildishCase -Name 'runtime-failure-matrix' -Body {
    param($caseDirectory)

    $correctPayload = Get-BuildishWrapperPayload -Version '8.14.5'
    $badPayload = Join-Path $caseDirectory 'wrong-wrapper.jar'
    [System.IO.File]::WriteAllText(
      $badPayload,
      "not a Wrapper JAR`n",
      [System.Text.UTF8Encoding]::new($false)
    )
    $correctFixture = Start-BuildishHttpFixture `
      -Payload $correctPayload `
      -CaseDirectory $caseDirectory `
      -StallSeconds 20
    $badFixture = $null
    try {
      $badFixture = Start-BuildishHttpFixture `
        -Payload $badPayload `
        -CaseDirectory $caseDirectory
      $failureRoutes = @(
        [pscustomobject]@{
          Name = 'digest-mismatch'
          Fixture = $badFixture
          Route = '/jar'
          Diagnostic = 'SHA-256 mismatch'
        },
        [pscustomobject]@{
          Name = 'http-503'
          Fixture = $correctFixture
          Route = '/status/503'
          Diagnostic = '503'
        },
        [pscustomobject]@{
          Name = 'read-timeout'
          Fixture = $correctFixture
          Route = '/stall'
          Diagnostic = '(?i)timed out|timeout'
        },
        [pscustomobject]@{
          Name = 'oversize-content-length'
          Fixture = $correctFixture
          Route = '/oversize/accurate'
          Diagnostic = 'exceeds the 10 MiB limit'
        },
        [pscustomobject]@{
          Name = 'oversize-no-content-length'
          Fixture = $correctFixture
          Route = '/oversize/missing'
          Diagnostic = 'exceeds the 10 MiB limit'
        }
      )
      foreach ($failure in $failureRoutes) {
        $consumer = New-BuildishConsumer `
          -Directory (Join-Path $caseDirectory $failure.Name) `
          -BootstrapVersion '8.14.5' `
          -TargetVersion '8.14.5' `
          -IncludeBootstrapPair
        Set-BuildishRuntimeRoute `
          -ConsumerDirectory $consumer `
          -Port $failure.Fixture.Port `
          -Route $failure.Route
        $result = Invoke-BuildishPowerShellBootstrap `
          -ConsumerDirectory $consumer `
          -TimeoutSeconds 90
        Assert-BuildishExitCode `
          -Result $result `
          -ExpectedExitCode 1 `
          -Label "runtime $($failure.Name)"
        if ($result.StandardOutput.Length -ne 0) {
          throw "Runtime $($failure.Name) emitted stdout."
        }
        if ([string]::IsNullOrWhiteSpace($result.StandardError)) {
          throw "Runtime $($failure.Name) emitted no diagnostic on stderr."
        }
        if ($result.StandardError -notmatch '^buildish-wrapper-bootstrap:' -or
            $result.StandardError -notmatch $failure.Diagnostic) {
          throw "Runtime $($failure.Name) emitted the wrong diagnostic: $($result.StandardError)"
        }
        Assert-BuildishHttpRequestCount `
          -Fixture $failure.Fixture `
          -Route $failure.Route `
          -ExpectedCount 1
        Assert-BuildishFailedDownloadClean -ConsumerDirectory $consumer
      }
    } finally {
      if ($null -ne $badFixture) {
        Stop-BuildishHttpFixture -Fixture $badFixture
      }
      Stop-BuildishHttpFixture -Fixture $correctFixture
    }
  }

  Invoke-BuildishCase -Name 'runtime-property-validation-before-network' -Body {
    param($caseDirectory)

    $payload = Get-BuildishWrapperPayload -Version '8.14.5'
    $fixture = Start-BuildishHttpFixture -Payload $payload -CaseDirectory $caseDirectory
    try {
      foreach ($variant in @(
          'missing-digest',
          'duplicate-version',
          'noncanonical-digest',
          'backslash-version'
        )) {
        $consumer = New-BuildishConsumer `
          -Directory (Join-Path $caseDirectory $variant) `
          -BootstrapVersion '8.14.5' `
          -TargetVersion '8.14.5' `
          -IncludeBootstrapPair
        Set-BuildishRuntimeRoute -ConsumerDirectory $consumer -Port $fixture.Port -Route '/jar'
        $properties = Join-Path $consumer 'gradle\wrapper\gradle-wrapper.properties'
        $text = [System.IO.File]::ReadAllText($properties)
        if ($variant -ceq 'missing-digest') {
          $text = [regex]::Replace(
            $text,
            '(?m)^buildishWrapperJarSha256Sum=[0-9a-f]{64}\r?\n?',
            ''
          )
        } elseif ($variant -ceq 'duplicate-version') {
          $text += "buildishWrapperJarVersion : 8.14.5`r`n"
        } elseif ($variant -ceq 'noncanonical-digest') {
          $text = $text.Replace(
            'buildishWrapperJarSha256Sum=7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172',
            'buildishWrapperJarSha256Sum=7D3A4AC4DE1C32B59BC6A4EB8ECB8E612CCD0CF1AE1E99F66902DA64DF296172'
          )
        } else {
          $text = $text.Replace(
            'buildishWrapperJarVersion=8.14.5',
            'buildishWrapperJarVersion=8.14.5\other'
          )
        }
        [System.IO.File]::WriteAllText($properties, $text, [System.Text.Encoding]::ASCII)
        $result = Invoke-BuildishPowerShellBootstrap -ConsumerDirectory $consumer
        Assert-BuildishExitCode `
          -Result $result `
          -ExpectedExitCode 1 `
          -Label "runtime property validation $variant"
        if ($result.StandardOutput.Length -ne 0 -or
            [string]::IsNullOrWhiteSpace($result.StandardError) -or
            $result.StandardError -notmatch '^buildish-wrapper-bootstrap:') {
          throw "Runtime property validation $variant violated the stderr-only diagnostic contract."
        }
        Assert-BuildishFailedDownloadClean -ConsumerDirectory $consumer
      }
      Assert-BuildishHttpRequestCount -Fixture $fixture -Route '/jar' -ExpectedCount 0
    } finally {
      Stop-BuildishHttpFixture -Fixture $fixture
    }
  }

  Invoke-BuildishCase -Name 'runtime-valid-non-matrix-version' -Body {
    param($caseDirectory)

    $payload = Get-BuildishWrapperPayload -Version '8.14.5'
    $fixture = Start-BuildishHttpFixture -Payload $payload -CaseDirectory $caseDirectory
    try {
      $consumer = New-BuildishConsumer `
        -Directory (Join-Path $caseDirectory 'valid-non-matrix-version') `
        -BootstrapVersion '8.14.5' `
        -TargetVersion '8.14.5' `
        -IncludeBootstrapPair
      Set-BuildishRuntimeRoute -ConsumerDirectory $consumer -Port $fixture.Port -Route '/jar'
      $properties = Join-Path $consumer 'gradle\wrapper\gradle-wrapper.properties'
      $text = [System.IO.File]::ReadAllText($properties).Replace(
        'buildishWrapperJarVersion=8.14.5',
        'buildishWrapperJarVersion=7.8.9'
      )
      [System.IO.File]::WriteAllText($properties, $text, [System.Text.Encoding]::ASCII)

      $result = Invoke-BuildishPowerShellBootstrap -ConsumerDirectory $consumer
      Assert-BuildishExitCode `
        -Result $result `
        -ExpectedExitCode 0 `
        -Label 'runtime valid non-matrix version'
      if ($result.StandardOutput.Length -ne 0 -or $result.StandardError.Length -ne 0) {
        throw 'Valid non-matrix PowerShell bootstrap emitted output.'
      }
      Assert-BuildishHttpRequestCount -Fixture $fixture -Route '/jar' -ExpectedCount 1
      Assert-BuildishHttpRequestPathOnce `
        -Fixture $fixture `
        -ExpectedPath '/jar?source=v7.8.9/gradle/wrapper/gradle-wrapper.jar'
      $jar = Join-Path $consumer 'gradle\wrapper\gradle-wrapper.jar'
      $expected = Get-BuildishManifestEntry -Collection 'wrapperVersions' -Version '8.14.5'
      if ((Get-BuildishSha256 -Path $jar) -cne [string]$expected.wrapperJarSha256) {
        throw 'Valid non-matrix PowerShell bootstrap published unexpected bytes.'
      }
      Assert-BuildishNoWrapperTemporaries -ConsumerDirectory $consumer
    } finally {
      Stop-BuildishHttpFixture -Fixture $fixture
    }
  }

  Invoke-BuildishCase -Name 'runtime-concurrent-same-pin' -Body {
    param($caseDirectory)

    $payload = Get-BuildishWrapperPayload -Version '8.14.5'
    $fixture = Start-BuildishHttpFixture -Payload $payload -CaseDirectory $caseDirectory
    try {
      $consumer = New-BuildishConsumer `
        -Directory (Join-Path $caseDirectory 'concurrent consumer') `
        -BootstrapVersion '8.14.5' `
        -TargetVersion '8.14.5' `
        -IncludeBootstrapPair
      Set-BuildishRuntimeRoute `
        -ConsumerDirectory $consumer `
        -Port $fixture.Port `
        -Route '/jar/barrier'
      $helper = Join-Path $consumer 'gradle\buildish-wrapper-bootstrap.ps1'
      $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        (ConvertTo-BuildishCmdArgument -Value $helper)
      $first = $null
      $second = $null
      $firstNeedsCleanup = $false
      $secondNeedsCleanup = $false
      try {
        $first = Start-BuildishNativeProcess `
          -FilePath 'powershell.exe' `
          -ArgumentString $arguments `
          -WorkingDirectory $consumer
        $firstNeedsCleanup = $true
        $second = Start-BuildishNativeProcess `
          -FilePath 'powershell.exe' `
          -ArgumentString $arguments `
          -WorkingDirectory $consumer
        $secondNeedsCleanup = $true
        $firstNeedsCleanup = $false
        $firstResult = Complete-BuildishNativeProcess -Invocation $first -TimeoutSeconds 90
        $secondNeedsCleanup = $false
        $secondResult = Complete-BuildishNativeProcess -Invocation $second -TimeoutSeconds 90
      } finally {
        foreach ($pending in @(
            [pscustomobject]@{ Invocation = $first; NeedsCleanup = $firstNeedsCleanup },
            [pscustomobject]@{ Invocation = $second; NeedsCleanup = $secondNeedsCleanup }
          )) {
          if ($pending.NeedsCleanup) {
            if (-not $pending.Invocation.Process.HasExited) {
              Stop-BuildishProcessTree -Process $pending.Invocation.Process
            }
            [void](Complete-BuildishNativeProcess `
              -Invocation $pending.Invocation `
              -TimeoutSeconds 5)
          }
        }
      }
      Assert-BuildishExitCode -Result $firstResult -ExpectedExitCode 0 -Label 'first concurrent publisher'
      Assert-BuildishExitCode -Result $secondResult -ExpectedExitCode 0 -Label 'second concurrent publisher'
      if (($firstResult.StandardOutput + $secondResult.StandardOutput).Length -ne 0) {
        throw 'Concurrent same-pin publishers emitted stdout.'
      }
      if (($firstResult.StandardError + $secondResult.StandardError).Length -ne 0) {
        throw 'Concurrent same-pin publishers emitted stderr despite succeeding.'
      }
      $entry = Get-BuildishManifestEntry -Collection 'wrapperVersions' -Version '8.14.5'
      $jar = Join-Path $consumer 'gradle\wrapper\gradle-wrapper.jar'
      if ((Get-BuildishSha256 -Path $jar) -cne [string]$entry.wrapperJarSha256) {
        throw 'Concurrent same-pin publication produced unexpected final bytes.'
      }
      Assert-BuildishHttpRequestCount `
        -Fixture $fixture `
        -Route '/jar/barrier' `
        -ExpectedCount 2
      Assert-BuildishNoWrapperTemporaries -ConsumerDirectory $consumer
    } finally {
      Stop-BuildishHttpFixture -Fixture $fixture
    }
  }

  foreach ($transition in @($script:Manifest.transitions)) {
    $bootstrapVersion = [string]$transition.bootstrapVersion
    $targetVersion = [string]$transition.targetVersion
    if ($bootstrapVersion -ceq $targetVersion) {
      continue
    }
    Invoke-BuildishCase `
      -Name "runtime-canonical-cold-batch-$bootstrapVersion-target-$targetVersion" `
      -Body {
      param($caseDirectory)

      $consumer = New-BuildishConsumer `
        -Directory (Join-Path $caseDirectory 'canonical cold batch consumer') `
        -BootstrapVersion $bootstrapVersion `
        -TargetVersion $targetVersion
      Copy-Item `
        -LiteralPath (Get-BuildishWrapperPayload -Version $bootstrapVersion) `
        -Destination (Join-Path $consumer 'gradle\wrapper\gradle-wrapper.jar')
      [void](Invoke-BuildishAdoption `
        -ConsumerDirectory $consumer `
        -ExecutingVersion $bootstrapVersion `
        -TargetVersion $targetVersion `
        -CaseDirectory $caseDirectory)

      $payload = Get-BuildishWrapperPayload -Version $bootstrapVersion
      $fixture = Start-BuildishHttpFixture -Payload $payload -CaseDirectory $caseDirectory
      try {
        Remove-Item `
          -LiteralPath (Join-Path $consumer 'gradle\wrapper\gradle-wrapper.jar') `
          -Force
        Set-BuildishRuntimeRoute `
          -ConsumerDirectory $consumer `
          -Port $fixture.Port `
          -Route '/jar'
        $result = Invoke-BuildishGradleBatch `
          -GradleBatch (Join-Path $consumer 'gradlew.bat') `
          -ProjectDirectory $consumer `
          -Arguments @('--daemon', '--version') `
          -GradleUserHome $runtimeGradleUserHome `
          -TimeoutSeconds 600
        Assert-BuildishExitCode `
          -Result $result `
          -ExpectedExitCode 0 `
          -Label "canonical cold batch $bootstrapVersion to $targetVersion"
        $versionPattern = '(?m)^Gradle ' + [regex]::Escape($targetVersion) + '\r?$'
        if ($result.StandardOutput -notmatch $versionPattern) {
          throw "Canonical cold batch did not start Gradle $targetVersion."
        }
        Assert-BuildishHttpRequestCount -Fixture $fixture -Route '/jar' -ExpectedCount 1
        $entry = Get-BuildishManifestEntry `
          -Collection 'wrapperVersions' `
          -Version $bootstrapVersion
        $jar = Join-Path $consumer 'gradle\wrapper\gradle-wrapper.jar'
        if ((Get-BuildishSha256 -Path $jar) -cne [string]$entry.wrapperJarSha256) {
          throw 'Canonical cold batch published unexpected Wrapper JAR bytes.'
        }
        Assert-BuildishNoWrapperTemporaries -ConsumerDirectory $consumer
      } finally {
        Stop-BuildishHttpFixture -Fixture $fixture
      }
    }
  }

  Invoke-BuildishCase -Name 'runtime-warm-batch-skips-powershell' -Body {
    param($caseDirectory)

    $consumer = New-BuildishConsumer `
      -Directory (Join-Path $caseDirectory 'warm consumer with spaces') `
      -BootstrapVersion '8.14.5' `
      -TargetVersion '8.14.5'
    Copy-Item `
      -LiteralPath (Get-BuildishWrapperPayload -Version '8.14.5') `
      -Destination (Join-Path $consumer 'gradle\wrapper\gradle-wrapper.jar')
    [void](Invoke-BuildishAdoption `
      -ConsumerDirectory $consumer `
      -ExecutingVersion '8.14.5' `
      -TargetVersion '8.14.5' `
      -CaseDirectory $caseDirectory)

    $sentinel = Join-Path $caseDirectory 'powershell-was-started.txt'
    $sentinelHelper = Join-Path $consumer 'gradle\buildish-warm-sentinel.ps1'
    $instrumentedHelper = @(
      '$ErrorActionPreference = ''Stop''',
      "[System.IO.File]::WriteAllText('$($sentinel.Replace("'", "''"))', 'started')",
      'exit 97'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText(
      $sentinelHelper,
      $instrumentedHelper + "`r`n",
      [System.Text.Encoding]::ASCII
    )
    $launcherPath = Join-Path $consumer 'gradlew.bat'
    $launcherText = [System.IO.File]::ReadAllText($launcherPath)
    $canonicalCommandTarget = 'buildish-wrapper-bootstrap.ps1'
    if (([regex]::Matches(
          $launcherText,
          [regex]::Escape($canonicalCommandTarget)
        )).Count -ne 1) {
      throw 'Warm-path launcher instrumentation expected one PowerShell helper command.'
    }
    $launcherText = $launcherText.Replace(
      $canonicalCommandTarget,
      'buildish-warm-sentinel.ps1'
    )
    [System.IO.File]::WriteAllText(
      $launcherPath,
      $launcherText,
      [System.Text.UTF8Encoding]::new($false)
    )
    $userHome = $runtimeGradleUserHome
    $warm = Invoke-BuildishStableBatchCopy `
      -ProjectDirectory $consumer `
      -LauncherArguments @('--daemon', '--version') `
      -GradleUserHome $userHome `
      -TimeoutSeconds 360
    Assert-BuildishExitCode -Result $warm -ExpectedExitCode 0 -Label 'warm batch launcher'
    if (Test-Path -LiteralPath $sentinel) {
      throw 'Warm batch launcher started PowerShell despite an existing Wrapper JAR.'
    }

    Remove-Item -LiteralPath (Join-Path $consumer 'gradle\wrapper\gradle-wrapper.jar') -Force
    $cold = Invoke-BuildishStableBatchCopy `
      -ProjectDirectory $consumer `
      -LauncherArguments @('--daemon', '--version') `
      -GradleUserHome $userHome `
      -TimeoutSeconds 30
    Assert-BuildishExitCode -Result $cold -ExpectedExitCode 97 -Label 'instrumented cold batch launcher'
    if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) {
      throw 'Cold batch launcher did not invoke its PowerShell helper.'
    }
  }
}
