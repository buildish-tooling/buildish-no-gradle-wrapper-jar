/*
 * Copyright 2026 The Buildish Authors
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
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import org.gradle.api.GradleException
import org.gradle.api.tasks.wrapper.Wrapper

/*
 * Buildish no-gradle-wrapper-jar helper init script.
 * https://buildish.org/components/no-gradle-wrapper-jar/
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
val buildishWrapperJarSha256Property = "buildishWrapperJarSha256Sum"

// Preserve the target file's original newline style so Gradle keeps emitting the
// script format expected on each platform.
fun newlineFor(content: String): String = if (content.contains("\r\n")) "\r\n" else "\n"

fun normalizeForFile(text: String, newline: String): String = text.lines().joinToString(newline)

fun hasConfiguredProperty(line: String, key: String): Boolean {
  val normalizedLine = line.removeSuffix("\r")
  if (!normalizedLine.startsWith("$key=")) return false
  return normalizedLine.substringAfter('=', "").isNotBlank()
}

fun requireSinglePropertyValue(propertiesFile: File, key: String): String {
  val values =
    propertiesFile.readLines().filter { line -> line.startsWith("$key=") }.map { line -> line.substringAfter('=') }
  if (values.isEmpty()) {
    throw GradleException("'${propertiesFile.absolutePath}' is missing the required $key entry.")
  }
  if (values.size != 1) {
    throw GradleException("'${propertiesFile.absolutePath}' contains duplicate $key entries.")
  }
  return values.single()
}

fun requireBuildishWrapperJarSha256(propertiesFile: File): String {
  val value = requireSinglePropertyValue(propertiesFile, buildishWrapperJarSha256Property)
  if (!value.matches(Regex("[0-9a-f]{64}"))) {
    throw GradleException(
      "$buildishWrapperJarSha256Property must be exactly one lowercase 64-character SHA-256 value in '${propertiesFile.absolutePath}'.",
    )
  }
  return value
}

// Gradle's Wrapper task rewrites gradle-wrapper.properties and drops unknown
// project-owned keys. Reinsert the already-reviewed digest without deriving or
// downloading a replacement, preserving the file's newline convention.
fun contentWithSingleProperty(content: String, key: String, value: String): String {
  val newline = newlineFor(content)
  val hasTrailingNewline = content.endsWith("\n") || content.endsWith("\r")
  val lines = content.split(Regex("\\r?\\n")).toMutableList()
  if (hasTrailingNewline && lines.lastOrNull().isNullOrEmpty()) lines.removeLast()
  val retainedLines = lines.filterNot { line -> line.startsWith("$key=") }
  return (retainedLines + "$key=$value").joinToString(newline) + if (hasTrailingNewline) newline else ""
}

// Insert one block immediately after any supported anchor line unless it is
// already present. The operation is intentionally idempotent because the helper
// may run the wrapper task multiple times in the same project.
fun contentAfterAnyAnchor(
  content: String,
  target: File,
  anchors: List<String>,
  insertion: String,
  label: String,
): String {
  val newline = newlineFor(content)
  val normalizedInsertion = normalizeForFile(insertion, newline)
  if (content.contains(normalizedInsertion)) return content
  for (anchor in anchors) {
    val anchorWithNewline = "$anchor$newline"
    val updated =
      when {
        content.contains(anchorWithNewline) ->
          content.replace(anchorWithNewline, "$anchor$newline$normalizedInsertion$newline")
        content.endsWith(anchor) -> content.dropLast(anchor.length) + "$anchor$newline$normalizedInsertion"
        else -> continue
      }
    return updated
  }
  throw GradleException("Unable to find the expected insertion point in $label at '${target.absolutePath}'.")
}

// Replace the exact generated Java invocation line with the helper-aware version.
// Multiple historical launcher shapes are supported so the tool can span several
// Gradle minor lines without guessing which batch format was generated.
fun contentAfterAnyExactLineReplacement(
  content: String,
  target: File,
  replacements: List<Pair<String, String>>,
  label: String,
): String {
  val newline = newlineFor(content)
  for ((_, replacement) in replacements) {
    val normalizedReplacement = normalizeForFile(replacement, newline)
    if (content.contains(normalizedReplacement)) return content
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
    return updated
  }
  throw GradleException("Unable to find the expected replacement point in $label at '${target.absolutePath}'.")
}

fun requireOrdinaryFile(target: File, label: String) {
  val path = target.toPath()
  if (Files.isSymbolicLink(path) || !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
    throw GradleException("$label must be an ordinary file at '${target.absolutePath}'.")
  }
}

fun moveReplacing(source: Path, target: Path) {
  try {
    Files.move(source, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
  } catch (_: AtomicMoveNotSupportedException) {
    Files.move(source, target, StandardCopyOption.REPLACE_EXISTING)
  }
}

fun restoreFileBackups(
  backupPaths: List<Path>,
  updates: List<Pair<File, String>>,
  publicationFailure: Exception,
) {
  for (index in updates.indices) {
    val rollbackResult = runCatching { moveReplacing(backupPaths[index], updates[index].first.toPath()) }
    rollbackResult.exceptionOrNull()?.also(publicationFailure::addSuppressed)
  }
}

// Publish the properties file and both launchers as one rollback-capable
// operation. Each replacement is staged beside its destination, and all
// originals are copied before the first move so a late failure cannot split the
// wrapper configuration from its launcher patches.
fun publishFileUpdates(updates: List<Pair<File, String>>) {
  val stagedPaths = mutableListOf<Path>()
  val backupPaths = mutableListOf<Path>()

  try {
    for ((target, updatedContent) in updates) {
      val targetPath = target.toPath()
      val parent = targetPath.parent
      val stagedPath = Files.createTempFile(parent, ".buildish-no-gradle-wrapper-jar-stage.", ".tmp")
      Files.copy(targetPath, stagedPath, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.COPY_ATTRIBUTES)
      Files.write(stagedPath, updatedContent.toByteArray(StandardCharsets.UTF_8), StandardOpenOption.WRITE, StandardOpenOption.TRUNCATE_EXISTING)
      stagedPaths.add(stagedPath)

      val backupPath = Files.createTempFile(parent, ".buildish-no-gradle-wrapper-jar-backup.", ".tmp")
      Files.copy(targetPath, backupPath, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.COPY_ATTRIBUTES)
      backupPaths.add(backupPath)
    }

    try {
      updates.indices.forEach { index -> moveReplacing(stagedPaths[index], updates[index].first.toPath()) }
    } catch (publicationFailure: Exception) {
      restoreFileBackups(backupPaths, updates, publicationFailure)
      throw GradleException("Unable to publish patched Gradle wrapper files; original files were restored where possible.", publicationFailure)
    }
  } finally {
    stagedPaths.forEach { path -> runCatching { Files.deleteIfExists(path) } }
    backupPaths.forEach { path -> runCatching { Files.deleteIfExists(path) } }
  }
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

fun patchGeneratedWrapperFiles(wrapperTask: Wrapper, preservedWrapperJarSha256: String): String {
  val scriptFile = wrapperTask.scriptFile
  val batchScript = wrapperTask.batchScript
  val propertiesFile = wrapperTask.jarFile.parentFile.resolve("gradle-wrapper.properties")
  requireOrdinaryFile(propertiesFile, "gradle-wrapper.properties")
  requireOrdinaryFile(scriptFile, "gradlew")
  requireOrdinaryFile(batchScript, "gradlew.bat")

  val propertiesContent = propertiesFile.readText()
  val unixContent = scriptFile.readText()
  val batchContent = batchScript.readText()
  val generatedDistributionUrl = requireSinglePropertyValue(propertiesFile, "distributionUrl")
  val updatedPropertiesContent =
    contentWithSingleProperty(
      propertiesContent,
      buildishWrapperJarSha256Property,
      preservedWrapperJarSha256,
    )
  val updatedUnixContent =
    contentAfterAnyAnchor(unixContent, scriptFile, unixAnchors, unixInsertion, "gradlew")
  val batchContentWithHelper =
    contentAfterAnyAnchor(batchContent, batchScript, listOf(batchAnchor), batchHelperBlock, "gradlew.bat")
  val updatedBatchContent =
    contentAfterAnyExactLineReplacement(
      batchContentWithHelper,
      batchScript,
      batchExecuteLineReplacements,
      "gradlew.bat",
    )

  publishFileUpdates(
    listOf(
      propertiesFile to updatedPropertiesContent,
      scriptFile to updatedUnixContent,
      batchScript to updatedBatchContent,
    ),
  )
  return generatedDistributionUrl
}

data class WrapperConfigurationBeforeExecution(
  val wrapperJarSha256: String,
  val distributionUrl: String,
)

fun readWrapperConfigurationBeforeExecution(wrapperTask: Wrapper): WrapperConfigurationBeforeExecution {
  val propertiesFile = wrapperTask.jarFile.parentFile.resolve("gradle-wrapper.properties")
  requireOrdinaryFile(propertiesFile, "gradle-wrapper.properties")
  return WrapperConfigurationBeforeExecution(
    wrapperJarSha256 = requireBuildishWrapperJarSha256(propertiesFile),
    distributionUrl = requireSinglePropertyValue(propertiesFile, "distributionUrl"),
  )
}

fun completeWrapperTask(wrapperTask: Wrapper, previousConfiguration: WrapperConfigurationBeforeExecution?) {
  val requiredPreviousConfiguration =
    previousConfiguration
      ?: throw GradleException("Unable to preserve the reviewed Gradle wrapper configuration before the Wrapper task.")
  val generatedDistributionUrl =
    patchGeneratedWrapperFiles(wrapperTask, requiredPreviousConfiguration.wrapperJarSha256)
  warnIfDistributionSha256SumMissing(wrapperTask)
  if (generatedDistributionUrl != requiredPreviousConfiguration.distributionUrl) {
    wrapperTask.logger.warn(
      """
      ==============================================================================
      Buildish helper warning: distributionUrl changed, but
      $buildishWrapperJarSha256Property was only preserved; it was not recalculated.
      Replace it with the reviewed Gradle wrapper JAR SHA-256 for the new version
      before the next gradlew / gradlew.bat invocation.
      ==============================================================================
      """.trimIndent(),
    )
  }
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
      var configurationBeforeExecution: WrapperConfigurationBeforeExecution? = null
      notCompatibleWithConfigurationCache("Patches generated launcher scripts after the Wrapper task writes them.")
      doFirst { configurationBeforeExecution = readWrapperConfigurationBeforeExecution(wrapperTask) }
      doLast { completeWrapperTask(wrapperTask, configurationBeforeExecution) }
    }
  }
}
