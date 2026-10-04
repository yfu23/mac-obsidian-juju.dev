#!/bin/bash
# Builds ObsidianJuju.app into ./build using SwiftPM (no Xcode project required).
set -euo pipefail
cd "$(dirname "$0")"
./scripts/check_readonly.sh
# JujuPix's shared core (for .jjpx photos); does nothing when it's up to date.
../JujuPixCore/scripts/build-apple.sh
swift build -c release --product ObsidianJuju
# Check a few core results on the optimized build (debug-built CoreChecks can't catch optimizer problems).
REL="$(swift build -c release --show-bin-path)"
SMOKE="$(mktemp -d)/release_smoke"
swiftc -O -I "$REL" -I "$REL/include" scripts/release_smoke.swift "$REL/ObsidianJujuCore.o" "$REL/JujuPixCore.o" \
  "$REL/libjujupix_ffi.a" -o "$SMOKE"
"$SMOKE"
APP=build/ObsidianJuju.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$(swift build -c release --show-bin-path)/ObsidianJuju" "$APP/Contents/MacOS/"
cp -R Resources/Web "$APP/Contents/Resources/Web"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ObsidianJuju</string>
  <key>CFBundleDisplayName</key><string>ObsidianJuju</string>
  <key>CFBundleIdentifier</key><string>com.example.ObsidianJuju</string>
  <key>CFBundleExecutable</key><string>ObsidianJuju</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Read Obsidian vaults stored on your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Read Obsidian vaults stored in Documents.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Read Obsidian vaults stored in Downloads.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
