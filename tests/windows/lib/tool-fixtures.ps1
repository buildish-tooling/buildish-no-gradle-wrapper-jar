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
function Assert-BuildishCanonicalSource {
  param([Parameter(Mandatory = $true)][string]$Name)

  $path = Join-Path -Path $script:RepositoryRoot -ChildPath $Name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "missing canonical product source: $Name"
  }
  return $path
}

function Assert-BuildishGradleHome {
  param(
    [Parameter(Mandatory = $true)][string]$GradleHome,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion,
    [Parameter(Mandatory = $true)][string]$CaseDirectory
  )

  $absoluteHome = Get-BuildishAbsolutePath -Path $GradleHome -BasePath $script:RepositoryRoot
  $gradleBatch = Join-Path -Path $absoluteHome -ChildPath 'bin\gradle.bat'
  if (-not (Test-Path -LiteralPath $gradleBatch -PathType Leaf)) {
    throw "Gradle $ExpectedVersion home does not contain bin\gradle.bat: $absoluteHome"
  }
  $result = Invoke-BuildishNativeProcess `
    -FilePath 'cmd.exe' `
    -ArgumentString ('/d /c call ' + (ConvertTo-BuildishCmdArgument -Value $gradleBatch) + ' --version') `
    -WorkingDirectory $CaseDirectory `
    -Environment @{ GRADLE_USER_HOME = (Join-Path $CaseDirectory 'gradle-user-home-validation') } `
    -TimeoutSeconds 60
  Assert-BuildishExitCode -Result $result -ExpectedExitCode 0 -Label "Gradle $ExpectedVersion validation"
  $versionPattern = '(?m)^Gradle ' + [regex]::Escape($ExpectedVersion) + '\r?$'
  if ($result.StandardOutput -notmatch $versionPattern) {
    throw "Gradle home '$absoluteHome' did not report exact version $ExpectedVersion."
  }
  return $absoluteHome
}

function Get-BuildishSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)

  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BuildishManifestEntry {
  param(
    [Parameter(Mandatory = $true)][string]$Collection,
    [Parameter(Mandatory = $true)][string]$Version
  )

  $matches = @($script:Manifest.$Collection | Where-Object { $_.version -ceq $Version })
  if ($matches.Count -ne 1) {
    throw "Expected one manifest $Collection entry for $Version, found $($matches.Count)."
  }
  return $matches[0]
}

function Get-BuildishPythonPath {
  foreach ($name in @('python.exe', 'python3.exe')) {
    $commands = @(Get-Command `
        -Name $name `
        -CommandType Application `
        -ErrorAction SilentlyContinue)
    if ($commands.Count -ne 0) {
      return [string]$commands[0].Source
    }
  }
  throw 'Native Windows tests require Python 3 as python.exe or python3.exe on PATH.'
}

function Get-BuildishWrapperPayload {
  param([Parameter(Mandatory = $true)][string]$Version)

  $entry = Get-BuildishManifestEntry -Collection 'wrapperVersions' -Version $Version
  $toolRoot = Join-Path -Path $script:ResolvedBuildDirectory -ChildPath 'test-tools'
  New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
  $destination = Join-Path -Path $toolRoot -ChildPath "wrapper-$Version.jar"
  $temporary = $destination + '.tmp.' + [System.Guid]::NewGuid().ToString('N')
  if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
    try {
      $arguments = '--fail --location --silent --show-error --max-time 120 --output ' +
        (ConvertTo-BuildishCmdArgument -Value $temporary) + ' ' +
        (ConvertTo-BuildishCmdArgument -Value ([string]$entry.rawJarUrl))
      $result = Invoke-BuildishNativeProcess `
        -FilePath 'curl.exe' `
        -ArgumentString $arguments `
        -WorkingDirectory $script:WorkRoot `
        -TimeoutSeconds 150
      Assert-BuildishExitCode `
        -Result $result `
        -ExpectedExitCode 0 `
        -Label "Wrapper JAR $Version download"
      Move-Item -LiteralPath $temporary -Destination $destination -ErrorAction Stop
    } finally {
      Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
  }
  $actual = Get-BuildishSha256 -Path $destination
  if ($actual -cne [string]$entry.wrapperJarSha256) {
    throw "Wrapper JAR $Version digest mismatch: expected $($entry.wrapperJarSha256), found $actual."
  }
  return $destination
}

function Get-BuildishGradleHome {
  param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$CaseDirectory
  )

  if ($script:GradleHomes.ContainsKey($Version)) {
    return $script:GradleHomes[$Version]
  }

  $supplied = if ($Version -ceq '8.14.5') { $Gradle8145Home } else { $Gradle961Home }
  if (-not [string]::IsNullOrWhiteSpace($supplied)) {
    $gradleHome = Assert-BuildishGradleHome `
      -GradleHome $supplied `
      -ExpectedVersion $Version `
      -CaseDirectory $CaseDirectory
    $script:GradleHomes[$Version] = $gradleHome
    return $gradleHome
  }

  $entry = Get-BuildishManifestEntry -Collection 'targetDistributions' -Version $Version
  $toolRoot = Join-Path -Path $script:ResolvedBuildDirectory -ChildPath 'test-tools'
  $gradleHome = Join-Path -Path $toolRoot -ChildPath "gradle-$Version"
  $archive = Join-Path -Path $toolRoot -ChildPath "gradle-$Version-bin.zip"
  New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
  if (-not (Test-Path -LiteralPath (Join-Path $gradleHome 'bin\gradle.bat') -PathType Leaf)) {
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
      $temporaryArchive = $archive + '.tmp.' + [System.Guid]::NewGuid().ToString('N')
      try {
        $arguments = '--fail --location --silent --show-error --max-time 300 --output ' +
          (ConvertTo-BuildishCmdArgument -Value $temporaryArchive) + ' ' +
          (ConvertTo-BuildishCmdArgument -Value ([string]$entry.url))
        $download = Invoke-BuildishNativeProcess `
          -FilePath 'curl.exe' `
          -ArgumentString $arguments `
          -WorkingDirectory $script:WorkRoot `
          -TimeoutSeconds 330
        Assert-BuildishExitCode `
          -Result $download `
          -ExpectedExitCode 0 `
          -Label "Gradle $Version distribution download"
        Move-Item -LiteralPath $temporaryArchive -Destination $archive -ErrorAction Stop
      } finally {
        Remove-Item -LiteralPath $temporaryArchive -Force -ErrorAction SilentlyContinue
      }
    }
    $actual = Get-BuildishSha256 -Path $archive
    if ($actual -cne [string]$entry.sha256) {
      throw "Gradle $Version distribution digest mismatch: expected $($entry.sha256), found $actual."
    }

    $staging = Join-Path -Path $toolRoot -ChildPath (
      ".extract-gradle-$Version-$([System.Guid]::NewGuid().ToString('N'))"
    )
    try {
      New-Item -ItemType Directory -Path $staging -Force | Out-Null
      Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
      $extracted = Join-Path -Path $staging -ChildPath "gradle-$Version"
      if (-not (Test-Path -LiteralPath (Join-Path $extracted 'bin\gradle.bat') -PathType Leaf)) {
        throw "Gradle $Version archive did not contain gradle-$Version\bin\gradle.bat."
      }
      if (Test-Path -LiteralPath $gradleHome) {
        throw "Refusing to overwrite incomplete Gradle home: $gradleHome"
      }
      Move-Item -LiteralPath $extracted -Destination $gradleHome -ErrorAction Stop
    } finally {
      Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  $validated = Assert-BuildishGradleHome `
    -GradleHome $gradleHome `
    -ExpectedVersion $Version `
    -CaseDirectory $CaseDirectory
  $script:GradleHomes[$Version] = $validated
  return $validated
}
