#!/bin/zsh
# Builds BrainFog.app into ./build without Xcode.
#
# The Command Line Tools' macOS 27 SDK turns SwiftUI's @State into a macro
# whose plugin ships only with Xcode, so build against the macOS 26 SDK
# (which already has the Liquid Glass APIs) unless SDKROOT is set.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=${CONFIG:-release}
CLT=/Library/Developer/CommandLineTools
export SDKROOT=${SDKROOT:-$CLT/SDKs/MacOSX26.sdk}

swift build --build-system native -c "$CONFIG" --product BrainFog 2>&1 | grep -v "has been deprecated"
BIN=$(swift build --build-system native -c "$CONFIG" --show-bin-path 2>/dev/null)

APP=build/BrainFog.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BrainFog" "$APP/Contents/MacOS/BrainFog"

# App icon: Resources/AppIcon.png (from scripts/make-icon.swift) → .icns.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

VERSION=$(git describe --tags --always 2>/dev/null || echo 0.1.0)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BrainFog</string>
  <key>CFBundleDisplayName</key><string>BrainFog</string>
  <key>CFBundleIdentifier</key><string>dev.brainfog.BrainFog</string>
  <key>CFBundleExecutable</key><string>BrainFog</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
