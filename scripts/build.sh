#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="Bookshelf"
BUNDLE_ID="com.volodymyr.bookshelf"

echo "==> Building ($CONFIG)…"
# shellcheck disable=SC2086
swift build -c "$CONFIG" ${SWIFT_BUILD_FLAGS:-}

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
APP_DIR="build/$APP_NAME.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Helpers"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

# DjVuLibre's ddjvu helper (GPLv2, invoked as a separate process).
cp Assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp Vendor/ddjvu "$APP_DIR/Contents/Helpers/ddjvu"
chmod +x "$APP_DIR/Contents/Helpers/ddjvu"
cp Vendor/DjVuLibre-NOTICE.txt "$APP_DIR/Contents/Resources/DjVuLibre-NOTICE.txt"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Bookshelf</string>
    <key>CFBundleDisplayName</key>
    <string>Bookshelf</string>
    <key>CFBundleExecutable</key>
    <string>Bookshelf</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>uk</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Volodymyr. Скевоморфна бібліотека книг.</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.books</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_DIR/Contents/Helpers/ddjvu" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "==> Готово: $APP_DIR"
