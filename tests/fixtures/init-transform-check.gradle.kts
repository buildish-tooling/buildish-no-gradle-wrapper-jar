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

/*
 * This test-only appendix is added to a temporary copy of the product init
 * script after its terminal lifecycle registration is removed. It therefore
 * exercises the product script's actual imports, types, parsing, and text
 * transformations without adding a separately compiled product artifact.
 */

class BuildishConfigureTransformationFixtureAction(
    private val rootProjectDirectory: String,
) : Action<Task>, Serializable {
    override fun execute(task: Task) {
        task.doLast(BuildishRunTransformationFixtureAction(rootProjectDirectory))
    }
}

class BuildishRunTransformationFixtureAction(
    private val rootProjectDirectory: String,
) : Action<Task>, Serializable {
    override fun execute(task: Task) {
        val root = File(rootProjectDirectory)
        val transformer = BuildishFinalizeWrapperAction(rootProjectDirectory, true, true)
        val fixtureDigest = "a".repeat(64)
        val fixtureCases = listOf(
            "9.6.1" to root,
            "8.14.5" to File(root, "transformation-fixtures/8.14.5"),
        )
        for ((version, fixtureRoot) in fixtureCases) {
            val fixturePosix = transformer.readText(
                File(fixtureRoot, "gradlew"),
                StandardCharsets.UTF_8,
                "$version fixture POSIX launcher",
            )
            val fixtureWindows = transformer.readText(
                File(fixtureRoot, "gradlew.bat"),
                StandardCharsets.UTF_8,
                "$version fixture Windows launcher",
            )
            val fixtureProperties = transformer.readText(
                File(fixtureRoot, "gradle/wrapper/gradle-wrapper.properties"),
                StandardCharsets.ISO_8859_1,
                "$version fixture Wrapper properties",
            )

            val patchedPosix = transformer.patchPosix(fixturePosix)
            requireLineCount(patchedPosix, "# BEGIN BUILDISH WRAPPER BOOTSTRAP", 1)
            requireLineCount(
                patchedPosix,
                ". \"${'$'}APP_HOME/gradle/buildish-wrapper-bootstrap.sh\" || exit ${'$'}?",
                1,
            )
            requireNewlineContract(
                fixturePosix,
                patchedPosix,
                "\n",
                "$version POSIX launcher",
            )

            val patchedWindows = transformer.patchWindows(fixtureWindows)
            requireLineCount(patchedWindows, "@rem BEGIN BUILDISH WRAPPER BOOTSTRAP", 1)
            requireLineCount(patchedWindows, ":buildishWrapperReady", 1)
            val patchedInvocation = patchedWindows.lines.single {
                it.contains("-jar \"%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar\"")
            }
            require(patchedInvocation.contains(
                "--init-script \"%APP_HOME%\\gradle\\buildish-wrapper.init.gradle.kts\" %*",
            )) {
                "$version patched Windows invocation has no static init-script argument"
            }
            requireNewlineContract(
                fixtureWindows,
                patchedWindows,
                "\r\n",
                "$version Windows launcher",
            )

            val patchedProperties = transformer.patchProperties(
                fixtureProperties,
                version,
                fixtureDigest,
            )
            requireLineCount(patchedProperties, "buildishWrapperJarVersion=$version", 1)
            requireLineCount(
                patchedProperties,
                "buildishWrapperJarSha256Sum=$fixtureDigest",
                1,
            )
            requireNewlineContract(
                fixtureProperties,
                patchedProperties,
                "\n",
                "$version Wrapper properties",
            )
        }

        val posix = transformer.readText(
            File(root, "gradlew"),
            StandardCharsets.UTF_8,
            "fixture POSIX launcher",
        )
        val windows = transformer.readText(
            File(root, "gradlew.bat"),
            StandardCharsets.UTF_8,
            "fixture Windows launcher",
        )
        val properties = transformer.readText(
            File(root, "gradle/wrapper/gradle-wrapper.properties"),
            StandardCharsets.ISO_8859_1,
            "fixture Wrapper properties",
        )
        requireMissingFinalNewlinePreserved(
            transformer,
            root,
            "gradlew",
            posix,
            StandardCharsets.UTF_8,
            "\n",
        ) { transformer.patchPosix(it) }
        requireMissingFinalNewlinePreserved(
            transformer,
            root,
            "gradlew.bat",
            windows,
            StandardCharsets.UTF_8,
            "\r\n",
        ) { transformer.patchWindows(it) }

        val posixAnchor = posix.lines.single { it.startsWith("APP_HOME=${'$'}( cd -P ") }
        expectFailure("exactly one POSIX APP_HOME insertion anchor, found 0") {
            transformer.patchPosix(posix.withLines(posix.lines.filterNot { it == posixAnchor }))
        }
        expectFailure("exactly one POSIX APP_HOME insertion anchor, found 2") {
            transformer.patchPosix(posix.withLines(posix.lines + posixAnchor))
        }

        val windowsInvocation = windows.lines.single {
            it.contains("-jar \"%APP_HOME%\\gradle\\wrapper\\gradle-wrapper.jar\"") &&
                it.contains("%*")
        }
        expectFailure("expected exactly one supported Windows Java invocation, found 0") {
            transformer.patchWindows(
                windows.withLines(
                    windows.lines.map { it.replace("%DEFAULT_JVM_OPTS%", "%REMOVED_DEFAULT_JVM_OPTS%") },
                ),
            )
        }
        expectFailure("expected exactly one supported Windows Java invocation, found 2") {
            transformer.patchWindows(windows.withLines(windows.lines + windowsInvocation))
        }

        val distributionDigest = properties.lines.single {
            it.startsWith("distributionSha256Sum=")
        }
        expectFailure("exactly one distributionSha256Sum definition; found 0") {
            transformer.patchProperties(
                properties.withLines(properties.lines.filterNot { it == distributionDigest }),
                "9.6.1",
                fixtureDigest,
            )
        }
        expectFailure("exactly one distributionSha256Sum definition; found 2") {
            transformer.patchProperties(
                properties.withLines(properties.lines + distributionDigest),
                "9.6.1",
                fixtureDigest,
            )
        }
        expectFailure("distributionSha256Sum must be one canonical lowercase SHA-256 line") {
            transformer.patchProperties(
                properties.withLines(
                    properties.lines.map {
                        if (it == distributionDigest) {
                            it.replace("distributionSha256Sum=", " distributionSha256Sum:")
                        } else {
                            it
                        }
                    },
                ),
                "9.6.1",
                fixtureDigest,
            )
        }
        expectFailure("unsupported continued property") {
            transformer.patchProperties(
                properties.withLines(
                    properties.lines.flatMap {
                        if (it == distributionDigest) {
                            listOf("distributionSha256Sum=\\", " ${it.substringAfter('=')}")
                        } else {
                            listOf(it)
                        }
                    },
                ),
                "9.6.1",
                fixtureDigest,
            )
        }
    }

    private fun requireLineCount(content: BuildishTextContent, line: String, expected: Int) {
        val actual = content.lines.count { it == line }
        require(actual == expected) {
            "expected $expected fixture line(s) $line, found $actual"
        }
    }

    private fun requireNewlineContract(
        original: BuildishTextContent,
        patched: BuildishTextContent,
        newline: String,
        description: String,
    ) {
        val originalBytes = original.bytes()
        val patchedBytes = patched.bytes()
        val newlineBytes = newline.toByteArray(StandardCharsets.UTF_8)
        require(hasSuffix(originalBytes, newlineBytes) == hasSuffix(patchedBytes, newlineBytes)) {
            "$description changed its final-newline contract"
        }
        if (newline == "\r\n") {
            require(patchedBytes.indices.none { index ->
                patchedBytes[index] == '\n'.code.toByte() &&
                    (index == 0 || patchedBytes[index - 1] != '\r'.code.toByte())
            }) {
                "$description contains a bare LF after transformation"
            }
        } else {
            require(patchedBytes.none { it == '\r'.code.toByte() }) {
                "$description contains a CR after transformation"
            }
        }
    }

    private fun requireMissingFinalNewlinePreserved(
        transformer: BuildishFinalizeWrapperAction,
        root: File,
        name: String,
        original: BuildishTextContent,
        charset: Charset,
        newline: String,
        transform: (BuildishTextContent) -> BuildishTextContent,
    ) {
        val newlineBytes = newline.toByteArray(charset)
        val originalBytes = original.bytes()
        require(hasSuffix(originalBytes, newlineBytes)) {
            "$name fixture unexpectedly has no final newline"
        }
        val fixtureFile = File(root, "build/transformation-fixture/no-final-$name")
        fixtureFile.parentFile.mkdirs()
        Files.write(fixtureFile.toPath(), originalBytes.copyOf(originalBytes.size - newlineBytes.size))
        val noFinalNewline = transformer.readText(fixtureFile, charset, "no-final-$name fixture")
        require(!hasSuffix(noFinalNewline.bytes(), newlineBytes)) {
            "$name no-final-newline fixture was not read faithfully"
        }
        require(!hasSuffix(transform(noFinalNewline).bytes(), newlineBytes)) {
            "$name transformation added a final newline"
        }
    }

    private fun hasSuffix(value: ByteArray, suffix: ByteArray): Boolean {
        if (value.size < suffix.size) {
            return false
        }
        return suffix.indices.all { offset ->
            value[value.size - suffix.size + offset] == suffix[offset]
        }
    }

    private fun expectFailure(expected: String, action: () -> Unit) {
        try {
            action()
        } catch (error: GradleException) {
            if (error.message?.contains(expected) == true) {
                return
            }
            throw GradleException(
                "expected transformation failure containing '$expected', found '${error.message}'",
                error,
            )
        }
        throw GradleException("expected transformation failure containing '$expected'")
    }
}

class BuildishTransformationFixtureProjectAction : IsolatedAction<Project>, Serializable {
    override fun execute(project: Project) {
        if (project.gradle.parent == null && project.path == ":") {
            project.tasks.register(
                "buildishTransformationCheck",
                BuildishConfigureTransformationFixtureAction(project.projectDir.absolutePath),
            )
        }
    }
}

gradle.lifecycle.afterProject(BuildishTransformationFixtureProjectAction())
