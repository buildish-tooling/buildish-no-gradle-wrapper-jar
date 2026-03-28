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

# Runtime contract:
# - gradlew.bat calls this helper only after its warm-path JAR check fails;
# - the helper reads one canonical committed version/digest pair;
# - the version selects one fixed upstream raw-tag URL;
# - the untrusted response is bounded and written to a unique sibling file; and
# - only bytes matching the committed digest may reach gradle-wrapper.jar.
# Direct invocation is supported for diagnostics, but accepts no arguments.

$MaximumResponseBytes = 10 * 1024 * 1024
$ConnectTimeoutMilliseconds = 10000
$ReadTimeoutMilliseconds = 10000
$OverallTimeoutMilliseconds = 60000
$RawSourcePrefix = 'https://raw.githubusercontent.com/gradle/gradle/'

function Get-BuildishWrapperProperty {
  param(
    [Parameter(Mandatory = $true)][string[]]$Lines,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$ValuePattern,
    [Parameter(Mandatory = $true)][string]$ExpectedForm
  )

  # Reject every Java-properties alias for this key. Both platform helpers must
  # consume exactly the same single physical Name=value definition.
  $escapedName = [regex]::Escape($Name)
  $definitionPattern = '^\s*' + $escapedName + '(?=\s|=|:|\\|$)'
  $definitions = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in $Lines) {
    if ([regex]::IsMatch($line, $definitionPattern)) {
      [void]$definitions.Add($line)
    }
  }
  if ($definitions.Count -ne 1) {
    throw "Property '$Name' must occur exactly once as $ExpectedForm."
  }

  $match = [regex]::Match($definitions[0], '^' + $escapedName + '=(' + $ValuePattern + ')$')
  if (-not $match.Success) {
    throw "Property '$Name' must use the canonical form $ExpectedForm."
  }
  return $match.Groups[1].Value
}

function Get-BuildishSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)

  $stream = $null
  $sha256 = $null
  try {
    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha256.ComputeHash($stream)
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
  } finally {
    if ($null -ne $sha256) {
      $sha256.Dispose()
    }
    if ($null -ne $stream) {
      $stream.Dispose()
    }
  }
}

function Invoke-BuildishWrapperBootstrap {
  $wrapperDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'wrapper'
  $propertiesPath = Join-Path -Path $wrapperDirectory -ChildPath 'gradle-wrapper.properties'
  $jarPath = Join-Path -Path $wrapperDirectory -ChildPath 'gradle-wrapper.jar'
  if (-not [System.IO.File]::Exists($propertiesPath)) {
    throw "Wrapper properties file is missing: $propertiesPath"
  }

  # Snapshot and validate trusted configuration before constructing a URL or
  # opening a network request.
  $lines = [System.IO.File]::ReadAllLines($propertiesPath)
  $version = Get-BuildishWrapperProperty `
    -Lines $lines `
    -Name 'buildishWrapperJarVersion' `
    -ValuePattern '(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)' `
    -ExpectedForm 'buildishWrapperJarVersion=<canonical three-component stable version>'
  $expectedSha256 = Get-BuildishWrapperProperty `
    -Lines $lines `
    -Name 'buildishWrapperJarSha256Sum' `
    -ValuePattern '[0-9a-f]{64}' `
    -ExpectedForm 'buildishWrapperJarSha256Sum=<64 lowercase hexadecimal characters>'

  $downloadUrl = $RawSourcePrefix + 'v' + $version + '/gradle/wrapper/gradle-wrapper.jar'

  # The batch launcher owns the ordinary warm path. This branch handles only a
  # same-pin publisher that won the race after the batch existence check.
  if ([System.IO.File]::Exists($jarPath)) {
    $raceSha256 = Get-BuildishSha256 -Path $jarPath
    if ($raceSha256 -cne $expectedSha256) {
      throw "Concurrent Wrapper JAR does not match the snapshotted SHA-256: expected=$expectedSha256 actual=$raceSha256"
    }
    return
  }

  # The temporary is a sibling of the final JAR so a successful Move publishes
  # the verified bytes without a cross-volume copy window.
  $temporaryPath = $jarPath + '.tmp.' + [System.Guid]::NewGuid().ToString('N')
  $request = $null
  $response = $null
  $responseStream = $null
  $outputStream = $null
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $outputStream = New-Object System.IO.FileStream(
      $temporaryPath,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )
    # Keep acquisition on the exact derived URL instead of widening it to a
    # redirect target. Connect and read timeouts bound individual blocking
    # operations; the stopwatch below bounds the complete response transfer.
    $request = [System.Net.HttpWebRequest]::Create($downloadUrl)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $false
    $request.Timeout = $ConnectTimeoutMilliseconds
    $request.ReadWriteTimeout = $ReadTimeoutMilliseconds
    $response = $request.GetResponse()
    if ($response.ContentLength -gt $MaximumResponseBytes) {
      throw "Wrapper JAR response exceeds the 10 MiB limit: $($response.ContentLength) bytes"
    }

    $responseStream = $response.GetResponseStream()
    $buffer = New-Object byte[] 81920
    [long]$totalBytes = 0
    while ($true) {
      $remainingMilliseconds = $OverallTimeoutMilliseconds - $stopwatch.ElapsedMilliseconds
      if ($remainingMilliseconds -le 0) {
        throw 'Wrapper JAR download exceeded the overall timeout.'
      }
      if ($responseStream.CanTimeout) {
        $responseStream.ReadTimeout = [Math]::Max(
          1,
          [Math]::Min($ReadTimeoutMilliseconds, [int]$remainingMilliseconds)
        )
      }
      $read = $responseStream.Read($buffer, 0, $buffer.Length)
      if ($read -eq 0) {
        break
      }
      if ($totalBytes -gt ($MaximumResponseBytes - $read)) {
        throw 'Wrapper JAR response exceeds the 10 MiB limit.'
      }
      $outputStream.Write($buffer, 0, $read)
      $totalBytes += $read
    }
    $outputStream.Flush($true)
    $outputStream.Dispose()
    $outputStream = $null
    $responseStream.Dispose()
    $responseStream = $null
    $response.Dispose()
    $response = $null

    # Verification is the only transition from untrusted response bytes to a
    # candidate that may be published at the executable Wrapper path.
    $actualSha256 = Get-BuildishSha256 -Path $temporaryPath
    if ($actualSha256 -cne $expectedSha256) {
      throw "Wrapper JAR SHA-256 mismatch: expected=$expectedSha256 actual=$actualSha256"
    }

    try {
      [System.IO.File]::Move($temporaryPath, $jarPath)
      $temporaryPath = $null
    } catch [System.IO.IOException] {
      if (-not [System.IO.File]::Exists($jarPath)) {
        throw
      }
      $raceSha256 = Get-BuildishSha256 -Path $jarPath
      if ($raceSha256 -cne $expectedSha256) {
        throw "Concurrent Wrapper JAR does not match the snapshotted SHA-256: expected=$expectedSha256 actual=$raceSha256"
      }
      [System.IO.File]::Delete($temporaryPath)
      $temporaryPath = $null
    }
  } finally {
    $stopwatch.Stop()
    if ($null -ne $outputStream) {
      $outputStream.Dispose()
    }
    if ($null -ne $responseStream) {
      $responseStream.Dispose()
    }
    if ($null -ne $response) {
      $response.Dispose()
    }
    if ($null -ne $request) {
      $request.Abort()
    }
    if ($null -ne $temporaryPath -and [System.IO.File]::Exists($temporaryPath)) {
      [System.IO.File]::Delete($temporaryPath)
    }
  }
}

try {
  if ($args.Count -ne 0) {
    throw 'buildish-wrapper-bootstrap.ps1 does not accept command-line arguments.'
  }
  [void](Invoke-BuildishWrapperBootstrap)
  exit 0
} catch {
  [Console]::Error.WriteLine("buildish-wrapper-bootstrap: $($_.Exception.Message)")
  exit 1
}
