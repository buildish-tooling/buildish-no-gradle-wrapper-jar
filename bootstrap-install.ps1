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

 Important: the repository copy is a release template. A release step must fill in
 the hard-coded base URL and pinned signing-key material before users execute it.
 That keeps the final published script static and reviewable without reintroducing
 runtime remote-override knobs.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Tool = 'buildish-no-gradle-wrapper-jar bootstrap-install'
$BaseUrl = '__BUILDISH_BOOTSTRAP_INSTALL_BASE_URL__'
$ManifestName = 'bootstrap-install-powershell.sha256'
$SignatureName = 'bootstrap-install-powershell.sha256.asc'
$Fingerprint = '__BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_FINGERPRINT__'
$TrustedPublicKey = @'
__BUILDISH_BOOTSTRAP_INSTALL_TRUSTED_PUBLIC_KEY__
'@
$Files = @(
  'install.ps1',
  'buildish-no-gradle-wrapper-jar.sh',
  'buildish-no-gradle-wrapper-jar.ps1',
  'buildish-no-gradle-wrapper-jar.init.gradle.kts'
)
$MaxMetadataBytes = 64KB
$MaxPayloadBytes = 256KB
$HttpTimeoutSeconds = 60
$OnWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

# __BUILDISH_BOOTSTRAP_INSTALL_DROP_START__
throw 'This checked-in bootstrap-install.ps1 still contains unreplaced release placeholders. Use a release-generated bootstrap-install.ps1 or the reviewed local-copy/manual-verification flow.'
# __BUILDISH_BOOTSTRAP_INSTALL_DROP_END__

function Test-WindowsGitGpgPath {
  param([string]$CommandPath)

  if ([string]::IsNullOrWhiteSpace($CommandPath)) {
    return $false
  }

  $normalizedPath = $CommandPath.Replace('/', '\').ToLowerInvariant()
  return $normalizedPath.Contains('\git\usr\bin\') -or $normalizedPath.Contains('\git\mingw64\bin\')
}

function Get-GpgCommand {
  $unsupportedGitGpgCommandPath = $null

  foreach ($name in @('gpg.exe', 'gpg')) {
    $commands = @(Get-Command $name -All -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
      if ($null -eq $command) {
        continue
      }

      $commandPath = $command.Source
      if ($OnWindows -and (Test-WindowsGitGpgPath -CommandPath $commandPath)) {
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

  if ($OnWindows -and -not [string]::IsNullOrWhiteSpace($unsupportedGitGpgCommandPath)) {
    throw "Unsupported Git for Windows GnuPG detected at '$unsupportedGitGpgCommandPath'. Install a native Windows GnuPG such as Gpg4win, Chocolatey ('choco install gnupg'), or Scoop ('scoop install gpg')."
  }

  return $null
}

function Write-Utf8File {
  param(
    [string]$Path,
    [string]$Content
  )

  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Assert-MaxFileSize {
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

function Download {
  param(
    [string]$Path,
    [string]$Uri,
    [string]$Label,
    [long]$MaxBytes
  )

  $tempPath = Join-Path -Path (Split-Path -Parent $Path) -ChildPath ".buildish-bootstrap-install.$([System.IO.Path]::GetRandomFileName())"
  try {
    Invoke-WebRequest -Uri $Uri -OutFile $tempPath -TimeoutSec $HttpTimeoutSeconds
    Assert-MaxFileSize -Path $tempPath -MaxBytes $MaxBytes -Label $Label
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-FileSha256 {
  param([string]$Path)

  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-Gpg {
  param(
    [string]$GpgCommand,
    [string]$GpgHome,
    [string[]]$Arguments,
    [string]$FailurePrefix
  )

  # Invoke GPG directly so PowerShell waits for the native process and captures
  # both streams before control returns. Start-Process output-file redirection
  # can expose an empty file briefly even after the process reports completion.
  $commandArguments = @('--homedir', $GpgHome, '--batch', '--no-options', '--no-autostart') + $Arguments
  $capturedOutput = @(& $GpgCommand @commandArguments 2>&1)
  $exitCode = $LASTEXITCODE
  $output = ($capturedOutput | ForEach-Object { $_.ToString() }) -join [System.Environment]::NewLine
  if ($exitCode -ne 0) {
    throw "${FailurePrefix}: ($exitCode) $output"
  }
  return $output
}

function Verify-Signature {
  param(
    [string]$ManifestPath,
    [string]$SignaturePath,
    [string]$GpgCommand
  )

  $tempDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "buildish-bootstrap-install-gpg-$([System.Guid]::NewGuid())"
  $gpgHome = Join-Path -Path $tempDirectory -ChildPath 'home'
  $trustedKeyPath = Join-Path -Path $tempDirectory -ChildPath 'trusted-key.asc'

  try {
    New-Item -ItemType Directory -Path $gpgHome -Force | Out-Null
    Write-Utf8File -Path $trustedKeyPath -Content $TrustedPublicKey

    $fingerprintOutput = Invoke-Gpg -GpgCommand $GpgCommand -GpgHome $gpgHome -Arguments @('--show-keys', '--with-colons', '--fingerprint', $trustedKeyPath) -FailurePrefix 'Unable to inspect the pinned release signing key'
    $fingerprintLine = ($fingerprintOutput -split "`r?`n" | Where-Object { $_.StartsWith('fpr:') } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($fingerprintLine)) {
      throw 'Pinned release signing key did not expose a primary fingerprint.'
    }

    $actualFingerprint = $fingerprintLine.Split(':')[9].ToLowerInvariant()
    if ($actualFingerprint -ne $Fingerprint) {
      throw 'Pinned release signing key fingerprint mismatch.'
    }

    [void](Invoke-Gpg -GpgCommand $GpgCommand -GpgHome $gpgHome -Arguments @('--import', $trustedKeyPath) -FailurePrefix 'Unable to import the pinned release signing key')
    [void](Invoke-Gpg -GpgCommand $GpgCommand -GpgHome $gpgHome -Arguments @('--no-auto-key-retrieve', '--verify', $SignaturePath, $ManifestPath) -FailurePrefix 'Detached signature verification failed for the payload manifest')
  } finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Get-ManifestChecksum {
  param(
    [string]$ManifestPath,
    [string]$ExpectedFileName
  )

  $foundChecksums = [System.Collections.Generic.List[string]]::new()
  foreach ($line in Get-Content -LiteralPath $ManifestPath) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $match = [regex]::Match($line, '^(?<sha>[A-Fa-f0-9]{64})  (?<file>[^ ]+)$')
    if (-not $match.Success) {
      throw "Verified payload manifest line was malformed: '$line'."
    }

    $fileName = $match.Groups['file'].Value
    if ($fileName -notin $Files) {
      throw "Verified payload manifest contained an unexpected file '$fileName'."
    }

    if ($fileName -eq $ExpectedFileName) {
      [void]$foundChecksums.Add($match.Groups['sha'].Value.ToLowerInvariant())
    }
  }

  if ($foundChecksums.Count -ne 1) {
    throw "Verified payload manifest did not contain exactly one checksum entry for '$ExpectedFileName'."
  }

  return $foundChecksums[0]
}

$bootstrapTempDirectory = $null

try {
  $gpgCommand = Get-GpgCommand
  if ([string]::IsNullOrWhiteSpace($gpgCommand)) {
    throw "A GnuPG command ('gpg.exe' preferred, otherwise 'gpg') is required for detached-signature verification but was not found on PATH."
  }

  $positionals = [System.Collections.Generic.List[string]]::new()
  $argIndex = 0
  while ($argIndex -lt $args.Count) {
    $arg = $args[$argIndex]
    if ($arg -eq '--') {
      $argIndex++
      while ($argIndex -lt $args.Count) {
        [void]$positionals.Add($args[$argIndex])
        $argIndex++
      }
      break
    }
    if ($arg.StartsWith('-')) {
      throw "Unknown option '$arg'."
    }
    [void]$positionals.Add($arg)
    $argIndex++
  }

  if ($positionals.Count -gt 1) {
    throw 'Expected zero or one positional argument: the target project directory.'
  }

  $targetDirectory = if ($positionals.Count -eq 1) { $positionals[0] } else { '.' }
  $bootstrapTempDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "buildish-bootstrap-install-$([System.Guid]::NewGuid())"
  $filesDirectory = Join-Path -Path $bootstrapTempDirectory -ChildPath 'files'
  $manifestPath = Join-Path -Path $bootstrapTempDirectory -ChildPath $ManifestName
  $signaturePath = Join-Path -Path $bootstrapTempDirectory -ChildPath $SignatureName
  New-Item -ItemType Directory -Path $filesDirectory -Force | Out-Null

  foreach ($fileName in $Files) {
    Download -Path (Join-Path -Path $filesDirectory -ChildPath $fileName) -Uri "$BaseUrl/$fileName" -Label "File '$fileName'" -MaxBytes $MaxPayloadBytes
  }

  Download -Path $manifestPath -Uri "$BaseUrl/$ManifestName" -Label 'Checksum manifest' -MaxBytes $MaxMetadataBytes
  Download -Path $signaturePath -Uri "$BaseUrl/$SignatureName" -Label 'Checksum manifest detached signature' -MaxBytes $MaxMetadataBytes

  Verify-Signature -ManifestPath $manifestPath -SignaturePath $signaturePath -GpgCommand $gpgCommand
  foreach ($fileName in $Files) {
    $expectedChecksum = Get-ManifestChecksum -ManifestPath $manifestPath -ExpectedFileName $fileName
    $actualChecksum = Get-FileSha256 -Path (Join-Path -Path $filesDirectory -ChildPath $fileName)
    if ($actualChecksum -ne $expectedChecksum) {
      throw "Downloaded file '$fileName' did not match the verified SHA-256 checksum."
    }
  }

  & (Join-Path -Path $filesDirectory -ChildPath 'install.ps1') --trusted-source-dir $filesDirectory $targetDirectory
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
} catch {
  Write-Error "${Tool}: $($_.Exception.Message)"
  exit 1
} finally {
  if ($null -ne $bootstrapTempDirectory) {
    Remove-Item -LiteralPath $bootstrapTempDirectory -Recurse -Force -ErrorAction SilentlyContinue
  }
}
