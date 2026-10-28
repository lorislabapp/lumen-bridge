#!/bin/zsh
# Mac App Store screenshots for Lumen Bridge (MAS build, fixture data only).
# usage: Scripts/store-screenshots/capture.sh <out-dir> <lang: en|fr> <region: US|FR>
# Needs Screen Recording permission for the terminal (screencapture -l).
# Renders HubTests/AppStoreScreenshotTests in hold mode and grabs each real
# 1440x900 window (2880x1800 px), then removes the alpha channel.
set -eu
here=${0:A:h}; repo=${here:h:h}; out=$1; lang=$2; region=$3
work=$out/work-$lang; mkdir -p $work/raw $out/$lang
swiftc -O $here/winlist.swift -o $work/winlist
swiftc -O $here/flatten.swift -o $work/flatten
names=(01-home 02-zone-alerts 03-homekit)
(
  seen=(); n=0; end=$((SECONDS+900))
  while (( n < ${#names} && SECONDS < end )); do
    for line in "${(@f)$($work/winlist)}"; do
      id=${line%% *}; [[ ${line#* } == 1440x900 ]] || continue
      (( ${seen[(Ie)$id]} )) && continue
      seen+=$id; sleep 2.5; n=$((n+1))
      screencapture -o -x -l $id $work/raw/${names[$n]}.png
    done
    sleep 0.3
  done
) &
poller=$!
TEST_RUNNER_LUMEN_STORE_SCREENSHOTS=1 TEST_RUNNER_LUMEN_STORE_SCREENSHOTS_HOLD=6 \
  xcodebuild test -project $repo/LumenBridge.xcodeproj -scheme LumenBridge -destination 'platform=macOS' \
  -only-testing:LumenBridgeTests/AppStoreScreenshotTests -testLanguage $lang -testRegion $region \
  -resultBundlePath $work/result.xcresult > $work/test.log 2>&1
wait $poller
for f in $work/raw/*.png; do $work/flatten $f $out/$lang/${f:t}; done
ls $out/$lang
