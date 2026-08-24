#!/bin/bash
#
# Signs, notarises and packages Sideband for distribution.
#
# Notarisation is Apple scanning the binary for malware, not App Store review,
# so the private IOAVService symbols this app resolves are not a problem here —
# they only rule out the App Store.
#
# Prerequisites, once per machine:
#
#   1. A "Developer ID Application" certificate in the keychain.
#      Apple Developer account → Certificates → Developer ID Application.
#
#   2. A notarytool credential profile. With an App Store Connect API key:
#
#        xcrun notarytool store-credentials "sideband" \
#            --key ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 \
#            --key-id XXXXXXXXXX \
#            --issuer <issuer-uuid>
#
#      Nothing secret is stored in this repository; the key and the profile
#      stay on the machine that signs.
#
# Usage: Scripts/release.sh
#
# Override with environment variables when the defaults do not match:
#   SIGN_IDENTITY   full name of the signing certificate
#   NOTARY_PROFILE  notarytool keychain profile name

set -euo pipefail

cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-sideband}"

VERSION="$(git describe --tags 2>/dev/null || echo "0.1.0")"
APP="dist/Sideband.app"
DMG="dist/Sideband-$VERSION.dmg"
ZIP="dist/Sideband-$VERSION.zip"

echo "==> Building $VERSION"
Scripts/bundle.sh >/dev/null

echo "==> Signing"
# --options runtime enables the hardened runtime, which notarisation requires.
# --timestamp binds a trusted timestamp, so the signature stays valid after the
# certificate expires. No entitlements are needed: the app runs no JIT, maps no
# unsigned executable memory, and only resolves symbols already loaded in the
# process.
codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    "$APP"

codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarising the app"
# Submitted as a zip because notarytool takes an archive, not a bundle. The
# ticket that comes back is stapled to the .app itself, so a copy taken out of
# the disk image is still verifiable without a network round trip.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "==> Building the disk image"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Sideband" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Signing and notarising the disk image"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying as Gatekeeper sees it"
spctl --assess --type execute --verbose=2 "$APP"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

echo
echo "Ready: $DMG"
