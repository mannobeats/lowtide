#!/bin/zsh
# Compiles and prints only errors and warnings, without colour codes.
ROOT=${0:A:h:h}
cd $ROOT
xcrun swift build --scratch-path ${LOWTIDE_SCRATCH:-$HOME/Library/Developer/Lowtide/build} 2>&1 \
  | sed -E 's/\x1b\[[0-9;]*m//g' | grep -E "(error|warning): " | grep -v "^warning: 'lowtide'" | sort -u | head -${1:-40}
rc=${pipestatus[1]}
echo "exit: $rc"
exit $rc
