#!/bin/bash
# Watch the light HAL (dumpsys lights) and HiLight-related logs for N seconds.
#   hilight-watch.sh <seconds>
S=66020DLDV0049F; N=${1:-120}
out=~/Downloads/kodiak-evox/aod-flash/hilight-$(date +%H%M%S).txt
since=$(adb -s $S shell "date '+%m-%d %H:%M:%S.000'" | tr -d '\r')
(timeout $N adb -s $S logcat -T "$since" -v time > "$out.logcat" 2>/dev/null &)
end=$(( $(date +%s) + N )); last=""
while [ "$(date +%s)" -lt "$end" ]; do
    cur=$(adb -s $S shell dumpsys lights 2>/dev/null | grep -E "color=|Session|client|effect|Effect" | grep -v "color=00000000" | tr -d '\r')
    if [ "$cur" != "$last" ]; then echo "$(date +%T) ${cur:-<all lights off>}" | tee -a "$out"; last=$cur; fi
done
echo "== log lines mentioning lights:"
grep -iE "hilight|light_anim|lightanim|glow|LightsService|LightsManager|MultiLightEffect|lights-service|ILights" "$out.logcat" | cut -c1-220 | head -30
echo "files: $out $out.logcat"
