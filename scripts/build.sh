#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
build_dir="${1:-build}"
# Shipped builds are optimized (-O2 -g); pass Debug as the second argument for an unoptimized one.
build_type="${2:-RelWithDebInfo}"
cmake -S . -B "$build_dir" -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_BUILD_TYPE="$build_type" -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" -DCMAKE_C_COMPILER="$(xcrun --find clang)" -DCMAKE_OBJC_COMPILER="$(xcrun --find clang)"
cmake --build "$build_dir" --parallel
ctest --test-dir "$build_dir" --output-on-failure
