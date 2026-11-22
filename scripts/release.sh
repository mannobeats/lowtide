#!/bin/zsh
# A release anyone can install: builds Lowtide.app optimized, signs it and its
# helpers with the Developer ID (hardened runtime, secure timestamp), has
# Apple notarize it and staples the ticket, then wraps it with an
# Applications link in a signed DMG that is notarized and stapled too, and
# zips the stapled app for Lowtide's own updater (SelfUpdate).
#   scripts/release.sh   → dist/Lowtide.app, dist/Lowtide-<version>.dmg,
#                          dist/Lowtide-<version>.zip and dist/SHA256SUMS
# Notarization signs in one of two ways (docs/RELEASING.md):
#   - a notarytool keychain profile, made once with `xcrun notarytool
#     store-credentials`, named in LOWTIDE_NOTARY_PROFILE (on your Mac);
#   - an App Store Connect API key: LOWTIDE_NOTARY_KEY (path to the .p8),
#     LOWTIDE_NOTARY_KEY_ID and LOWTIDE_NOTARY_ISSUER (in CI).
# The Developer ID Application certificate must be in the keychain; set
# LOWTIDE_SIGN to pick one when there are several.
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
PROFILE=${LOWTIDE_NOTARY_PROFILE:-${NOTARY_KEYCHAIN_PROFILE:-}}
if [[ -n ${LOWTIDE_NOTARY_KEY:-} ]]; then
  AUTH=(--key "$LOWTIDE_NOTARY_KEY" --key-id "${LOWTIDE_NOTARY_KEY_ID:?LOWTIDE_NOTARY_KEY_ID}" --issuer "${LOWTIDE_NOTARY_ISSUER:?LOWTIDE_NOTARY_ISSUER}")
elif [[ -n $PROFILE ]]; then
  AUTH=(--keychain-profile "$PROFILE")
else
  echo "Set LOWTIDE_NOTARY_PROFILE, or LOWTIDE_NOTARY_KEY with its key id and issuer (docs/RELEASING.md)."; exit 1
fi
xcrun notarytool history $AUTH >/dev/null 2>&1 || { echo "notarytool can't sign in with those credentials."; exit 1; }
DIST=$ROOT/dist
APP=$DIST/Lowtide.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
DMG=$DIST/Lowtide-$VERSION.dmg
ZIP=$DIST/Lowtide-$VERSION.zip
IDENTITY=${LOWTIDE_SIGN:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
[[ -n $IDENTITY ]] || { echo "No Developer ID Application certificate in the keychain."; exit 1; }

# Apple answers "Accepted" or not; anything else stops the release with its log.
notarize() {
  local out id
  out=$(xcrun notarytool submit "$1" $AUTH --wait 2>&1) || true
  print -r -- "$out" | grep -E "id:|status:" | sort -u || true
  if ! print -r -- "$out" | grep -q "status: Accepted"; then
    id=$(print -r -- "$out" | awk '/^ *id:/ {print $2; exit}')
    [[ -n $id ]] && xcrun notarytool log $id $AUTH
    echo "Notarization failed for $1"; exit 1
  fi
}

rm -rf -- $DIST
mkdir -p $DIST
LOWTIDE_APP=$APP LOWTIDE_SIGN="$IDENTITY" zsh scripts/build.sh --release
codesign --verify --deep --strict "$APP"

echo "Notarizing the app…"
ditto -c -k --keepParent "$APP" $DIST/Lowtide.zip
notarize $DIST/Lowtide.zip
xcrun stapler staple -q "$APP"
rm -f $DIST/Lowtide.zip

echo "Making the DMG…"
STAGE=$(mktemp -d)
ditto "$APP" $STAGE/Lowtide.app
ln -s /Applications $STAGE/Applications
hdiutil create -quiet -volname Lowtide -srcfolder $STAGE -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple -q "$DMG"

# The updater downloads this: the stapled app, zipped as Finder would.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

spctl --assess --type execute -v "$APP"
spctl --assess --type open --context context:primary-signature -v "$DMG"
(cd $DIST && shasum -a 256 ${DMG:t} ${ZIP:t} > SHA256SUMS)
echo "released $DMG and $ZIP"
