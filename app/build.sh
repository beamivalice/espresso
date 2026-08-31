#!/bin/sh
# Build Espresso.app — arm64 menu-bar supervisor, no Xcode project required.
set -e
cd "$(dirname "$0")"

NAME=Espresso
APP="$NAME.app"
BIN="build/$NAME"

echo "== compiling $NAME (arm64) =="
rm -rf "$APP" build
mkdir -p build

swiftc -O -swift-version 5 -parse-as-library \
       -target arm64-apple-macosx13.0 \
       main.swift -o "$BIN"

echo "== bundling =="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Espresso</string>
    <key>CFBundleDisplayName</key><string>Espresso</string>
    <key>CFBundleIdentifier</key><string>dev.espresso.supervisor</string>
    <key>CFBundleExecutable</key><string>Espresso</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Espresso launches Wine and Steam on your behalf.</string>
</dict>
</plist>
PLIST

echo "== ad-hoc signing =="
codesign --force --sign - --options runtime "$APP" 2>/dev/null \
  || codesign --force --sign - "$APP"

echo
echo "built: $(pwd)/$APP"
echo "arch:  $(lipo -archs "$APP/Contents/MacOS/$NAME")"
codesign -dv "$APP" 2>&1 | grep -E 'Signature|Identifier' || true
