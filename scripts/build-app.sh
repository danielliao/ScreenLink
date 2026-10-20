#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product ScreenLink --arch arm64
app_path="$PWD/dist/ScreenLink.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/arm64-apple-macosx/release/ScreenLink "$app_path/Contents/MacOS/ScreenLink"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp README.md "$app_path/Contents/Resources/README.md"
cp LICENSE THIRD_PARTY_NOTICES.md SECURITY.md "$app_path/Contents/Resources/"
mkdir -p "$app_path/Contents/Resources/docs"
cp docs/*.md "$app_path/Contents/Resources/docs/"
/usr/bin/codesign --force --sign "${SCREENLINK_SIGN_IDENTITY:--}" "$app_path"
/usr/bin/codesign --verify --strict "$app_path"
app_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$PWD/dist/ScreenLink-$app_version-arm64.zip"
echo "Built: $app_path"
