#!/bin/sh
#
# Copyright 2026 The Buildish Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

model_file=docs/threat-model.md
inputs_file=scripts/security-model-inputs.txt
mode=${1:-check}

case "$mode" in
  check|--print-digest) ;;
  *)
    echo "usage: $0 [--print-digest]" >&2
    exit 2
    ;;
esac

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/buildish-security-model.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

{
  printf '%s\n' "$inputs_file"
  while IFS= read -r input_path || [ -n "$input_path" ]; do
    case "$input_path" in
      ''|'#'*) continue ;;
    esac
    git ls-files --cached --others --exclude-standard -- "$input_path"
  done < "$inputs_file"
} | LC_ALL=C sort -u > "$tmp_dir/paths"

if [ ! -s "$tmp_dir/paths" ]; then
  echo "security-model-check: no security-model inputs were found" >&2
  exit 1
fi

while IFS= read -r input_path; do
  if [ ! -f "$input_path" ]; then
    echo "security-model-check: listed input is not a regular file: $input_path" >&2
    exit 1
  fi
  printf '%s  %s\n' "$(git hash-object -- "$input_path")" "$input_path"
done < "$tmp_dir/paths" > "$tmp_dir/inventory"

actual_digest=$(git hash-object --stdin < "$tmp_dir/inventory")

if [ "$mode" = --print-digest ]; then
  printf '%s\n' "$actual_digest"
  exit 0
fi

expected_digest=$(
  sed -n 's/^Security-sensitive content digest: `\([0-9a-f][0-9a-f]*\)`.*/\1/p' "$model_file"
)

case "$expected_digest" in
  ''|*"
"*)
    echo "security-model-check: expected exactly one content digest in $model_file" >&2
    exit 1
    ;;
esac

if [ "$actual_digest" != "$expected_digest" ]; then
  echo "security-model-check: security-sensitive content changed since the threat model was reviewed" >&2
  echo "security-model-check: expected $expected_digest" >&2
  echo "security-model-check: actual   $actual_digest" >&2
  echo "security-model-check: review docs/threat-model.md, then update its content digest" >&2
  exit 1
fi

echo "security-model-check: passed ($actual_digest)"
