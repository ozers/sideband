#!/bin/bash
#
# Builds Kadran.app from the SwiftPM product.
#
# SwiftPM emits a bare executable, but a menu bar app needs a bundle: LSUIElement
# is what keeps it out of the Dock, and NSStatusItem needs a bundle identifier to
# persist its position between launches.
#
# Usage: Scripts/bundle.sh [output-directory]   (default: ./dist)

set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="${1:-dist}"
APP="$OUT_DIR/Kadran.app"
# --always is deliberately absent: with no tags it returns a commit hash, which
# is not a valid CFBundleShortVersionString and makes the app look unversioned
# in Finder. Tag a release to change this.
VERSION="$(git describe --tags 2>/dev/null || echo "0.1.0")"

echo "Building release…"
swift build -c release --arch arm64

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Kadran "$APP/Contents/MacOS/Kadran"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "note: Resources/AppIcon.icns missing; run Scripts/make-icon.swift" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Kadran</string>
    <key>CFBundleDisplayName</key>     <string>Kadran</string>
    <key>CFBundleIdentifier</key>      <string>dev.kadran.Kadran</string>
    <key>CFBundleExecutable</key>      <string>Kadran</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough to run locally; distributing to other machines needs
# a Developer ID signature and notarization, which this script deliberately does
# not attempt, since the private IOAVService API rules out the App Store anyway.
codesign --force --sign - "$APP" >/dev/null 2>&1 || {
    echo "warning: ad-hoc codesign failed; the app may be blocked by Gatekeeper" >&2
}

echo "Built $APP ($VERSION)"
