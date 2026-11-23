#!/bin/zsh
# Builds the dictation helper (Helpers/Voice: FluidAudio for Parakeet, MLX for
# Qwen3-ASR, PhononCoreML for Phonon-2) into ~/Library/Developer/Lowtide/helpers,
# with the resource bundles its packages read at run time (MLX's GPU shaders
# above all). scripts/build.sh copies that folder into Contents/Helpers, where
# the helper's Bundle.main is, so it finds the bundles beside itself.
# Slow the first time (MLX); later runs only relink.
set -euo pipefail
ROOT=${0:A:h:h}
SCRATCH=${LOWTIDE_VOICE_SCRATCH:-$HOME/Library/Developer/Lowtide/voice-build}
OUT=$HOME/Library/Developer/Lowtide/helpers
# Resource bundles the helper loads at run time. These two are always built;
# others come and go with package versions (FluidAudio 0.18 dropped its own),
# so whatever the build makes is copied and nothing else.
REQUIRED=(mlx-swift_Cmlx.bundle swift-transformers_Hub.bundle)

# macOS remounts the Metal toolchain under a new random name now and then and
# the build plan keeps the old path: every shader then fails to compile. The
# plan is cheap to make again; the compiled objects stay.
rm -rf $SCRATCH/out/Intermediates.noindex/XCBuildData

xcrun swift build -c release --package-path $ROOT/Helpers/Voice --scratch-path $SCRATCH 2>&1 \
  | sed -E 's/\x1b\[[0-9;]*m//g' | grep -E "(error|warning): |Build complete|Compiling .* failed" | sort -u || true
PRODUCTS=$SCRATCH/release
[[ -x $PRODUCTS/lowtide-voice ]] || { echo "voice helper build failed"; exit 1; }
if [[ -n $(find $ROOT/Helpers/Voice/Sources -name '*.swift' -newer $PRODUCTS/lowtide-voice -print -quit) ]]; then
  echo "voice helper build failed (sources newer than binary)"; exit 1
fi

mkdir -p $OUT
cp $PRODUCTS/lowtide-voice $OUT/lowtide-voice
for name in $REQUIRED; do
  [[ -d $PRODUCTS/$name ]] || { echo "missing $name"; exit 1; }
done
BUNDLES=(${PRODUCTS}/*.bundle(N:t))
for old in $OUT/*.bundle(N:t); do
  (( ${BUNDLES[(Ie)$old]} )) || rm -rf $OUT/$old
done
for name in $BUNDLES; do
  rsync -a --delete $PRODUCTS/$name/ $OUT/$name/
done
# Signed here: in Contents/Helpers they count as nested code, and the app's
# signature refuses unsigned ones. Same identity as scripts/build.sh.
IDENTITY=${LOWTIDE_SIGN:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')}
IDENTITY=${IDENTITY:--}
for name in $BUNDLES; do
  codesign --force --sign "$IDENTITY" $OUT/$name 2>&1 | grep -v "replacing existing signature" || true
done
$OUT/lowtide-voice --self-test >/dev/null || { echo "voice helper self-test failed"; exit 1; }
echo "built $OUT/lowtide-voice"
