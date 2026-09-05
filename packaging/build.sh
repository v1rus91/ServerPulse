#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -f Resources/ServerPulse.icns ]; then
  [ -x .venv-icon/bin/python ] || { python3 -m venv .venv-icon && .venv-icon/bin/pip install -q pillow; }
  .venv-icon/bin/python packaging/make_icon.py
fi
swift build -c release 2>&1 | tail -2
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" packaging/Info.plist)
APP=dist/ServerPulse.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ServerPulse "$APP/Contents/MacOS/"
cp packaging/Info.plist "$APP/Contents/"
cp Resources/ServerPulse.icns "$APP/Contents/Resources/"
cp -R Resources/en.lproj "$APP/Contents/Resources/" 2>/dev/null || true
echo -n "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "ServerPulse" -srcfolder "$STAGE" -ov -format UDZO "dist/ServerPulse-$VERSION.dmg"; rm -rf "$STAGE"
echo; echo "✅ Готово:"; du -sh "$APP" "dist/ServerPulse-$VERSION.dmg"
