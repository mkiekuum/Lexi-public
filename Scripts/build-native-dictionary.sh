#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="https://github.com/kiwakiwaa/mkd-tools.git"
REVISION="02ac2e7eef3f949483e4ccb1be62f5c17b9c053e"
WORK="${LEXI_NATIVE_BUILD_DIR:-$ROOT/.build-native}"
mkdir -p "$WORK"
SOURCE="$WORK/mkd-tools"
if [[ ! -d "$SOURCE/.git" ]]; then
    git clone --branch v0.10.0 --depth 1 "$UPSTREAM" "$SOURCE"
fi
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$REVISION" ]] || { echo "Unexpected mkd-tools revision" >&2; exit 1; }
git -C "$SOURCE" submodule update --init --recursive
cmake -S "$ROOT/NativeDictionary" -B "$WORK/build" -G Ninja -DMKD_SOURCE="$SOURCE" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build "$WORK/build" --target lexi-dictionary-reader --parallel 4
