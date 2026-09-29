#!/bin/bash
# Runs a command while reporting, every minute, what it is doing: the tail
# of the unit-test log and the live build/test processes. After 8 minutes it
# also samples the test host, so a hang shows where it is stuck.
"$@" &
CMD=$!
START=$SECONDS
SAMPLED=0
while kill -0 "$CMD" 2>/dev/null; do
  sleep 60
  kill -0 "$CMD" 2>/dev/null || break
  ELAPSED=$((SECONDS - START))
  echo "::group::heartbeat ${ELAPSED}s"
  tail -n 15 /tmp/ccterm-utest-*/raw.log 2>/dev/null
  echo "--- processes"
  ps -axo pid,etime,%cpu,command | grep -E "xcodebuild|ccterm.app|xctest|swift-frontend|testmanagerd|SWBBuildService" | grep -v grep | cut -c1-200
  echo "::endgroup::"
  if [ "$ELAPSED" -ge 480 ] && [ "$SAMPLED" -eq 0 ]; then
    SAMPLED=1
    for pid in $(pgrep -f "ccterm.app/Contents/MacOS/ccterm"); do
      echo "::group::sample $pid"
      sample "$pid" 3 2>&1 | head -n 120
      echo "::endgroup::"
    done
  fi
done
wait "$CMD"
