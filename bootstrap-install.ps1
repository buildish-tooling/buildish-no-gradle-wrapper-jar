<#
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

 Tiny secure bootstrap verifier for the no-gradle-wrapper-jar installer.

 Important: the repository copy is a release template. A release step must render
 the hard-coded base URL and pinned signing-key material before users execute it.
 That keeps the final published script static and reviewable without reintroducing
 runtime remote-override knobs.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BuildishBootstrapInstallToolName = 'buildish-no-gradle-wrapper-jar bootstrap-install'
$BuildishBootstrapInstallBaseUrl = '__BUILDISH_BOOTSTRAP_INSTALL_BASE_URL__'
$BuildishBootstrapInstallManifestName = 'bootstrap-install-powershell.sha256'
$BuildishBootstrapInstallSignatureName = 'bootstrap-install-powershell.sha256.asc'
$BuildishBootstrapInstallTrustedFingerprint = '__BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_FINGERPRINT__'
$BuildishBootstrapInstallTrustedPublicKey = @'
__BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_PUBLIC_KEY__
'@
$BuildishBootstrapInstallExpectedFiles = @(
  'install.ps1',
  'buildish-no-gradle-wrapper-jar.sh',
  'buildish-no-gradle-wrapper-jar.ps1',
  'buildish-no-gradle-wrapper-jar.init.gradle.kts'
)
$BuildishBootstrapInstallMaxMetadataBytes = 64KB
$BuildishBootstrapInstallMaxPayloadBytes = 256KB
$BuildishBootstrapInstallHttpTimeoutSeconds = 60
$BuildishBootstrapIsWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

function Test-BuildishBootstrapInstallWindowsGitGpgPath {
  param([string]$CommandPath)

  if ([string]::IsNullOrWhiteSpace($CommandPath)) {
    return $false
  }

  $normalizedPath = $CommandPath.Replace('/', '\').ToLowerInvariant()
  return $normalizedPath.Contains('\git\usr\bin\') -or $normalizedPath.Contains('\git\mingw64\bin\')
}

function Get-BuildishBootstrapInstallGpgCommandPath {
  $unsupportedGitGpgCommandPath = $null

  foreach ($name in @('gpg.exe', 'gpg')) {
    $commands = @(Get-Command $name -All -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
      if ($null -eq $command) {
        continue
      }

      $commandPath = $command.Source
      if ($BuildishBootstrapIsWindows -and (Test-BuildishBootstrapInstallWindowsGitGpgPath -CommandPath $commandPath)) {
        if ([string]::IsNullOrWhiteSpace($unsupportedGitGpgCommandPath)) {
          $unsupportedGitGpgCommandPath = $commandPath
        }
        continue
      }

      if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
        return $commandPath
      }
    }
  }

  if ($BuildishBootstrapIsWindows -and -not [string]::IsNullOrWhiteSpace($unsupportedGitGpgCommandPath)) {
    throw "Unsupported Git for Windows GnuPG detected at '$unsupportedGitGpgCommandPath'. Install a native Windows GnuPG such as Gpg4win, Chocolatey ('choco install gnupg'), or Scoop ('scoop install gpg')."
  }

  return $null
}

function Get-BuildishBootstrapInstallUtf8NoBomEncoding {
  return [System.Text.UTF8Encoding]::new($false)
}

function Write-BuildishBootstrapInstallUtf8File {
  param(
    [string]$Path,
    [string]$Content
  )

  [System.IO.File]::WriteAllText($Path, $Content, (Get-BuildishBootstrapInstallUtf8NoBomEncoding))
}

function New-BuildishBootstrapInstallTempPath {
  param([string]$Directory)

  return [System.IO.Path]::Combine($Directory, ".buildish-bootstrap-install.$([System.IO.Path]::GetRandomFileName())")
}

function Assert-BuildishBootstrapInstallRendered {
  if ($BuildishBootstrapInstallBaseUrl.Contains('__BUILDISH_BOOTSTRAP_') -or
      $BuildishBootstrapInstallTrustedFingerprint.Contains('__BUILDISH_BOOTSTRAP_') -or
      $BuildishBootstrapInstallTrustedPublicKey.Contains('__BUILDISH_BOOTSTRAP_')) {
    throw 'This repository copy is an unrendered release template. Use a release-rendered bootstrap-install.ps1 or the reviewed local-copy/manual-verification flow.'
  }
}

function Assert-BuildishBootstrapInstallMaxFileSize {
  param(
    [string]$Path,
    [long]$MaxBytes,
    [string]$Label
  )

  $size = (Get-Item -LiteralPath $Path -Force).Length
  if ($size -gt $MaxBytes) {
    throw "$Label exceeded the maximum allowed size of $MaxBytes bytes."
  }
}

function Save-BuildishBootstrapInstallDownloadedFile {
  param(
    [string]$Path,
    [string]$Uri,
    [string]$Label,
    [long]$MaxBytes
  )

  $tempPath = New-BuildishBootstrapInstallTempPath -Directory (Split-Path -Parent $Path)
  try {
    Invoke-WebRequest -Uri $Uri -OutFile $tempPath -TimeoutSec $BuildishBootstrapInstallHttpTimeoutSeconds
    Assert-BuildishBootstrapInstallMaxFileSize -Path $tempPath -MaxBytes $MaxBytes -Label $Label
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-BuildishBootstrapInstallFileSha256 {
  param([string]$Path)

  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-BuildishBootstrapInstallGpg {
  param(
    [string]$GpgCommand,
    [string]$GpgHome,
    [string[]]$Arguments,
    [string]$FailurePrefix
  )

  $stdoutPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "buildish-bootstrap-install-gpg-stdout-$([System.Guid]::NewGuid()).txt"
  $stderrPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "buildish-bootstrap-install-gpg-stderr-$([System.Guid]::NewGuid()).txt"

  try {
    $process = Start-Process -FilePath $GpgCommand -ArgumentList (@('--homedir', $GpgHome, '--batch', '--no-options', '--no-autostart') + $Arguments) -PassThru -Wait -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    $output = ($stdout, $stderr | Where-Object { -not [string]::IsNullOrEmpty($_) }) -join ''
    if ($process.ExitCode -ne 0) {
      throw "${FailurePrefix}: ($($process.ExitCode)) $output"
    }
    return $output
  } finally {
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

function Test-BuildishBootstrapInstallManifestSignature {
  param(
    [string]$ManifestPath,
    [string]$SignaturePath,
    [string]$GpgCommand
  )

  $tempDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "buildish-bootstrap-install-gpg-$([System.Guid]::NewGuid())"
  $gpgHome = Join-Path -Path $tempDirectory -ChildPath 'home'
  $trustedKeyPath = Join-Path -Path $tempDirectory -ChildPath 'trusted-key.asc'
  $localManifestPath = Join-Path -Path $tempDirectory -ChildPath 'manifest.sha256'
  $localSignaturePath = Join-Path -Path $tempDirectory -ChildPath 'manifest.sha256.asc'
  $locationPushed = $false

  try {
    New-Item -ItemType Directory -Path $gpgHome -Force | Out-Null
    Write-BuildishBootstrapInstallUtf8File -Path $trustedKeyPath -Content $BuildishBootstrapInstallTrustedPublicKey
    Copy-Item -LiteralPath $ManifestPath -Destination $localManifestPath -Force
    Copy-Item -LiteralPath $SignaturePath -Destination $localSignaturePath -Force

    Push-Location -LiteralPath $tempDirectory
    $locationPushed = $true

    $fingerprintOutput = Invoke-BuildishBootstrapInstallGpg -GpgCommand $GpgCommand -GpgHome 'home' -Arguments @('--show-keys', '--with-colons', '--fingerprint', 'trusted-key.asc') -FailurePrefix 'Unable to inspect the pinned release signing key'
    $fingerprintLine = ($fingerprintOutput -split "`r?`n" | Where-Object { $_.StartsWith('fpr:') } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($fingerprintLine)) {
      throw 'Pinned release signing key did not expose a primary fingerprint.'
    }

    $actualFingerprint = $fingerprintLine.Split(':')[9].ToLowerInvariant()
    if ($actualFingerprint -ne $BuildishBootstrapInstallTrustedFingerprint) {
      throw 'Pinned release signing key fingerprint mismatch.'
    }

    [void](Invoke-BuildishBootstrapInstallGpg -GpgCommand $GpgCommand -GpgHome 'home' -Arguments @('--import', 'trusted-key.asc') -FailurePrefix 'Unable to import the pinned release signing key')
    [void](Invoke-BuildishBootstrapInstallGpg -GpgCommand $GpgCommand -GpgHome 'home' -Arguments @('--no-auto-key-retrieve', '--verify', 'manifest.sha256.asc', 'manifest.sha256') -FailurePrefix 'Detached signature verification failed for the payload manifest')
  } finally {
    if ($locationPushed) {
      Pop-Location
    }
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Get-BuildishBootstrapInstallManifestChecksum {
  param(
    [string]$ManifestPath,
    [string]$ExpectedFileName
  )

  $matches = [System.Collections.Generic.List[string]]::new()
  foreach ($line in Get-Content -LiteralPath $ManifestPath) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $match = [regex]::Match($line, '^(?<sha>[A-Fa-f0-9]{64})  (?<file>[^ ]+)$')
    if (-not $match.Success) {
      throw "Verified payload manifest line was malformed: '$line'."
    }

    $fileName = $match.Groups['file'].Value
    if ($fileName -notin $BuildishBootstrapInstallExpectedFiles) {
      throw "Verified payload manifest contained an unexpected file '$fileName'."
    }

    if ($fileName -eq $ExpectedFileName) {
      [void]$matches.Add($match.Groups['sha'].Value.ToLowerInvariant())
    }
  }

  if ($matches.Count -ne 1) {
    throw "Verified payload manifest did not contain exactly one checksum entry for '$ExpectedFileName'."
  }

  return $matches[0]
}

function Assert-BuildishBootstrapInstallVerifiedPayloadSet {
  param(
    [string]$PayloadDirectory,
    [string]$ManifestPath
  )

  foreach ($fileName in $BuildishBootstrapInstallExpectedFiles) {
    $expectedChecksum = Get-BuildishBootstrapInstallManifestChecksum -ManifestPath $ManifestPath -ExpectedFileName $fileName
    $actualChecksum = Get-BuildishBootstrapInstallFileSha256 -Path (Join-Path -Path $PayloadDirectory -ChildPath $fileName)
    if ($actualChecksum -ne $expectedChecksum) {
      throw "Downloaded payload file '$fileName' did not match the verified SHA-256 checksum."
    }
  }
}

try {
  Assert-BuildishBootstrapInstallRendered

  $gpgCommand = Get-BuildishBootstrapInstallGpgCommandPath
  if ([string]::IsNullOrWhiteSpace($gpgCommand)) {
    throw "A GnuPG command ('gpg.exe' preferred, otherwise 'gpg') is required for detached-signature verification but was not found on PATH."
  }

  $parsedPositionalArgs = [System.Collections.Generic.List[string]]::new()
  $parsedArgIndex = 0
  while ($parsedArgIndex -lt $args.Count) {
    $parsedArg = $args[$parsedArgIndex]
    if ($parsedArg -eq '--') {
      $parsedArgIndex++
      while ($parsedArgIndex -lt $args.Count) {
        [void]$parsedPositionalArgs.Add($args[$parsedArgIndex])
        $parsedArgIndex++
      }
      break
    }
    if ($parsedArg.StartsWith('-')) {
      throw "Unknown option '$parsedArg'."
    }
    [void]$parsedPositionalArgs.Add($parsedArg)
    $parsedArgIndex++
  }

  if ($parsedPositionalArgs.Count -gt 1) {
    throw 'Expected zero or one positional argument: the target project directory.'
  }

  $targetDirectory = if ($parsedPositionalArgs.Count -eq 1) { $parsedPositionalArgs[0] } else { '.' }
  $bootstrapTempDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "buildish-bootstrap-install-$([System.Guid]::NewGuid())"
  $payloadDirectory = Join-Path -Path $bootstrapTempDirectory -ChildPath 'payload'
  $manifestPath = Join-Path -Path $bootstrapTempDirectory -ChildPath $BuildishBootstrapInstallManifestName
  $signaturePath = Join-Path -Path $bootstrapTempDirectory -ChildPath $BuildishBootstrapInstallSignatureName
  New-Item -ItemType Directory -Path $payloadDirectory -Force | Out-Null

  foreach ($fileName in $BuildishBootstrapInstallExpectedFiles) {
    Save-BuildishBootstrapInstallDownloadedFile -Path (Join-Path -Path $payloadDirectory -ChildPath $fileName) -Uri "$BuildishBootstrapInstallBaseUrl/$fileName" -Label "Payload file '$fileName'" -MaxBytes $BuildishBootstrapInstallMaxPayloadBytes
  }

  Save-BuildishBootstrapInstallDownloadedFile -Path $manifestPath -Uri "$BuildishBootstrapInstallBaseUrl/$BuildishBootstrapInstallManifestName" -Label 'Payload checksum manifest' -MaxBytes $BuildishBootstrapInstallMaxMetadataBytes
  Save-BuildishBootstrapInstallDownloadedFile -Path $signaturePath -Uri "$BuildishBootstrapInstallBaseUrl/$BuildishBootstrapInstallSignatureName" -Label 'Payload checksum manifest detached signature' -MaxBytes $BuildishBootstrapInstallMaxMetadataBytes

  Test-BuildishBootstrapInstallManifestSignature -ManifestPath $manifestPath -SignaturePath $signaturePath -GpgCommand $gpgCommand
  Assert-BuildishBootstrapInstallVerifiedPayloadSet -PayloadDirectory $payloadDirectory -ManifestPath $manifestPath

  & (Join-Path -Path $payloadDirectory -ChildPath 'install.ps1') --trusted-source-dir $payloadDirectory $targetDirectory
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
} catch {
  Write-Error "${BuildishBootstrapInstallToolName}: $($_.Exception.Message)"
  exit 1
} finally {
  if ($null -ne $bootstrapTempDirectory) {
    Remove-Item -LiteralPath $bootstrapTempDirectory -Recurse -Force -ErrorAction SilentlyContinue
  }
}