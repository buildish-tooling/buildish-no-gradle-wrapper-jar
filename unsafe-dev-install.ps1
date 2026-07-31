<#!
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

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Tool = 'buildish-no-gradle-wrapper-jar unsafe-dev-install'
$DefaultBaseUrl = 'https://raw.githubusercontent.com/buildish-tooling/buildish/main/tools/buildish-no-gradle-wrapper-jar'
$BaseUrl = if ([string]::IsNullOrWhiteSpace($env:BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL)) { $DefaultBaseUrl } else { $env:BUILDISH_UNSAFE_DEV_INSTALL_BASE_URL }
$Files = @('install.ps1', 'buildish-no-gradle-wrapper-jar.sh', 'buildish-no-gradle-wrapper-jar.ps1', 'buildish-no-gradle-wrapper-jar.init.gradle.kts')

function Show-Usage {
  Write-Host @'
Usage: unsafe-dev-install.ps1 --yes-i-know-this-is-unsafe [target-project-directory]

Download and execute unverified helper files from the current development
branch. This shortcut is unsafe and is not suitable for CI or environments
with secrets.

Options:
  --yes-i-know-this-is-unsafe  Required acknowledgement of the execution risk.
  -h, --help                   Show this help and exit without downloading.
'@
}

function Get-CiMarker {
  foreach ($marker in @('CI', 'GITHUB_ACTIONS', 'GITLAB_CI', 'JENKINS_URL', 'JENKINS_HOME', 'BUILDKITE', 'TEAMCITY_VERSION', 'CIRCLECI', 'TRAVIS', 'TF_BUILD', 'BITBUCKET_BUILD_NUMBER', 'APPVEYOR', 'DRONE', 'SYSTEM_COLLECTIONURI')) {
    $value = [System.Environment]::GetEnvironmentVariable($marker)
    if ($marker -eq 'CI') {
      if ([string]::IsNullOrWhiteSpace($value)) {
        continue
      }
      if (@('0', 'false', 'no') -contains $value.Trim().ToLowerInvariant()) {
        continue
      }
      return $marker
    }
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $marker
    }
  }

  return ''
}

if ($args.Count -ge 1 -and @('-h', '--help') -contains $args[0]) {
  Show-Usage
  exit 0
}

if ($args.Count -eq 0 -or $args[0] -ne '--yes-i-know-this-is-unsafe') {
  Write-Error "${Tool}: Refusing to run without --yes-i-know-this-is-unsafe. This script downloads and executes unverified content from the current development branch and is not suitable for CI, automation, or secret-bearing environments."
  exit 1
}

if ($args.Count -gt 2) {
  Write-Error "${Tool}: Expected the unsafe acknowledgement flag followed by zero or one positional argument: the target project directory."
  exit 1
}

$ciMarker = Get-CiMarker
if (-not [string]::IsNullOrWhiteSpace($ciMarker)) {
  Write-Error "${Tool}: Refusing to run because the CI marker '$ciMarker' is set. This script is not suitable for CI environments, automation, or secret-bearing environments."
  exit 1
}

Write-Warning (@"
${Tool}: This script downloads and executes unverified content from the current development branch.
${Tool}: Use it only when you intentionally trust the current branch contents.
${Tool}: It is not suitable for CI, automation, or environments with secrets.
"@).TrimEnd()

$targetDirectory = if ($args.Count -eq 2 -and -not [string]::IsNullOrWhiteSpace($args[1])) { $args[1] } else { (Get-Location).Path }
$temporaryDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "buildish-no-gradle-wrapper-jar-unsafe-dev-install.$([System.Guid]::NewGuid().ToString('N'))"

try {
  New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
  foreach ($fileName in $Files) {
    $targetPath = Join-Path -Path $temporaryDirectory -ChildPath $fileName
    try {
      Invoke-WebRequest -Uri "$BaseUrl/$fileName" -OutFile $targetPath | Out-Null
    } catch {
      Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
      throw "Unable to download '$fileName' from '$BaseUrl/$fileName'."
    }
  }

  & (Join-Path -Path $temporaryDirectory -ChildPath 'install.ps1') --trusted-source-dir $temporaryDirectory $targetDirectory
  exit $LASTEXITCODE
} catch {
  Write-Error "${Tool}: $($_.Exception.Message)"
  exit 1
} finally {
  Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
