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

import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
} from 'node:fs';
import { execFileSync } from 'node:child_process';
import { delimiter, dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const PINNED_RENOVATE_VERSION = '44.7.0';
const PACKAGE_FILE = 'gradle/wrapper/gradle-wrapper.properties';
const FROM_URL = 'https\\://services.gradle.org/distributions/gradle-8.14.5-bin.zip';
const TO_URL = 'https\\://services.gradle.org/distributions/gradle-9.6.1-bin.zip';
const FROM_SHA256 = '6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854';
const TO_SHA256 = '9c0f7faeeb306cb14e4279a3e084ca6b596894089a0638e68a07c945a32c9e14';

function fail(message) {
  process.stderr.write(`renovate-fixture: ${message}\n`);
  process.exit(1);
}

function findRenovatePackage() {
  for (const directory of (process.env.PATH ?? '').split(delimiter)) {
    if (!directory) {
      continue;
    }
    const executable = join(directory, process.platform === 'win32' ? 'renovate.cmd' : 'renovate');
    if (!existsSync(executable)) {
      continue;
    }
    let current;
    try {
      current = dirname(realpathSync(executable));
    } catch {
      continue;
    }
    for (;;) {
      const packageJson = join(current, 'package.json');
      if (existsSync(packageJson)) {
        const metadata = JSON.parse(readFileSync(packageJson, 'utf8'));
        if (metadata.name === 'renovate') {
          if (metadata.version !== PINNED_RENOVATE_VERSION) {
            fail(
              `expected renovate ${PINNED_RENOVATE_VERSION}, found ${metadata.version ?? 'unknown'}`,
            );
          }
          return current;
        }
      }
      const parent = dirname(current);
      if (parent === current) {
        break;
      }
      current = parent;
    }
  }
  fail(`cannot resolve renovate ${PINNED_RENOVATE_VERSION} from PATH`);
}

function replaceExactlyOnce(text, before, after, label) {
  const first = text.indexOf(before);
  if (first < 0 || text.indexOf(before, first + before.length) >= 0) {
    fail(`expected exactly one ${label} in ${PACKAGE_FILE}`);
  }
  return `${text.slice(0, first)}${after}${text.slice(first + before.length)}`;
}

function artifactErrorText(error) {
  if (typeof error === 'string') {
    return error;
  }
  if (error && typeof error === 'object') {
    return [error.message, error.stderr].filter((value) => typeof value === 'string').join('\n');
  }
  return String(error);
}

if (process.argv.length !== 3) {
  fail('usage: run-artifact-update.mjs <consumer>');
}

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const sourceConsumer = resolve(process.argv[2]);
const workConsumer = resolve(`${sourceConsumer}.renovate-work`);
const cacheRoot = resolve(`${sourceConsumer}.renovate-cache`);
if (!existsSync(join(sourceConsumer, '.git'))) {
  fail(`consumer is not a Git repository: ${sourceConsumer}`);
}
if (existsSync(workConsumer) || existsSync(cacheRoot)) {
  fail('Renovate work and cache paths must not exist before the fixture starts');
}
mkdirSync(cacheRoot, { recursive: false });
execFileSync('git', ['clone', '--quiet', '--no-hardlinks', sourceConsumer, workConsumer], {
  stdio: ['ignore', 'ignore', 'inherit'],
});

const fixtureConfig = JSON.parse(readFileSync(join(scriptDirectory, 'config.json'), 'utf8'));
if (
  JSON.stringify(fixtureConfig) !== JSON.stringify({
    enabledManagers: ['gradle-wrapper'],
  })
) {
  fail('repository Renovate fixture does not match the version-open update contract');
}
const renovateRoot = findRenovatePackage();
const importFromRenovate = async (relative) => import(pathToFileURL(join(renovateRoot, relative)).href);
const { GlobalConfig } = await importFromRenovate('dist/config/global.js');
const { updateArtifacts } = await importFromRenovate(
  'dist/modules/manager/gradle-wrapper/artifacts.js',
);
const { setPlatformApi } = await importFromRenovate('dist/modules/platform/index.js');
const { initRepo, syncGit } = await importFromRenovate('dist/util/git/index.js');

GlobalConfig.set({
  localDir: workConsumer,
  cacheDir: cacheRoot,
  containerbaseDir: join(cacheRoot, 'containerbase'),
  binarySource: 'global',
  allowedUnsafeExecutions: ['gradleWrapper'],
  platform: 'github',
});
setPlatformApi('github');
await initRepo({ url: sourceConsumer, defaultBranch: 'main' });
await syncGit();

const sourceJar = join(sourceConsumer, 'gradle/wrapper/gradle-wrapper.jar');
const workJar = join(workConsumer, 'gradle/wrapper/gradle-wrapper.jar');
if (!existsSync(sourceJar)) {
  fail(`ignored warm Wrapper JAR is missing: ${sourceJar}`);
}
copyFileSync(sourceJar, workJar);
process.chdir(workConsumer);

let updatedProperties = readFileSync(PACKAGE_FILE, 'utf8');
updatedProperties = replaceExactlyOnce(updatedProperties, FROM_URL, TO_URL, 'source distribution URL');
updatedProperties = replaceExactlyOnce(
  updatedProperties,
  `distributionSha256Sum=${FROM_SHA256}`,
  `distributionSha256Sum=${TO_SHA256}`,
  'source distribution digest',
);

const results = (await updateArtifacts({
  packageFileName: PACKAGE_FILE,
  newPackageFileContent: updatedProperties,
  updatedDeps: [],
  config: {
    currentValue: '8.14.5',
    newValue: '9.6.1',
    constraints: { java: '>=21' },
  },
})) ?? [];

const artifacts = results
  .flatMap((result) => (result.file?.path ? [result.file.path] : []))
  .sort();
const errors = results
  .flatMap((result) => (result.artifactError ? [artifactErrorText(result.artifactError)] : []));
process.stdout.write(`${JSON.stringify({ artifacts, errors })}\n`);
if (errors.length > 0) {
  process.exitCode = 1;
}
