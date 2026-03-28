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

function Write-BuildishWindowsLog {
  param([Parameter(Mandatory = $true)][string]$Message)

  Write-Host "windows-integration: $Message"
}

function Get-BuildishAbsolutePath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$BasePath
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path -Path $BasePath -ChildPath $Path))
}

function Stop-BuildishProcessTree {
  param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

  if ($Process.HasExited) {
    return
  }

  # Windows PowerShell 5.1 does not expose Process.Kill(Boolean). taskkill /T is
  # the native bounded process-tree operation available on every supported host.
  $killerStartInfo = New-Object System.Diagnostics.ProcessStartInfo
  $killerStartInfo.FileName = 'taskkill.exe'
  $killerStartInfo.Arguments = "/PID $($Process.Id) /T /F"
  $killerStartInfo.UseShellExecute = $false
  $killerStartInfo.CreateNoWindow = $true
  $killer = New-Object System.Diagnostics.Process
  $killer.StartInfo = $killerStartInfo

  try {
    [void]$killer.Start()
    if (-not $killer.WaitForExit(10000)) {
      $killer.Kill()
      [void]$killer.WaitForExit(5000)
    }
  } catch {
    if (-not $Process.HasExited) {
      $Process.Kill()
    }
  } finally {
    $killer.Dispose()
  }

  if (-not $Process.WaitForExit(5000)) {
    $Process.Kill()
    [void]$Process.WaitForExit(5000)
  }
}

function Start-BuildishNativeProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string]$ArgumentString = '',
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [hashtable]$Environment = @{}
  )

  $stdoutPath = Join-Path -Path $WorkingDirectory -ChildPath (
    "native-stdout-$([System.Guid]::NewGuid().ToString('N')).log"
  )
  $stderrPath = Join-Path -Path $WorkingDirectory -ChildPath (
    "native-stderr-$([System.Guid]::NewGuid().ToString('N')).log"
  )
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = $ArgumentString
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($name in $Environment.Keys) {
    $startInfo.EnvironmentVariables[$name] = [string]$Environment[$name]
  }

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    [void]$process.Start()
    return [pscustomobject]@{
      FilePath = $FilePath
      Process = $process
      StandardOutputTask = $process.StandardOutput.ReadToEndAsync()
      StandardErrorTask = $process.StandardError.ReadToEndAsync()
      StandardOutputPath = $stdoutPath
      StandardErrorPath = $stderrPath
      Stopwatch = $stopwatch
    }
  } catch {
    $stopwatch.Stop()
    $process.Dispose()
    throw
  }
}

function Complete-BuildishNativeProcess {
  param(
    [Parameter(Mandatory = $true)]$Invocation,
    [int]$TimeoutSeconds = $script:NativeProcessTimeoutSeconds
  )

  if ($TimeoutSeconds -le 0) {
    throw 'Native process timeout must be greater than zero.'
  }

  $process = $Invocation.Process
  try {
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
      Stop-BuildishProcessTree -Process $process
    } else {
      # WaitForExit() after the bounded wait drains asynchronous stream events.
      $process.WaitForExit()
    }

    $streamTasks = [System.Threading.Tasks.Task[]]@(
      $Invocation.StandardOutputTask,
      $Invocation.StandardErrorTask
    )
    if (-not [System.Threading.Tasks.Task]::WaitAll($streamTasks, 5000)) {
      throw "Native process output streams did not close after process-tree cleanup: " +
        $Invocation.FilePath
    }
    $stdout = $Invocation.StandardOutputTask.GetAwaiter().GetResult()
    $stderr = $Invocation.StandardErrorTask.GetAwaiter().GetResult()
    [System.IO.File]::WriteAllText(
      $Invocation.StandardOutputPath,
      $stdout,
      [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
      $Invocation.StandardErrorPath,
      $stderr,
      [System.Text.UTF8Encoding]::new($false)
    )

    $exitCode = if ($completed) { $process.ExitCode } else { 124 }
    return [pscustomobject]@{
      ExitCode = $exitCode
      TimedOut = -not $completed
      StandardOutput = $stdout
      StandardError = $stderr
      StandardOutputPath = $Invocation.StandardOutputPath
      StandardErrorPath = $Invocation.StandardErrorPath
      DurationMilliseconds = $Invocation.Stopwatch.ElapsedMilliseconds
    }
  } finally {
    $Invocation.Stopwatch.Stop()
    $process.Dispose()
  }
}

function Invoke-BuildishNativeProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string]$ArgumentString = '',
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [hashtable]$Environment = @{},
    [int]$TimeoutSeconds = $script:NativeProcessTimeoutSeconds
  )

  $invocation = Start-BuildishNativeProcess `
    -FilePath $FilePath `
    -ArgumentString $ArgumentString `
    -WorkingDirectory $WorkingDirectory `
    -Environment $Environment
  return Complete-BuildishNativeProcess `
    -Invocation $invocation `
    -TimeoutSeconds $TimeoutSeconds
}

function ConvertTo-BuildishCmdArgument {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

  if ($Value.IndexOf('"') -ge 0 -or $Value.IndexOf("`r") -ge 0 -or $Value.IndexOf("`n") -ge 0) {
    throw "Unsupported quote or newline in native-Windows test argument: '$Value'."
  }
  return '"' + $Value + '"'
}

function Invoke-BuildishStableBatchCopy {
  param(
    [Parameter(Mandatory = $true)][string]$ProjectDirectory,
    [string[]]$LauncherArguments = @(),
    [Parameter(Mandatory = $true)][string]$GradleUserHome,
    [int]$TimeoutSeconds = $script:NativeProcessTimeoutSeconds
  )

  # A same-directory GUID copy keeps APP_HOME stable while the canonical batch
  # launcher is replaced. The native result is returned without normalization.
  $sourceLauncher = Join-Path -Path $ProjectDirectory -ChildPath 'gradlew.bat'
  if (-not (Test-Path -LiteralPath $sourceLauncher -PathType Leaf)) {
    throw "Stable-copy source launcher is missing: $sourceLauncher"
  }

  $stableName = ".gradlew-buildish-update-$([System.Guid]::NewGuid().ToString('N')).bat"
  $stableLauncher = Join-Path -Path $ProjectDirectory -ChildPath $stableName
  try {
    Copy-Item -LiteralPath $sourceLauncher -Destination $stableLauncher -ErrorAction Stop
    $command = 'call ' + (ConvertTo-BuildishCmdArgument -Value $stableLauncher)
    foreach ($argument in $LauncherArguments) {
      $command += ' ' + (ConvertTo-BuildishCmdArgument -Value $argument)
    }
    return Invoke-BuildishNativeProcess `
      -FilePath 'cmd.exe' `
      -ArgumentString ('/d /c ' + $command) `
      -WorkingDirectory $ProjectDirectory `
      -Environment @{ GRADLE_USER_HOME = $GradleUserHome } `
      -TimeoutSeconds $TimeoutSeconds
  } finally {
    Remove-Item -LiteralPath $stableLauncher -Force -ErrorAction SilentlyContinue
  }
}

function Assert-BuildishExitCode {
  param(
    [Parameter(Mandatory = $true)]$Result,
    [Parameter(Mandatory = $true)][int]$ExpectedExitCode,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ($Result.TimedOut) {
    throw "$Label timed out; stderr: $($Result.StandardErrorPath)"
  }
  if ($Result.ExitCode -ne $ExpectedExitCode) {
    throw "$Label returned $($Result.ExitCode), expected $ExpectedExitCode; " +
      "stdout: $($Result.StandardOutputPath); stderr: $($Result.StandardErrorPath)"
  }
}

