#!/bin/zsh
# Captures the windows that HubTests/HubScreensTests puts on screen.
# Usage: Scripts/capture-hub-screens.sh <dir>   (same dir as TEST_RUNNER_LUMEN_HUB_SCREENS_DIR)
# The test writes <dir>/req/<name>.id (a window number) and waits for <dir>/out/<name>.png.
# Needs Screen Recording permission for the terminal. Stops after 5 idle minutes.
dir=${1:?usage: capture-hub-screens.sh <dir>}
mkdir -p "$dir/req" "$dir/out"
idle=0
while [ $idle -lt 600 ]; do
  found=0
  for req in "$dir"/req/*.id(N); do
    found=1
    name=${req:t:r}
    id=$(<"$req")
    sleep 0.4
    screencapture -x -o -l"$id" "$dir/out/$name.tmp.png" && mv "$dir/out/$name.tmp.png" "$dir/out/$name.png"
    rm -f "$req"
    echo "captured $name (window $id)"
  done
  [ $found -eq 0 ] && { sleep 0.5; idle=$((idle + 1)); } || idle=0
done
