#!/bin/zsh
# Compiles the privileged helper (Helpers/Privileged/lowtide-privileged.swift)
# into ~/Library/Developer/Lowtide/helpers/lowtide-privileged. scripts/build.sh
# copies that folder into Contents/Helpers and signs it; the launch daemon's
# plist (Support/LaunchDaemons) points launchd at it.
#   scripts/build-privileged.sh [--debug]
set -euo pipefail
ROOT=${0:A:h:h}
OUT=${LOWTIDE_HELPERS:-$HOME/Library/Developer/Lowtide/helpers}
OPT=-O
[[ ${1:-} == --debug ]] && OPT=-Onone
mkdir -p $OUT
xcrun swiftc $OPT -swift-version 6 -target arm64-apple-macos26.0 \
  -o $OUT/lowtide-privileged $ROOT/Helpers/Privileged/lowtide-privileged.swift
echo "built $OUT/lowtide-privileged"
