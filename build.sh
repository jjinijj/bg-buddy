#!/bin/bash
# 설치된 소스에서 앱을 다시 빌드한다 (buddy rebuild 와 install.sh 가 호출).
set -e
DIR="${1:-$HOME/Applications/BgBuddy}"
APP="$DIR/BgBuddy.app"
command -v swiftc >/dev/null || { echo "swiftc 없음. xcode-select --install"; exit 1; }
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/BgBuddy" "$DIR/BgBuddy.swift" -framework AppKit
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>BgBuddy</string>
  <key>CFBundleDisplayName</key><string>BG Buddy</string>
  <key>CFBundleIdentifier</key><string>local.bgbuddy</string>
  <key>CFBundleExecutable</key><string>BgBuddy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force -s - "$APP" 2>/dev/null || true
echo "built: $APP"
