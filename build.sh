#!/bin/bash
# Build SysInfoBar.app (release) from the Swift package.
#   ./build.sh           build ./build/SysInfoBar.app
#   ./build.sh install   build, then copy to /Applications and launch
#   ./build.sh zip       build, then pack build/SysInfoBar-<version>.zip
# Env: VERSION (default 1.0.0), BUILD_NUMBER (default 1)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SysInfoBar.app
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/SysInfoBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SysInfoBar"
strip -x "$APP/Contents/MacOS/SysInfoBar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: swift scripts/make-icon.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SysInfoBar</string>
    <key>CFBundleDisplayName</key><string>SysInfoBar</string>
    <key>CFBundleIdentifier</key><string>local.hyj.SysInfoBar</string>
    <key>CFBundleExecutable</key><string>SysInfoBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($VERSION build $BUILD_NUMBER)"

if [[ "${1:-}" == "zip" ]]; then
    ZIP="build/SysInfoBar-${VERSION}.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
    echo "Packed $ZIP"
fi

if [[ "${1:-}" == "install" ]]; then
    pkill -x SysInfoBar 2>/dev/null || true
    rm -rf /Applications/SysInfoBar.app
    cp -R "$APP" /Applications/
    open /Applications/SysInfoBar.app
    echo "Installed to /Applications/SysInfoBar.app and launched"
fi
