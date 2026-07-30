/*
 * Copyright 2026 The Apache Software Foundation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import java.io.File
import org.gradle.api.GradleException
import org.gradle.api.tasks.wrapper.Wrapper

/*
 * Apache Buildish no-gradle-wrapper-jar helper init script.
 * https://buildish.apache.org/components/no-gradle-wrapper-jar/
 *
 * This init script is added to Gradle invocations by the shell/PowerShell helpers.
 * Its only job is to keep the helper installed after `./gradlew wrapper ...`
 * regenerates `gradlew` and `gradlew.bat`.
 *
 * Relationship between the files in this tool directory:
 *   - install.sh / install.ps1 copy the helper files into the target project and
 *     patch the generated launchers once.
 *   - buildish-no-gradle-wrapper-jar.sh / .ps1 ensure `gradle-wrapper.jar` exists
 *     and prepend this init script on every launcher run.
 *   - this init script hooks the `Wrapper` task so a later wrapper upgrade keeps
 *     the launcher patches instead of silently discarding them.
 *
 * The patch operations are deliberately exact-string based. That makes the helper
 * easier to audit and lets integration tests catch when new Gradle versions change
 * launcher shapes in ways that require explicit support.
 */

// Known insertion / replacement anchors in Gradle-generated launcher scripts.
// Gradle 8.1.x still emits a classpath/main-class batch launcher, some later 8.x
// versions switched to `-classpath ... -jar ...`, and current releases use a
// direct `-jar ...` invocation.
val currentUnixAnchor =
  """APP_HOME=$( cd -P "${'$'}{APP_HOME:-./}" > /dev/null && printf '%s\n' "${'$'}PWD" ) || exit"""
val oldUnixAnchor =
  """APP_HOME=$( cd "${'$'}{APP_HOME:-./}" && pwd -P ) || exit"""
val unixInsertion = ". \"${'$'}{APP_HOME}/gradle/buildish-no-gradle-wrapper-jar.sh\""
val unixAnchors = listOf(currentUnixAnchor, oldUnixAnchor)
val batchAnchor = "for %%i in (\"%APP_HOME%\") do set APP_HOME=%%~fi"
val batchHelperCommand =
  "powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"%APP_HOME%\\gradle\\buildish-no-gradle-wrapper-jar.ps1\""
val batchHelperBlock =
  """
  set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=%*
  set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=
  for /f "delims=" %%a in ('$batchHelperCommand') do @set BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS=%%a
  set BUILDISH_NO_GRADLE_WRAPPER_JAR_ORIGINAL_ARGS=
  if errorlevel 1 goto fail
  """.trimIndent()
val batchExecuteLines =
  listOf(
    "\"%JAVA_EXE%\" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% \"-Dorg.gradle.appname=%APP_BASE_NAME%\" -classpath \"%CLASSPATH%\" org.gradle.wrapper.GradleWrapperMain %*",
    "\"%JAVA_EXE%\" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% \"-Dorg.gradle.appname=%APP_BASE_NAME%\" -classpath \"%CLASSPATH%\" -jar \"%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar\" %*",
    "\"%JAVA_EXE%\" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% \"-Dorg.gradle.appname=%APP_BASE_NAME%\" -jar \"%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar\" %*",
    "endlocal & \"%JAVA_EXE%\" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% \"-Dorg.gradle.appname=%APP_BASE_NAME%\" -jar \"%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar\" %* & call :exitWithErrorLevel",
  )

fun patchBatchExecuteLine(currentLine: String): String {
  val argumentMarker = " %*"
  val argumentIndex = currentLine.indexOf(argumentMarker)
  require(
    argumentIndex >= 0 && currentLine.indexOf(argumentMarker, argumentIndex + argumentMarker.length) < 0
  ) {
    "Unsupported batch execute line shape: '$currentLine'"
  }
  return currentLine.substring(0, argumentIndex) +
    " %BUILDISH_NO_GRADLE_WRAPPER_JAR_ARGS%" +
    currentLine.substring(argumentIndex)
}

val batchExecuteLineReplacements =
  batchExecuteLines.map { currentLine -> currentLine to patchBatchExecuteLine(currentLine) }

// Preserve the target file's original newline style so Gradle keeps emitting the
// script format expected on each platform.
fun newlineFor(content: String): String = if (content.contains("\r\n")) "\r\n" else "\n"

fun normalizeForFile(text: String, newline: String): String = text.lines().joinToString(newline)

fun hasConfiguredProperty(line: String, key: String): Boolean {
  val normalizedLine = line.removeSuffix("\r")
  if (!normalizedLine.startsWith("$key=")) return false
  return normalizedLine.substringAfter('=', "").isNotBlank()
}

// Insert one block immediately after any supported anchor line unless it is
// already present. The operation is intentionally idempotent because the helper
// may run the wrapper task multiple times in the same project.
fun patchAfterAnyAnchor(target: File, anchors: List<String>, insertion: String, label: String) {
  val content = target.readText()
  val newline = newlineFor(content)
  val normalizedInsertion = normalizeForFile(insertion, newline)
  if (content.contains(normalizedInsertion)) return
  for (anchor in anchors) {
    val anchorWithNewline = "$anchor$newline"
    val updated =
      when {
        content.contains(anchorWithNewline) ->
          content.replace(anchorWithNewline, "$anchor$newline$normalizedInsertion$newline")
        content.endsWith(anchor) -> content.dropLast(anchor.length) + "$anchor$newline$normalizedInsertion"
        else -> continue
      }
    target.writeText(updated)
    return
    }
  throw GradleException("Unable to find the expected insertion point in $label at '${target.absolutePath}'.")
}

// Replace the exact generated Java invocation line with the helper-aware version.
// Multiple historical launcher shapes are supported so the tool can span several
// Gradle minor lines without guessing which batch format was generated.
fun replaceAnyExactLine(target: File, replacements: List<Pair<String, String>>, label: String) {
  val content = target.readText()
  val newline = newlineFor(content)
  for ((_, replacement) in replacements) {
    val normalizedReplacement = normalizeForFile(replacement, newline)
    if (content.contains(normalizedReplacement)) return
  }
  for ((currentLine, replacement) in replacements) {
    val normalizedReplacement = normalizeForFile(replacement, newline)
    val currentLineWithNewline = "$currentLine$newline"
    val replacementWithNewline = "$normalizedReplacement$newline"
    val updated =
      when {
        content.contains(currentLineWithNewline) -> content.replace(currentLineWithNewline, replacementWithNewline)
        content.endsWith(currentLine) -> content.dropLast(currentLine.length) + normalizedReplacement
        else -> continue
      }
    target.writeText(updated)
    return
  }
  throw GradleException("Unable to find the expected replacement point in $label at '${target.absolutePath}'.")
}

// Gradle's generated `gradle-wrapper.properties` often omits distributionSha256Sum
// unless a project or tool explicitly configures it. That omission weakens the
// wrapper-distribution trust story even though this helper still verifies the
// wrapper JAR itself, so emit a prominent reminder whenever the Wrapper task leaves
// the properties file without that checksum pin.
fun warnIfDistributionSha256SumMissing(wrapperTask: Wrapper) {
  val propertiesFile = wrapperTask.jarFile.parentFile.resolve("gradle-wrapper.properties")
  if (!propertiesFile.isFile) return
  val hasDistributionSha256Sum =
    propertiesFile.useLines { lines -> lines.any { line -> hasConfiguredProperty(line, "distributionSha256Sum") } }
  if (hasDistributionSha256Sum) return
  wrapperTask.logger.warn(
    """
    ==============================================================================
    Buildish helper warning: '${propertiesFile.absolutePath}' does not define
    distributionSha256Sum.
    Gradle will not pin the wrapper distribution ZIP checksum during wrapper
    downloads. This helper still verifies gradle-wrapper.jar, but not the
    distribution ZIP itself.
    ==============================================================================
    """.trimIndent(),
  )
}

// Init scripts are evaluated with a `Gradle` receiver rather than a project
// receiver, so the `Wrapper` hook is registered once the projects are loaded.
//
// The `doLast` patcher is intentionally marked incompatible with configuration
// cache because it reaches into generated launcher files after the task runs.
// That is preferable to a silent wrapper failure during upgrades.
gradle.projectsLoaded {
  rootProject {
    tasks.withType<Wrapper>().configureEach {
      val wrapperTask = this
      notCompatibleWithConfigurationCache("Patches generated launcher scripts after the Wrapper task writes them.")
      doLast {
        warnIfDistributionSha256SumMissing(wrapperTask)
        patchAfterAnyAnchor(scriptFile, unixAnchors, unixInsertion, "gradlew")
        patchAfterAnyAnchor(batchScript, listOf(batchAnchor), batchHelperBlock, "gradlew.bat")
        replaceAnyExactLine(batchScript, batchExecuteLineReplacements, "gradlew.bat")
      }
    }
  }
}
