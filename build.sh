#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build/module-cache dist/AudioFlow.app/Contents/MacOS dist/AudioFlow.app/Contents/Resources/Helpers
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx15.0" -O \
  -framework AppKit -framework SwiftUI -framework CoreAudio \
  App.swift -o dist/AudioFlow.app/Contents/MacOS/AudioFlow
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx15.0" -O \
  -framework AppKit -framework CoreAudio -framework AudioToolbox \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/AudioRoute/Info.plist \
  Sources/AudioRoute/main.swift -o dist/AudioFlow.app/Contents/Resources/Helpers/audio-route
cp Info.plist dist/AudioFlow.app/Contents/Info.plist
cp -R en.lproj zh-Hans.lproj dist/AudioFlow.app/Contents/Resources/
swift Icon.swift dist/AudioFlow.app/Contents/Resources
codesign --force --sign - dist/AudioFlow.app/Contents/Resources/Helpers/audio-route
codesign --force --deep --sign - dist/AudioFlow.app
echo "Built: $PWD/dist/AudioFlow.app"
