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
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $repositoryRoot 'tests\windows\lib\tool-fixtures.ps1')

$testRoot = Join-Path $repositoryRoot (
  'build\windows-unit\python-resolution-' + [System.Guid]::NewGuid().ToString('N')
)
$firstDirectory = Join-Path $testRoot 'first'
$secondDirectory = Join-Path $testRoot 'second'
$originalPath = $env:PATH

try {
  New-Item -ItemType Directory -Path $firstDirectory, $secondDirectory -Force | Out-Null
  $currentExecutable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  Copy-Item -LiteralPath $currentExecutable -Destination (Join-Path $firstDirectory 'python.exe')
  Copy-Item -LiteralPath $currentExecutable -Destination (Join-Path $secondDirectory 'python.exe')

  $separator = [System.IO.Path]::PathSeparator
  $env:PATH = $firstDirectory + $separator + $secondDirectory
  $commands = @(Get-Command `
      -Name 'python.exe' `
      -CommandType Application `
      -ErrorAction SilentlyContinue)
  if ($commands.Count -ne 2) {
    throw "Python resolution fixture expected two candidates, found $($commands.Count)."
  }

  $actual = Get-BuildishPythonPath
  if ($actual -isnot [string]) {
    throw "Python resolution returned $($actual.GetType().FullName), expected System.String."
  }
  if (-not $actual.Equals(
      [string]$commands[0].Source,
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Python resolution selected '$actual', expected '$($commands[0].Source)'."
  }
} finally {
  $env:PATH = $originalPath
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'windows-unit: fixture application resolution passed'
