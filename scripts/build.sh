#!/bin/zsh
# Builds Lowtide into /Applications/Lowtide.app, where a release installs it
# (the path never changes, so macOS keeps its permission grants), signs it with the
# Developer ID, and with --open quits the running copy and opens the new one.
#   scripts/build.sh [--release] [--open] [--voice]
#   --voice also rebuilds the dictation helper (MLX: slow, needed once).
set -euo pipefail
ROOT=${0:A:h:h}
CONFIG=debug
OPEN=0
VOICE=0
for arg in "$@"; do
  case $arg in
    --release) CONFIG=release ;;
    --open) OPEN=1 ;;
    --voice) VOICE=1 ;;
  esac
done
SCRATCH=${LOWTIDE_SCRATCH:-$HOME/Library/Developer/Lowtide/build}
APP=${LOWTIDE_APP:-/Applications/Lowtide.app}
IDENTITY=${LOWTIDE_SIGN:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')}
IDENTITY=${IDENTITY:--}

cd $ROOT
xcrun swift build -c $CONFIG --scratch-path $SCRATCH 2>&1 | grep -v "^\[" | grep -Ev "^(Building|Build complete|Compiling|Write|Planning|Emitting|Linking)" || true
BIN=$SCRATCH/$CONFIG/Lowtide
[[ -x $BIN ]] || { echo "build failed"; exit 1; }
# A failed incremental build can leave the old binary: any newer source means failure.
if [[ -n $(find Sources -name '*.swift' -newer $BIN -print -quit) ]]; then echo "build failed (sources newer than binary)"; exit 1; fi

# Replacing the binary of a running copy invalidates its code signature
# and macOS kills it: quit that copy (only that one) first.
if pgrep -f "$APP/Contents/MacOS/Lowtide" >/dev/null; then
  pkill -f "$APP/Contents/MacOS/Lowtide"; sleep 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp $BIN "$APP/Contents/MacOS/Lowtide"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Test copies run beside the real app under their own id (their own
# settings, and macOS gives each its own windows).
if [[ -n ${LOWTIDE_BUNDLE_ID:-} ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $LOWTIDE_BUNDLE_ID" "$APP/Contents/Info.plist"
fi
rsync -a --delete --exclude AppIcon.icns --exclude Assets.car Resources/ "$APP/Contents/Resources/"
[[ -f Support/AppIcon.icns ]] && cp Support/AppIcon.icns Support/Assets.car "$APP/Contents/Resources/"

# Helpers built by their own scripts (dictation, privileged helper).
if [[ $VOICE == 1 ]]; then zsh scripts/build-voice.sh; fi
HELPERS=$HOME/Library/Developer/Lowtide/helpers
if [[ -d $HELPERS ]]; then rsync -a $HELPERS/ "$APP/Contents/Helpers/"; fi
if [[ -d Support/LaunchDaemons ]]; then mkdir -p "$APP/Contents/Library/LaunchDaemons"; cp Support/LaunchDaemons/*.plist "$APP/Contents/Library/LaunchDaemons/"; fi

# Release builds ship without debug symbols (the binary drops by half).
if [[ $CONFIG == release ]]; then
  strip -S -x "$APP/Contents/MacOS/Lowtide" 2>/dev/null
  for helper in "$APP"/Contents/Helpers/*(N); do [[ -f $helper && -x $helper ]] && strip -S -x "$helper" 2>/dev/null; done
fi
xattr -cr "$APP"
SIGN=(codesign --force --sign "$IDENTITY")
# Release builds carry Apple's secure timestamp, which notarization requires;
# everyday builds skip it (it asks Apple's server on every build).
if [[ $IDENTITY != "-" ]]; then
  if [[ $CONFIG == release ]]; then SIGN+=(--options runtime --timestamp); else SIGN+=(--options runtime --timestamp=none); fi
fi
for helper in "$APP"/Contents/Helpers/*(N); do
  [[ -f $helper && -x $helper ]] && $SIGN --entitlements Support/Lowtide.entitlements "$helper"
done
$SIGN --entitlements Support/Lowtide.entitlements "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "built $APP ($CONFIG)"

if [[ $OPEN == 1 ]]; then
  open "$APP"
fi
