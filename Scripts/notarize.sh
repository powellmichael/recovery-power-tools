#!/bin/bash
# Notarizes and staples the app built by make-app.sh, then zips it for
# download. Refuses anything that is not release-ready.
#
#   NOTARY_PROFILE  keychain profile made once with:
#                   xcrun notarytool store-credentials <profile-name>
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Recovery Power Tools.app"
ZIP="dist/Recovery-Power-Tools.zip"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile name}"

[ -d "$APP" ] || { echo "error: $APP not found. Run make app first." >&2; exit 1; }
if ! codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "error: the app is not signed with a Developer ID. Rebuild with SIGN_IDENTITY set." >&2
    exit 1
fi
KEY="$(plutil -extract RPTLicensePublicKey raw "$APP/Contents/Info.plist")"
[ -n "$KEY" ] || { echo "error: this build has no licence key, so recovery is unlocked. Add license-public.key and rebuild." >&2; exit 1; }

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
# Zip again so the download carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Ready to distribute: $ZIP"
