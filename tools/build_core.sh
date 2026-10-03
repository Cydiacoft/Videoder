#!/usr/bin/env bash
# Builds the native core standalone and runs its ctest suites (Linux/macOS).
#
# The Flutter app builds the same CMake target through linux/CMakeLists.txt or
# the macOS "Build Videoder Core" phase; this script exists so the core can be
# compiled and tested without Flutter.
#
# Usage:
#   tools/build_core.sh                # Debug build + tests
#   tools/build_core.sh Release
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${1:-Debug}"
build_dir="$root/build/native/videoder_core"

cmake -S "$root/native/videoder_core" -B "$build_dir" -DCMAKE_BUILD_TYPE="$config"
cmake --build "$build_dir" --config "$config"
ctest --test-dir "$build_dir" --output-on-failure

echo "videoder_core built in $build_dir"
echo "Dart picks it up automatically, or set VIDEODER_CORE_LIBRARY to force it."
