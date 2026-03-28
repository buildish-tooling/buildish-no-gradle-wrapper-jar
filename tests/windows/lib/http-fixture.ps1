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
function Start-BuildishHttpFixture {
  param(
    [Parameter(Mandatory = $true)][string]$Payload,
    [Parameter(Mandatory = $true)][string]$CaseDirectory,
    [int]$StallSeconds = 20
  )

  $serverDirectory = Join-Path -Path $CaseDirectory -ChildPath (
    "http-$([System.Guid]::NewGuid().ToString('N'))"
  )
  New-Item -ItemType Directory -Path $serverDirectory -Force | Out-Null
  $logPath = Join-Path $serverDirectory 'requests.jsonl'
  $portPath = Join-Path $serverDirectory 'port'
  $serverScript = Join-Path $script:RepositoryRoot 'tests\fixtures\http-server.py'
  $arguments = '-u ' + (ConvertTo-BuildishCmdArgument -Value $serverScript) +
    ' --payload ' + (ConvertTo-BuildishCmdArgument -Value $Payload) +
    ' --log ' + (ConvertTo-BuildishCmdArgument -Value $logPath) +
    ' --port-file ' + (ConvertTo-BuildishCmdArgument -Value $portPath) +
    ' --stall-seconds ' + $StallSeconds
  $invocation = Start-BuildishNativeProcess `
    -FilePath $script:PythonPath `
    -ArgumentString $arguments `
    -WorkingDirectory $serverDirectory

  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $invocationCompleted = $false
  try {
    while ($stopwatch.ElapsedMilliseconds -lt 10000) {
      if (Test-Path -LiteralPath $portPath -PathType Leaf) {
        $port = [int]([System.IO.File]::ReadAllText($portPath).Trim())
        return [pscustomobject]@{
          Invocation = $invocation
          Port = $port
          LogPath = $logPath
          Directory = $serverDirectory
        }
      }
      if ($invocation.Process.HasExited) {
        $result = Complete-BuildishNativeProcess -Invocation $invocation -TimeoutSeconds 5
        $invocationCompleted = $true
        throw "Local HTTP fixture exited before publishing its port; stderr: " +
          $result.StandardErrorPath
      }
      Start-Sleep -Milliseconds 50
    }
    Stop-BuildishProcessTree -Process $invocation.Process
    [void](Complete-BuildishNativeProcess -Invocation $invocation -TimeoutSeconds 5)
    $invocationCompleted = $true
    throw 'Local HTTP fixture did not publish its port within 10 seconds.'
  } catch {
    if (-not $invocationCompleted) {
      if (-not $invocation.Process.HasExited) {
        Stop-BuildishProcessTree -Process $invocation.Process
      }
      [void](Complete-BuildishNativeProcess -Invocation $invocation -TimeoutSeconds 5)
      $invocationCompleted = $true
    }
    throw
  } finally {
    $stopwatch.Stop()
  }
}

function Stop-BuildishHttpFixture {
  param([Parameter(Mandatory = $true)]$Fixture)

  if (-not $Fixture.Invocation.Process.HasExited) {
    Stop-BuildishProcessTree -Process $Fixture.Invocation.Process
  }
  [void](Complete-BuildishNativeProcess -Invocation $Fixture.Invocation -TimeoutSeconds 5)
}

function Assert-BuildishHttpRequestCount {
  param(
    [Parameter(Mandatory = $true)]$Fixture,
    [Parameter(Mandatory = $true)][string]$Route,
    [Parameter(Mandatory = $true)][int]$ExpectedCount
  )

  $count = 0
  if (Test-Path -LiteralPath $Fixture.LogPath -PathType Leaf) {
    foreach ($line in [System.IO.File]::ReadAllLines($Fixture.LogPath)) {
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        $record = $line | ConvertFrom-Json
        if ([string]$record.route -ceq $Route) {
          $count += 1
        }
      }
    }
  }
  if ($count -ne $ExpectedCount) {
    throw "Expected $ExpectedCount request(s) for $Route, found $count in $($Fixture.LogPath)."
  }
}

function Assert-BuildishHttpRequestPathOnce {
  param(
    [Parameter(Mandatory = $true)]$Fixture,
    [Parameter(Mandatory = $true)][string]$ExpectedPath
  )

  $count = 0
  if (Test-Path -LiteralPath $Fixture.LogPath -PathType Leaf) {
    foreach ($line in [System.IO.File]::ReadAllLines($Fixture.LogPath)) {
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        $record = $line | ConvertFrom-Json
        if ([string]$record.path -ceq $ExpectedPath) {
          $count += 1
        }
      }
    }
  }
  if ($count -ne 1) {
    throw "Expected one request for $ExpectedPath, found $count in $($Fixture.LogPath)."
  }
}
