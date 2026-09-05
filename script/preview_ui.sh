#!/bin/zsh
set -euo pipefail

# 编译独立的无硬件预览包；不读取真实配置，也不链接控制与服务实现。
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build --product BattCycle
BIN_DIR="$(swift build --show-bin-path)"
PREVIEW_APP="$ROOT/dist/BattCycleUIPreview.app"
mkdir -p "$PREVIEW_APP/Contents/MacOS"
/usr/bin/swiftc -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macosx14.0" \
  -I "$BIN_DIR/Modules" \
  "$BIN_DIR"/BattCycleCore.build/*.o \
  Sources/BattCycle/ContentView.swift \
  Sources/BattCycle/BatteryOverview.swift \
  Sources/BattCycle/CyclePlanView.swift \
  Sources/BattCycle/ActivityView.swift \
  Sources/BattCycle/UIComponents.swift \
  script/PreviewUI.swift \
  -framework AppKit -framework SwiftUI -framework IOKit \
  -o "$PREVIEW_APP/Contents/MacOS/BattCycleUIPreview"
cat > "$PREVIEW_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>BattCycleUIPreview</string>
<key>CFBundleIdentifier</key><string>org.alfwuxy.BattCycle.UIPreview</string>
<key>CFBundleName</key><string>BattCycle UI Preview</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/open -n -W "$PREVIEW_APP" --args "$@"
