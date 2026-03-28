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

function Invoke-BuildishLifecycleSuite {
  $lifecycleGradleUserHome = $script:SharedGradleUserHome

  foreach ($installedCase in @($script:Manifest.installedGradleCases)) {
    $installed = [string]$installedCase.installedVersion
    $target = [string]$installedCase.targetVersion
    Invoke-BuildishCase -Name "lifecycle-installed-$installed-target-$target" -Body {
      param($caseDirectory)

      $consumer = New-BuildishConsumer `
        -Directory (Join-Path $caseDirectory 'installed Gradle consumer') `
        -BootstrapVersion $installed `
        -TargetVersion $target
      if ($installed -ceq '8.14.5' -and $target -ceq '9.6.1') {
        Remove-Item -LiteralPath (Join-Path $consumer 'gradlew.bat') -Force
      } elseif ($installed -ceq '9.6.1' -and $target -ceq '8.14.5') {
        Remove-Item -LiteralPath (Join-Path $consumer 'gradlew') -Force
      } elseif ($installed -ceq '9.6.1' -and $target -ceq '9.6.1') {
        Remove-Item -LiteralPath (Join-Path $consumer 'gradlew') -Force
        Remove-Item -LiteralPath (Join-Path $consumer 'gradlew.bat') -Force
      }
      Copy-Item `
        -LiteralPath (Get-BuildishWrapperPayload -Version $installed) `
        -Destination (Join-Path $consumer 'gradle\wrapper\gradle-wrapper.jar')
      [void](Invoke-BuildishAdoption `
        -ConsumerDirectory $consumer `
        -ExecutingVersion $installed `
        -TargetVersion $target `
        -CaseDirectory $caseDirectory `
        -GradleUserHome $lifecycleGradleUserHome)
      if ($installed -ceq '8.14.5' -and $target -ceq '9.6.1') {
        if (Test-Path -LiteralPath (Join-Path $consumer 'gradlew.bat')) {
          throw 'POSIX-only adoption published an unwanted Windows launcher.'
        }
      } elseif ($installed -ceq '9.6.1' -and $target -ceq '8.14.5') {
        if (Test-Path -LiteralPath (Join-Path $consumer 'gradlew')) {
          throw 'Windows-only adoption published an unwanted POSIX launcher.'
        }
      } elseif ($installed -ceq '9.6.1' -and $target -ceq '9.6.1') {
        foreach ($launcher in @('gradlew', 'gradlew.bat')) {
          if (-not (Test-Path -LiteralPath (Join-Path $consumer $launcher) -PathType Leaf)) {
            throw "Initial adoption did not publish $launcher."
          }
        }
        $paths = @(
          (Join-Path $consumer 'gradlew'),
          (Join-Path $consumer 'gradlew.bat'),
          (Join-Path $consumer 'gradle\wrapper\gradle-wrapper.properties'),
          (Join-Path $consumer 'gradle\wrapper\gradle-wrapper.jar')
        )
        $before = @{}
        foreach ($path in $paths) {
          $before[$path] = Get-BuildishSha256 -Path $path
        }
        $rerun = Invoke-BuildishStableBatchCopy `
          -ProjectDirectory $consumer `
          -LauncherArguments @('--daemon', '--rerun-tasks', ':wrapper') `
          -GradleUserHome $lifecycleGradleUserHome `
          -TimeoutSeconds 360
        Assert-BuildishExitCode -Result $rerun -ExpectedExitCode 0 -Label 'same-version regeneration'
        foreach ($path in $paths) {
          if ((Get-BuildishSha256 -Path $path) -cne $before[$path]) {
            throw "Same-version regeneration changed $path."
          }
        }
        Invoke-BuildishLauncherContract `
          -ConsumerDirectory $consumer `
          -CaseDirectory $caseDirectory
      }
    }
  }


  Invoke-BuildishCase -Name 'lifecycle-root-scope-and-ordinary-build-modes' -Body {
    param($caseDirectory)

    $consumer = New-BuildishConsumer `
      -Directory (Join-Path $caseDirectory 'scoped consumer') `
      -BootstrapVersion '9.6.1' `
      -TargetVersion '9.6.1'
    Copy-Item `
      -LiteralPath (Get-BuildishWrapperPayload -Version '9.6.1') `
      -Destination (Join-Path $consumer 'gradle\wrapper\gradle-wrapper.jar')
    $included = New-BuildishConsumer `
      -Directory (Join-Path $consumer 'included') `
      -BootstrapVersion '9.6.1' `
      -TargetVersion '9.6.1'
    [System.IO.File]::WriteAllText(
      (Join-Path $included 'settings.gradle.kts'),
      "rootProject.name = `"included`"`r`n",
      [System.Text.UTF8Encoding]::new($false)
    )
    $includedBuild = @'
import org.gradle.api.tasks.wrapper.Wrapper

tasks.named<Wrapper>("wrapper") {
    doLast {
        layout.projectDirectory.file("included-wrapper-ran.marker").asFile.writeText(path)
    }
}
'@
    [System.IO.File]::WriteAllText(
      (Join-Path $included 'build.gradle.kts'),
      $includedBuild.Replace("`n", "`r`n"),
      [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
      (Join-Path $consumer 'settings.gradle.kts'),
      "rootProject.name = `"buildish-windows-test`"`r`nincludeBuild(`"included`")`r`n",
      [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
      (Join-Path $consumer 'build.gradle.kts'),
      "import org.gradle.api.tasks.wrapper.Wrapper`r`n`r`ntasks.register<Wrapper>(`"extraWrapper`")`r`n",
      [System.Text.UTF8Encoding]::new($false)
    )

    $buildSrc = Join-Path $consumer 'buildSrc'
    New-Item -ItemType Directory -Path $buildSrc -Force | Out-Null
    [System.IO.File]::WriteAllText(
      (Join-Path $buildSrc 'build.gradle.kts'),
      @'
import org.gradle.api.tasks.wrapper.Wrapper

tasks.named<Wrapper>("wrapper") {
    doLast {
        layout.projectDirectory.file("buildsrc-wrapper-ran.marker").asFile.writeText(path)
    }
}
tasks.named("jar") {
    dependsOn("wrapper")
}
'@.Replace("`n", "`r`n"),
      [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
      (Join-Path $buildSrc 'settings.gradle.kts'),
      "rootProject.name = `"buildSrc-scope-test`"`r`n",
      [System.Text.UTF8Encoding]::new($false)
    )

    $gradleHome = Get-BuildishGradleHome `
      -Version '9.6.1' `
      -CaseDirectory $caseDirectory
    $init = Join-Path $consumer 'gradle\buildish-wrapper.init.gradle.kts'

    $includedResult = Invoke-BuildishGradleBatch `
      -GradleBatch (Join-Path $gradleHome 'bin\gradle.bat') `
      -ProjectDirectory $consumer `
      -Arguments @(
        '--daemon',
        '--init-script',
        $init,
        '--rerun-tasks',
        ':included:wrapper',
        'extraWrapper'
      ) `
      -GradleUserHome $lifecycleGradleUserHome `
      -TimeoutSeconds 300
    Assert-BuildishExitCode `
      -Result $includedResult `
      -ExpectedExitCode 0 `
      -Label 'noncanonical Wrapper task scope'
    if (-not (Test-Path -LiteralPath (Join-Path $included 'included-wrapper-ran.marker'))) {
      throw 'Included-build Wrapper task did not execute.'
    }
    Assert-BuildishUnpatchedWrapperOutputs -ProjectDirectory $included
    Assert-BuildishUnpatchedWrapperOutputs -ProjectDirectory $consumer

    $ordinaryArguments = @(
      '--daemon',
      '--init-script',
      $init,
      'help',
      '--configuration-cache',
      '--configuration-cache-problems=fail'
    )
    $first = Invoke-BuildishGradleBatch `
      -GradleBatch (Join-Path $gradleHome 'bin\gradle.bat') `
      -ProjectDirectory $consumer `
      -Arguments $ordinaryArguments `
      -GradleUserHome $lifecycleGradleUserHome `
      -TimeoutSeconds 300
    Assert-BuildishExitCode -Result $first -ExpectedExitCode 0 -Label 'configuration-cache first run'
    $second = Invoke-BuildishGradleBatch `
      -GradleBatch (Join-Path $gradleHome 'bin\gradle.bat') `
      -ProjectDirectory $consumer `
      -Arguments $ordinaryArguments `
      -GradleUserHome $lifecycleGradleUserHome `
      -TimeoutSeconds 300
    Assert-BuildishExitCode -Result $second -ExpectedExitCode 0 -Label 'configuration-cache reuse run'
    if (($second.StandardOutput + $second.StandardError) -notmatch 'Reusing configuration cache') {
      throw 'Second ordinary build did not report configuration-cache reuse.'
    }
    $isolated = Invoke-BuildishGradleBatch `
      -GradleBatch (Join-Path $gradleHome 'bin\gradle.bat') `
      -ProjectDirectory $consumer `
      -Arguments @(
        '--daemon',
        '--init-script',
        $init,
        '-Dorg.gradle.unsafe.isolated-projects=true',
        'help'
      ) `
      -GradleUserHome $lifecycleGradleUserHome `
      -TimeoutSeconds 300
    Assert-BuildishExitCode -Result $isolated -ExpectedExitCode 0 -Label 'isolated-projects ordinary build'
    if (-not (Test-Path -LiteralPath (Join-Path $buildSrc 'buildsrc-wrapper-ran.marker'))) {
      throw 'The buildSrc Wrapper scope fixture did not execute.'
    }
    Assert-BuildishUnpatchedWrapperOutputs -ProjectDirectory $buildSrc

    $wrapperCacheArguments = @(
      '--daemon',
      '--init-script',
      $init,
      '--configuration-cache',
      '--configuration-cache-problems=fail',
      '--rerun-tasks',
      ':wrapper'
    )
    $wrapperCacheHome = $lifecycleGradleUserHome
    $wrapperCacheFirst = Invoke-BuildishGradleBatch `
      -GradleBatch (Join-Path $gradleHome 'bin\gradle.bat') `
      -ProjectDirectory $consumer `
      -Arguments $wrapperCacheArguments `
      -GradleUserHome $wrapperCacheHome `
      -TimeoutSeconds 300
    Assert-BuildishExitCode `
      -Result $wrapperCacheFirst `
      -ExpectedExitCode 0 `
      -Label 'explicit Wrapper configuration-cache first run'
    $wrapperCacheReuse = Invoke-BuildishGradleBatch `
      -GradleBatch (Join-Path $gradleHome 'bin\gradle.bat') `
      -ProjectDirectory $consumer `
      -Arguments $wrapperCacheArguments `
      -GradleUserHome $wrapperCacheHome `
      -TimeoutSeconds 300
    Assert-BuildishExitCode `
      -Result $wrapperCacheReuse `
      -ExpectedExitCode 0 `
      -Label 'explicit Wrapper configuration-cache reuse run'
    if (($wrapperCacheReuse.StandardOutput + $wrapperCacheReuse.StandardError) -notmatch
        'Reusing configuration cache') {
      throw 'Second explicit Wrapper run did not report configuration-cache reuse.'
    }
    Invoke-BuildishLauncherContract `
      -ConsumerDirectory $consumer `
      -CaseDirectory $caseDirectory

  }
}
