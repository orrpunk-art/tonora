#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
build_dir="${1:-build}"
cmake -S . -B "$build_dir" -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_BUILD_TYPE=Debug -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" -DCMAKE_C_COMPILER="$(xcrun --find clang)" -DCMAKE_OBJC_COMPILER="$(xcrun --find clang)"
cmake --build "$build_dir" --parallel
ctest --test-dir "$build_dir" --output-on-failure
