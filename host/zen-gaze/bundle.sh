#!/usr/bin/env bash
# Builds ZenGaze.app next to this script.
# The camera prompt only works from a bundle with NSCameraUsageDescription,
# so don't run the bare `swift run` binary for real use.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=ZenGaze.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ZenGaze "$APP/Contents/MacOS/ZenGaze"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ZenGaze</string>
  <key>CFBundleIdentifier</key><string>local.zen-firmware.zengaze</string>
  <key>CFBundleExecutable</key><string>ZenGaze</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key>
  <string>얼굴 방향을 보고 ZEN 키보드의 출력을 이 맥과 다른 컴퓨터 사이에서 전환합니다. 영상은 저장하거나 전송하지 않습니다.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS remembers the camera permission between launches.
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
