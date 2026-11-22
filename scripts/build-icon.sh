#!/bin/zsh
# Compiles Icon/AppIcon.icon (Icon Composer) into Support/AppIcon.icns and Support/Assets.car.
ROOT=${0:A:h:h}
OUT=$(mktemp -d)
xcrun actool $ROOT/Icon/AppIcon.icon --compile $OUT --platform macosx --minimum-deployment-target 26.0 \
  --app-icon AppIcon --output-partial-info-plist $OUT/partial.plist >/dev/null
cp $OUT/AppIcon.icns $OUT/Assets.car $ROOT/Support/ && echo "icon compiled"
