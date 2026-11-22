#!/bin/zsh
# Runs every unit test, one at a time: several suites drive real processes,
# file events and timers that starve when hundreds of tests run at once.
# LOWTIDE_HOME keeps every test away from the real data, caches and logs.
ROOT=${0:A:h:h}
cd $ROOT
export LOWTIDE_HOME=${LOWTIDE_HOME:-$(mktemp -d -t lowtide-tests)}
xcrun swift test --no-parallel --scratch-path ${LOWTIDE_TEST_SCRATCH:-$HOME/Library/Developer/Lowtide/test} "$@" 2>&1 \
  | sed -E 's/\x1b\[[0-9;]*m//g' | grep -E "✘|Test run with|error:" | tail -${TAIL:-20}
# The test run's own status, not the filter's: CI fails when a test does.
exit ${pipestatus[1]}
