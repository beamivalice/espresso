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

echo "== hide-steam-host dylib (x86_64, injected into Wine) =="
clang -dynamiclib -O2 -arch x86_64 -mmacosx-version-min=13.0 \
      hide-steam-host.m -o build/hide-steam-host.dylib \
      -framework AppKit -framework Foundation
mkdir -p "$HOME/Library/Application Support/Espresso/Helpers"
cp build/hide-steam-host.dylib "$HOME/Library/Application Support/Espresso/Helpers/"

echo "== app icon =="
swiftc -O -target arm64-apple-macosx13.0 \
       make-icon.swift -o build/make-icon
./build/make-icon build/icon-1024.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16     build/icon-1024.png --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     build/icon-1024.png --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     build/icon-1024.png --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     build/icon-1024.png --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   build/icon-1024.png --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   build/icon-1024.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   build/icon-1024.png --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   build/icon-1024.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   build/icon-1024.png --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 build/icon-1024.png --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o build/AppIcon.icns

echo "== bundling =="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp build/hide-steam-host.dylib "$APP/Contents/Resources/"
cp build/AppIcon.icns "$APP/Contents/Resources/"

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
    <key>CFBundleShortVersionString</key><string>0.3</string>
    <key>CFBundleVersion</key><string>10</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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
