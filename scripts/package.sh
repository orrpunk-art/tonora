#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app_path="build-universal/Tonora.app"
if [ ! -d "$app_path" ]; then
  echo 'Run ./scripts/build.sh build-universal first.' >&2
  exit 1
fi
lipo "$app_path/Contents/MacOS/Tonora" -verify_arch arm64 x86_64
# Local integrity signature; Developer ID signing/notarization is a separate step.
codesign --force --sign - "$app_path"
codesign --verify --all-architectures --deep --strict --verbose=2 "$app_path"
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$app_path" dist/Tonora-1.6.0-universal.zip
shasum -a 256 dist/Tonora-1.6.0-universal.zip
