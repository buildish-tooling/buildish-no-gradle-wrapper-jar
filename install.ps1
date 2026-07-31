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

<#
PowerShell installer for the Buildish no-gradle-wrapper-jar helper tool.
https://buildish.org/components/no-gradle-wrapper-jar/

The installer assumes it is run against an existing Gradle project that already
contains the generated wrapper launchers and `gradle-wrapper.properties`. It then:
  1. stages the helper files into `gradle/`
  2. removes any existing `gradle-wrapper.jar`
  3. patches `gradlew` / `gradlew.bat` so the helpers execute on every launch
  4. updates `.gitignore` for the retained checksum/signature side files

Safety properties:
  * symlinks / reparse points are rejected rather than followed
  * writes go through temporary files and atomic moves where possible
  * helper files are only staged from a caller-supplied --trusted-source-dir
    because this installer is not meant to establish trust in downloaded bytes
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BuildishToolName = 'buildish-no-gradle-wrapper-jar'

function Show-BuildishInstallUsage {
  Write-Host @'
Usage: install.ps1 --trusted-source-dir <path> [target-project-directory]

Stage reviewed helper files from a trusted local directory, patch the Gradle
wrapper launchers, remove gradle-wrapper.jar, and update .gitignore.

Options:
  --trusted-source-dir <path>  Reviewed directory containing the helper files.
  -h, --help                   Show this help and exit.
'@
}

if ($args.Count -ge 1 -and @('-h', '--help') -contains $args[0]) {
  Show-BuildishInstallUsage
  exit 0
}

# Parse --trusted-source-dir option and the optional positional target-directory argument.
$parsedTrustedSourceDirectory = ''
$parsedPositionalArgs = [System.Collections.Generic.List[string]]::new()
$parsedArgIndex = 0
while ($parsedArgIndex -lt $args.Count) {
  $parsedArg = $args[$parsedArgIndex]
  if ($parsedArg -eq '--trusted-source-dir') {
    if ($parsedArgIndex + 1 -ge $args.Count) {
      Write-Error "$BuildishToolName install: --trusted-source-dir requires a path argument."
      exit 1
    }
    $parsedTrustedSourceDirectory = $args[$parsedArgIndex + 1]
    $parsedArgIndex += 2
  } elseif ($parsedArg.StartsWith('--trusted-source-dir=')) {
    $parsedTrustedSourceDirectory = $parsedArg.Substring('--trusted-source-dir='.Length)
    $parsedArgIndex++
  } elseif ($parsedArg -eq '--') {
    $parsedArgIndex++
    while ($parsedArgIndex -lt $args.Count) {
      [void]$parsedPositionalArgs.Add($args[$parsedArgIndex])
      $parsedArgIndex++
    }
    break
  } elseif ($parsedArg.StartsWith('-')) {
    Write-Error "$BuildishToolName install: Unknown option '$parsedArg'."
    exit 1
  } else {
    [void]$parsedPositionalArgs.Add($parsedArg)
    $parsedArgIndex++
  }
}

$TrustedSourceDirectory = $parsedTrustedSourceDirectory
$TargetDirectory = if ($parsedPositionalArgs.Count -ge 1 -and -not [string]::IsNullOrWhiteSpace($parsedPositionalArgs[0])) {
  $parsedPositionalArgs[0]
} else {
  (Get-Location).Path
}

# Use UTF-8 without a BOM when rewriting launcher and text files so the output
# remains stable and acceptable to Gradle / shell tooling.
function Get-BuildishUtf8NoBomEncoding {
  return [System.Text.UTF8Encoding]::new($false)
}

function Set-BuildishUtf8NoBomFileText {
  param(
    [string]$Path,
    [string]$Content
  )

  [System.IO.File]::WriteAllText($Path, $Content, (Get-BuildishUtf8NoBomEncoding))
}

# PowerShell on Windows reports symlinks and junctions as reparse points. The
# installer rejects them so it never patches through indirection.
function Test-BuildishReparsePoint {
  param([string]$Path)

  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) {
    return $false
  }

  return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# Shared symlink / reparse-point guard.
function Assert-BuildishNotSymlink {
  param(
    [string]$Path,
    [string]$Label
  )

  if (Test-BuildishReparsePoint -Path $Path) {
    throw "$Label must not be a symbolic link: '$Path'."
  }
}

function Assert-BuildishDirectory {
  param(
    [string]$Path,
    [string]$Label
  )

  Assert-BuildishNotSymlink -Path $Path -Label $Label
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "$Label must be a directory: '$Path'."
  }
}

function Assert-BuildishRegularFile {
  param(
    [string]$Path,
    [string]$Label
  )

  Assert-BuildishNotSymlink -Path $Path -Label $Label
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Label must be a regular file: '$Path'."
  }
}

function Assert-BuildishRegularFileOrAbsent {
  param(
    [string]$Path,
    [string]$Label
  )

  if ($null -ne (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
    Assert-BuildishRegularFile -Path $Path -Label $Label
  }
}

# Create a temp file path inside the destination directory so the final move is a
# same-volume rename whenever possible.
function New-BuildishInstallTempPath {
  param([string]$Directory)

  return [System.IO.Path]::Combine($Directory, ".buildish-no-gradle-wrapper-jar-install.$([System.IO.Path]::GetRandomFileName())")
}

function Add-BuildishBatchHelperArgumentsToExecuteLine {
  param([string]$ExecuteLine)

  $argumentMarker = ' %*'
  $argumentIndex = $ExecuteLine.IndexOf($argumentMarker, [System.StringComparison]::Ordinal)
  if ($argumentIndex -lt 0 -or $argumentIndex -ne $ExecuteLine.LastIndexOf($argumentMarker, [System.StringComparison]::Ordinal)) {
    throw "Unsupported batch execute line shape: '$ExecuteLine'."
  }

  return $ExecuteLine.Insert($argumentIndex, ' %BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS%')
}

# Local-copy variant used by integration tests and verified bootstrap handoff.
# The caller is explicitly trusted to provide already-trusted local files.
function Save-BuildishCopiedFile {
  param(
    [string]$Path,
    [string]$SourcePath,
    [string]$Label
  )

  if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "$Label source file was not found at '$SourcePath'."
  }

  Assert-BuildishNotSymlink -Path $Path -Label $Label
  Assert-BuildishNotSymlink -Path $SourcePath -Label "$Label source file"
  $tempPath = New-BuildishInstallTempPath -Directory ([System.IO.Path]::GetDirectoryName($Path))

  try {
    [System.IO.File]::WriteAllBytes($tempPath, [System.IO.File]::ReadAllBytes($SourcePath))
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
  } catch {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    throw "Unable to copy $Label from '$SourcePath': $($_.Exception.Message)"
  }
}

# Stage one helper file from the already-trusted local source tree.
function Save-BuildishToolFile {
  param(
    [string]$Path,
    [string]$FileName,
    [string]$Label
  )

  Save-BuildishCopiedFile -Path $Path -SourcePath (Join-Path -Path $TrustedSourceDirectoryAbsolute -ChildPath $FileName) -Label $Label
}

function Install-BuildishHelperFiles {
  param([string]$DestinationDirectory)

  $helperFiles = @(
    @{ Path = (Join-Path -Path $DestinationDirectory -ChildPath 'buildish-no-gradle-wrapper-jar.sh'); FileName = 'buildish-no-gradle-wrapper-jar.sh'; Label = 'POSIX helper script' },
    @{ Path = (Join-Path -Path $DestinationDirectory -ChildPath 'buildish-no-gradle-wrapper-jar.ps1'); FileName = 'buildish-no-gradle-wrapper-jar.ps1'; Label = 'PowerShell helper script' },
    @{ Path = (Join-Path -Path $DestinationDirectory -ChildPath 'buildish-no-gradle-wrapper-jar.init.gradle.kts'); FileName = 'buildish-no-gradle-wrapper-jar.init.gradle.kts'; Label = 'Gradle init script' }
  )

  foreach ($helperFile in $helperFiles) {
    Save-BuildishToolFile -Path $helperFile.Path -FileName $helperFile.FileName -Label $helperFile.Label
  }
}

# Normalize inserted multi-line text to match the target file's existing newline
# convention so patched launchers remain platform-native.
function Convert-BuildishTextToNewlineStyle {
  param(
    [string]$Text,
    [string]$Newline
  )

  return (($Text -split "`r?`n") -join $Newline)
}

# Insert one block after any one of several exact anchor lines unless that block
# is already present.
function Add-BuildishBlockAfterAnyAnchor {
  param(
    [string]$Path,
    [string]$InsertionBlock,
    [string]$Label,
    [string[]]$Anchors
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Write-Warning "$BuildishToolName install: Skipping missing $Label at '$Path'."
    return
  }

  Assert-BuildishNotSymlink -Path $Path -Label $Label
  $content = [System.IO.File]::ReadAllText($Path)

  $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
  $normalizedInsertionBlock = Convert-BuildishTextToNewlineStyle -Text $InsertionBlock -Newline $newline
  if ($content.Contains($normalizedInsertionBlock)) {
    return
  }

  foreach ($anchor in $Anchors) {
    $anchorWithNewline = "$anchor$newline"
    if ($content.Contains($anchorWithNewline)) {
      $updated = $content.Replace($anchorWithNewline, "$anchor$newline$normalizedInsertionBlock$newline")
      Set-BuildishUtf8NoBomFileText -Path $Path -Content $updated
      return
    }
    if ($content.EndsWith($anchor)) {
      $updated = $content.Substring(0, $content.Length - $anchor.Length) + "$anchor$newline$normalizedInsertionBlock"
      Set-BuildishUtf8NoBomFileText -Path $Path -Content $updated
      return
    }
  }

  throw "Unable to find the expected insertion point in $Label at '$Path'."
}

# Replace one exact generated line when present. Missing lines are tolerated here
# because Gradle launcher shapes evolve; the installer performs a required-line
# assertion afterwards to ensure the supported patched form exists.
function Replace-BuildishExactLineIfPresent {
  param(
    [string]$Path,
    [string]$CurrentLine,
    [string]$Replacement,
    [string]$Label
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Write-Warning "$BuildishToolName install: Skipping missing $Label at '$Path'."
    return
  }

  Assert-BuildishNotSymlink -Path $Path -Label $Label
  $content = [System.IO.File]::ReadAllText($Path)
  $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
  $normalizedReplacement = Convert-BuildishTextToNewlineStyle -Text $Replacement -Newline $newline
  if ($content.Contains($normalizedReplacement)) {
    return
  }

  $currentWithNewline = "$CurrentLine$newline"
  if ($content.Contains($currentWithNewline)) {
    $updated = $content.Replace($currentWithNewline, "$normalizedReplacement$newline")
  } elseif ($content.EndsWith($CurrentLine)) {
    $updated = $content.Substring(0, $content.Length - $CurrentLine.Length) + $normalizedReplacement
  } else {
    return
  }

  Set-BuildishUtf8NoBomFileText -Path $Path -Content $updated
}

# Variant that accepts any of several supported exact lines.
function Assert-BuildishAnyExactLinePresent {
  param(
    [string]$Path,
    [string[]]$ExpectedLines,
    [string]$Label
  )

  $content = [System.IO.File]::ReadAllText($Path)
  $lines = $content -split "`r?`n"
  foreach ($expectedLine in $ExpectedLines) {
    if ($lines -contains $expectedLine) {
      return
    }
  }

  throw "Unable to apply the expected update to $Label at '$Path'."
}

function Update-BuildishGradlewBat {
  param([string]$Path)

  Replace-BuildishExactLineIfPresent -Path $Path -CurrentLine $GradlewBatHelperInvocation -Replacement $GradlewBatHelperBlock -Label 'gradlew.bat'
  Add-BuildishBlockAfterAnyAnchor -Path $Path -InsertionBlock $GradlewBatHelperBlock -Label 'gradlew.bat' -Anchors @($GradlewBatAnchor)
  foreach ($executeLineReplacement in $GradlewBatSupportedExecuteLineReplacements) {
    Replace-BuildishExactLineIfPresent -Path $Path -CurrentLine $executeLineReplacement.Current -Replacement $executeLineReplacement.Replacement -Label 'gradlew.bat'
  }
  Assert-BuildishAnyExactLinePresent -Path $Path -ExpectedLines @($GradlewBatSupportedExecuteLineReplacements | ForEach-Object { $_.Replacement }) -Label 'gradlew.bat'
}

# Add ignore entries for the retained metadata side files while leaving projects
# free to commit them explicitly if that suits their policy.
function Update-BuildishGitignore {
  param([string]$Path)

  $gitignorePath = $Path
  $commentLine = '# Added by buildish-no-gradle-wrapper-jar'
  $entries = @(
    'gradle/wrapper/gradle-wrapper-*.sha256',
    'gradle/wrapper/gradle-wrapper-*.asc'
  )

  if (Test-Path -LiteralPath $gitignorePath -PathType Leaf) {
    Assert-BuildishNotSymlink -Path $gitignorePath -Label '.gitignore'
    $content = [System.IO.File]::ReadAllText($gitignorePath)
    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
  } else {
    $content = ''
    $newline = [Environment]::NewLine
  }

  $existingLines = if ([string]::IsNullOrEmpty($content)) { @() } else { $content -split "`r?`n" }
  $missingEntries = @($entries | Where-Object { -not ($existingLines -contains $_) })
  if ($missingEntries.Count -eq 0) {
    return
  }

  $builder = [System.Text.StringBuilder]::new($content)
  if ($builder.Length -gt 0 -and -not $content.EndsWith("`n") -and -not $content.EndsWith("`r")) {
    [void]$builder.Append($newline)
  }
  if ($builder.Length -gt 0) {
    [void]$builder.Append($newline)
  }
  if (-not ($existingLines -contains $commentLine)) {
    [void]$builder.Append($commentLine).Append($newline)
  }
  foreach ($entry in $missingEntries) {
    [void]$builder.Append($entry).Append($newline)
  }

  Set-BuildishUtf8NoBomFileText -Path $gitignorePath -Content $builder.ToString()
}

function Restore-BuildishInstallTransaction {
  param([object[]]$Entries)

  for ($entryIndex = $Entries.Count - 1; $entryIndex -ge 0; $entryIndex--) {
    $entry = $Entries[$entryIndex]
    if (-not $entry.Prepared) {
      continue
    }

    Remove-Item -LiteralPath $entry.Destination -Force -ErrorAction SilentlyContinue
    if ($entry.Existed -and (Test-Path -LiteralPath $entry.Backup -PathType Leaf)) {
      Move-Item -LiteralPath $entry.Backup -Destination $entry.Destination -Force -ErrorAction SilentlyContinue
    }
  }
}

function Backup-BuildishInstallTransaction {
  param([object[]]$Entries)

  foreach ($entry in $Entries) {
    if ($null -ne (Get-Item -LiteralPath $entry.Destination -Force -ErrorAction SilentlyContinue)) {
      Move-Item -LiteralPath $entry.Destination -Destination $entry.Backup -Force
      $entry.Existed = $true
    }
    $entry.Prepared = $true
  }
}

function Publish-BuildishInstallTransaction {
  param([object[]]$Entries)

  foreach ($entry in $Entries) {
    if ($null -ne $entry.Stage) {
      Move-Item -LiteralPath $entry.Stage -Destination $entry.Destination -Force
    }
  }
}

try {
  # Installer entrypoint validation and derived project-local paths.
  if ($parsedPositionalArgs.Count -gt 1) {
    throw 'Expected zero or one positional argument: the target project directory.'
  }
  Assert-BuildishDirectory -Path $TargetDirectory -Label 'Target project directory'
  if ([string]::IsNullOrWhiteSpace($TrustedSourceDirectory)) {
    throw '--trusted-source-dir is required. This installer only stages already-trusted local files.'
  }
  Assert-BuildishDirectory -Path $TrustedSourceDirectory -Label 'Trusted local source directory'

  $TargetDirectoryAbsolute = (Resolve-Path -LiteralPath $TargetDirectory).Path
  $TrustedSourceDirectoryAbsolute = (Resolve-Path -LiteralPath $TrustedSourceDirectory).Path
  $GradleDirectory = Join-Path -Path $TargetDirectoryAbsolute -ChildPath 'gradle'
  $WrapperDirectory = Join-Path -Path $GradleDirectory -ChildPath 'wrapper'
  $GradlePropertiesPath = Join-Path -Path $WrapperDirectory -ChildPath 'gradle-wrapper.properties'
  $GradleWrapperJarPath = Join-Path -Path $WrapperDirectory -ChildPath 'gradle-wrapper.jar'
  $GradlewPath = Join-Path -Path $TargetDirectoryAbsolute -ChildPath 'gradlew'
  $GradlewBatPath = Join-Path -Path $TargetDirectoryAbsolute -ChildPath 'gradlew.bat'
  $GradleInitScriptPath = Join-Path -Path $GradleDirectory -ChildPath 'buildish-no-gradle-wrapper-jar.init.gradle.kts'
  $HelperShPath = Join-Path -Path $GradleDirectory -ChildPath 'buildish-no-gradle-wrapper-jar.sh'
  $HelperPs1Path = Join-Path -Path $GradleDirectory -ChildPath 'buildish-no-gradle-wrapper-jar.ps1'
  $GitignorePath = Join-Path -Path $TargetDirectoryAbsolute -ChildPath '.gitignore'

  # Windows launcher patch structure: first capture helper-emitted arguments into
  # an environment variable, then splice that variable into the final Java line.
  # The pre-8.14 classpath/main-class form plus the later `-jar` forms, including
  # Gradle 9's endlocal wrapper, are supported explicitly.
  $GradlewCurrentAnchor = 'APP_HOME=$( cd -P "${APP_HOME:-./}" > /dev/null && printf ''%s\n'' "$PWD" ) || exit'
  $GradlewOldAnchor = 'APP_HOME=$( cd "${APP_HOME:-./}" && pwd -P ) || exit'
  $GradlewBatAnchor = 'for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi'
  $GradlewBatHelperInvocation = 'powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%APP_HOME%\gradle\buildish-no-gradle-wrapper-jar.ps1"'
  $GradlewBatHelperBlock = @"
set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=%*
set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=
for /f "delims=" %%a in ('$GradlewBatHelperInvocation') do @set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=%%a
set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=
if errorlevel 1 goto fail
"@
  $GradlewBatSupportedExecuteLines = @(
    '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -classpath "%CLASSPATH%" org.gradle.wrapper.GradleWrapperMain %*',
    '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -classpath "%CLASSPATH%" -jar "%APP_HOME%\gradle\wrapper\gradle-wrapper.jar" %*',
    '"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -jar "%APP_HOME%\gradle\wrapper\gradle-wrapper.jar" %*',
    'endlocal & "%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% "-Dorg.gradle.appname=%APP_BASE_NAME%" -jar "%APP_HOME%\gradle\wrapper\gradle-wrapper.jar" %* & call :exitWithErrorLevel'
  )
  $GradlewBatSupportedExecuteLineReplacements = @($GradlewBatSupportedExecuteLines | ForEach-Object {
    @{ Current = $_; Replacement = (Add-BuildishBatchHelperArgumentsToExecuteLine -ExecuteLine $_) }
  })

  Assert-BuildishDirectory -Path $TargetDirectoryAbsolute -Label 'Target project directory'
  Assert-BuildishDirectory -Path $GradleDirectory -Label 'Gradle directory'
  Assert-BuildishDirectory -Path $WrapperDirectory -Label 'Gradle wrapper directory'
  if ($null -eq (Get-Item -LiteralPath $GradlePropertiesPath -Force -ErrorAction SilentlyContinue)) {
    throw "Gradle wrapper properties file was not found at '$GradlePropertiesPath'. Run this installer from a Gradle project root or pass that directory as the only argument."
  }
  Assert-BuildishRegularFile -Path $GradlePropertiesPath -Label 'gradle-wrapper.properties'
  Assert-BuildishRegularFile -Path $GradlewPath -Label 'gradlew'
  Assert-BuildishRegularFile -Path $GradlewBatPath -Label 'gradlew.bat'
  Assert-BuildishRegularFileOrAbsent -Path $GradleWrapperJarPath -Label 'gradle-wrapper.jar'
  Assert-BuildishRegularFileOrAbsent -Path $HelperShPath -Label 'POSIX helper script'
  Assert-BuildishRegularFileOrAbsent -Path $HelperPs1Path -Label 'PowerShell helper script'
  Assert-BuildishRegularFileOrAbsent -Path $GradleInitScriptPath -Label 'Gradle init script'
  Assert-BuildishRegularFileOrAbsent -Path $GitignorePath -Label '.gitignore'

  $sourceFiles = @(
    @{ Path = (Join-Path -Path $TrustedSourceDirectoryAbsolute -ChildPath 'buildish-no-gradle-wrapper-jar.sh'); Label = 'POSIX helper source file' },
    @{ Path = (Join-Path -Path $TrustedSourceDirectoryAbsolute -ChildPath 'buildish-no-gradle-wrapper-jar.ps1'); Label = 'PowerShell helper source file' },
    @{ Path = (Join-Path -Path $TrustedSourceDirectoryAbsolute -ChildPath 'buildish-no-gradle-wrapper-jar.init.gradle.kts'); Label = 'Gradle init-script source file' }
  )
  foreach ($sourceFile in $sourceFiles) {
    Assert-BuildishRegularFile -Path $sourceFile.Path -Label $sourceFile.Label
  }

  $distributionLine = (Select-String -Path $GradlePropertiesPath -CaseSensitive -Pattern '^distributionUrl=' | Select-Object -First 1).Line
  if ([string]::IsNullOrWhiteSpace($distributionLine)) {
    throw 'Gradle wrapper properties file is missing a distributionUrl entry.'
  }
  $distributionUrl = $distributionLine.Substring('distributionUrl='.Length).Replace('\:', ':')
  if (-not [regex]::IsMatch($distributionUrl, '^https://services\.gradle\.org/distributions/gradle-[0-9]+(?:\.[0-9]+){1,2}-(?:bin|all)\.zip$')) {
    throw 'distributionUrl must be a canonical HTTPS services.gradle.org URL ending in gradle-<version>-bin.zip or gradle-<version>-all.zip.'
  }

  $wrapperPinName = 'buildishWrapperJarSha256Sum'
  $wrapperPinMatches = @(Select-String -Path $GradlePropertiesPath -CaseSensitive -Pattern "^$wrapperPinName=")
  if ($wrapperPinMatches.Count -eq 0) {
    throw "Gradle wrapper properties file is missing the required $wrapperPinName entry. Add the reviewed Gradle wrapper JAR SHA-256 for the distributionUrl version before installing."
  }
  if ($wrapperPinMatches.Count -ne 1) {
    throw "Gradle wrapper properties file contains duplicate $wrapperPinName entries. Keep exactly one reviewed lowercase SHA-256 value."
  }
  $wrapperPinValue = $wrapperPinMatches[0].Line.Substring("$wrapperPinName=".Length)
  if ($wrapperPinValue -cnotmatch '^[0-9a-f]{64}$') {
    throw "$wrapperPinName must be exactly one lowercase 64-character SHA-256 value."
  }

  # The helper verifies `gradle-wrapper.jar`, but it does not make Gradle start
  # verifying the distribution ZIP automatically. Emit a prominent installer-time
  # warning so adopters notice the missing checksum pin immediately.
  if (-not (Select-String -Path $GradlePropertiesPath -Pattern '^distributionSha256Sum=\S' -Quiet)) {
    Write-Warning "$BuildishToolName install: WARNING: '$GradlePropertiesPath' does not define distributionSha256Sum. Gradle itself will not pin the distribution ZIP checksum during wrapper downloads; this helper continues, but it only verifies gradle-wrapper.jar."
  }

  # Produce and validate all outputs before moving any managed project file.
  $transactionDirectory = Join-Path -Path $TargetDirectoryAbsolute -ChildPath ".buildish-no-gradle-wrapper-jar-transaction.$([System.IO.Path]::GetRandomFileName())"
  [void][System.IO.Directory]::CreateDirectory($transactionDirectory)
  $transactionActive = $false
  $transactionEntries = @()

  try {
    $stagedGradlewPath = Join-Path -Path $transactionDirectory -ChildPath 'gradlew'
    $stagedGradlewBatPath = Join-Path -Path $transactionDirectory -ChildPath 'gradlew.bat'
    $stagedGitignorePath = Join-Path -Path $transactionDirectory -ChildPath 'gitignore'
    [System.IO.File]::Copy($GradlewPath, $stagedGradlewPath, $true)
    [System.IO.File]::Copy($GradlewBatPath, $stagedGradlewBatPath, $true)
    if (Test-Path -LiteralPath $GitignorePath -PathType Leaf) {
      [System.IO.File]::Copy($GitignorePath, $stagedGitignorePath, $true)
    } else {
      Set-BuildishUtf8NoBomFileText -Path $stagedGitignorePath -Content ''
    }
    Install-BuildishHelperFiles -DestinationDirectory $transactionDirectory

    Add-BuildishBlockAfterAnyAnchor -Path $stagedGradlewPath -InsertionBlock '. "${APP_HOME}/gradle/buildish-no-gradle-wrapper-jar.sh"' -Label 'gradlew' -Anchors @($GradlewCurrentAnchor, $GradlewOldAnchor)
    Update-BuildishGradlewBat -Path $stagedGradlewBatPath
    Update-BuildishGitignore -Path $stagedGitignorePath

    $transactionEntries = @(
      [pscustomobject]@{ Destination = $HelperShPath; Stage = (Join-Path -Path $transactionDirectory -ChildPath 'buildish-no-gradle-wrapper-jar.sh'); Backup = (Join-Path -Path $transactionDirectory -ChildPath 'backup.helper-sh'); Existed = $false; Prepared = $false },
      [pscustomobject]@{ Destination = $HelperPs1Path; Stage = (Join-Path -Path $transactionDirectory -ChildPath 'buildish-no-gradle-wrapper-jar.ps1'); Backup = (Join-Path -Path $transactionDirectory -ChildPath 'backup.helper-ps1'); Existed = $false; Prepared = $false },
      [pscustomobject]@{ Destination = $GradleInitScriptPath; Stage = (Join-Path -Path $transactionDirectory -ChildPath 'buildish-no-gradle-wrapper-jar.init.gradle.kts'); Backup = (Join-Path -Path $transactionDirectory -ChildPath 'backup.helper-init'); Existed = $false; Prepared = $false },
      [pscustomobject]@{ Destination = $GradlewPath; Stage = $stagedGradlewPath; Backup = (Join-Path -Path $transactionDirectory -ChildPath 'backup.gradlew'); Existed = $false; Prepared = $false },
      [pscustomobject]@{ Destination = $GradlewBatPath; Stage = $stagedGradlewBatPath; Backup = (Join-Path -Path $transactionDirectory -ChildPath 'backup.gradlew-bat'); Existed = $false; Prepared = $false },
      [pscustomobject]@{ Destination = $GitignorePath; Stage = $stagedGitignorePath; Backup = (Join-Path -Path $transactionDirectory -ChildPath 'backup.gitignore'); Existed = $false; Prepared = $false },
      [pscustomobject]@{ Destination = $GradleWrapperJarPath; Stage = $null; Backup = (Join-Path -Path $transactionDirectory -ChildPath 'backup.wrapper-jar'); Existed = $false; Prepared = $false }
    )

    $transactionActive = $true
    Backup-BuildishInstallTransaction -Entries $transactionEntries
    Publish-BuildishInstallTransaction -Entries $transactionEntries
    $transactionActive = $false
  } catch {
    if ($transactionActive) {
      Restore-BuildishInstallTransaction -Entries $transactionEntries
    }
    throw
  } finally {
    Remove-Item -LiteralPath $transactionDirectory -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host "$BuildishToolName install: Installed helper files into '$GradleDirectory' and updated launcher scripts in '$TargetDirectoryAbsolute'."
} catch {
  Write-Error "$BuildishToolName install: $($_.Exception.Message)"
  exit 1
}
