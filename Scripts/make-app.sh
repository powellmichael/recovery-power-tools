#!/bin/bash
# Assembles "Recovery Power Tools.app" from the SwiftPM release build and
# signs it with the hardened runtime.
#
# Settings come from the environment (the Makefile passes them through):
#   BUNDLE_ID       reverse-DNS identifier
#   VERSION, BUILD  marketing version and build number
#   SIGN_IDENTITY   "-" for an ad-hoc signature (local testing only), or a
#                   "Developer ID Application: …" identity for distribution
#   PURCHASE_URL    store page for the "Buy a Licence" link (optional)
#
# The licence public key is read from license-public.key in the repository
# root. Without it the app is built with recovery unlocked.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Recovery Power Tools"
BUNDLE_ID="${BUNDLE_ID:-com.recoverypowertools.app}"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
PURCHASE_URL="${PURCHASE_URL:-}"
APP="dist/$APP_NAME.app"

LICENSE_KEY=""
if [ -f license-public.key ]; then
    LICENSE_KEY="$(tr -d '[:space:]' < license-public.key)"
fi

swift build -c release --product FileRecovery
BIN="$(swift build -c release --show-bin-path)/FileRecovery"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FileRecovery"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

PLIST="$APP/Contents/Info.plist"
plutil -create xml1 "$PLIST"
set_string() { plutil -insert "$1" -string "$2" "$PLIST"; }
set_string CFBundleName "$APP_NAME"
set_string CFBundleDisplayName "$APP_NAME"
set_string CFBundleExecutable FileRecovery
set_string CFBundleIdentifier "$BUNDLE_ID"
set_string CFBundlePackageType APPL
set_string CFBundleInfoDictionaryVersion 6.0
set_string CFBundleShortVersionString "$VERSION"
set_string CFBundleVersion "$BUILD"
set_string LSMinimumSystemVersion 14.0
set_string LSApplicationCategoryType public.app-category.utilities
set_string CFBundleIconFile AppIcon
set_string RPTLicensePublicKey "$LICENSE_KEY"
set_string RPTPurchaseURL "$PURCHASE_URL"
plutil -insert NSHighResolutionCapable -bool true "$PLIST"

# Hardened runtime is required for notarization. No entitlements: the app is
# not sandboxed (it reads raw devices) and asks for no runtime exceptions.
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --options runtime --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo
echo "Built $APP ($VERSION, build $BUILD)"
[ "$SIGN_IDENTITY" = "-" ] && echo "warning: ad-hoc signature. Runs on this Mac only; not for distribution."
[ -z "$LICENSE_KEY" ] && echo "warning: no license-public.key. Recovery is UNLOCKED in this build; not for release."
exit 0
