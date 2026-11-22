#!/bin/zsh
# Builds your own copy of the app, opens it on one page through
# LaunchServices (a directly executed copy may show no window), captures the
# window, and quits it. Safe to run while other copies are running.
#   scripts/run-page.sh <your-name> <page route> [out.png]
#   WAIT=10 scripts/run-page.sh network network/live    # wait longer for data
#   KEEP=1 …                                            # leave it running
NAME=$1; PAGE=$2
OUT=${3:-/tmp/lowtide-$NAME-${PAGE//\//-}.png}
export LOWTIDE_SCRATCH=$HOME/Library/Developer/Lowtide/build-$NAME
export LOWTIDE_APP=/tmp/lowtide-$NAME/Lowtide.app
export LOWTIDE_BUNDLE_ID=dev.lowtide.app.test-$NAME
ROOT=${0:A:h:h}
zsh $ROOT/scripts/build.sh >/tmp/lowtide-$NAME-build.log 2>&1 || { tail -20 /tmp/lowtide-$NAME-build.log; exit 1; }
pkill -f "$LOWTIDE_APP/Contents/MacOS/Lowtide" 2>/dev/null; sleep 1
open -n "$LOWTIDE_APP" --args --page $PAGE -ApplePersistenceIgnoreState YES
sleep ${WAIT:-6}
PID=$(pgrep -f "$LOWTIDE_APP/Contents/MacOS/Lowtide" | head -1)
zsh $ROOT/scripts/shot.sh $OUT "" $PID
[[ -n $KEEP ]] || kill $PID 2>/dev/null
