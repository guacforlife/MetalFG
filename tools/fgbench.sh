#!/bin/zsh
# fgbench.sh DEV OUT.tsv "native:fg:preset" ...   e.g. fgbench.sh ip14 r.tsv 45:off:1 45:on:1 60:on:0
# Per config: MetalFG settings file + reload, Unity targetFrameRate via the TrumpetDismiss Lua console,
# 15 s settle, then a 60 s window (WIN=secs): MetalFG stats (native/shown fps, pacing) + pstat (game CPU/mW,
# GPU, thermal, whole-phone power from the battery gauge's system load). Needs TrumpetDismiss (Lua console) in
# the game, the guac pstat tool on the phone, and TrumpetDismiss's frame-rate throttle switched off.
DEV=$1; OUT=$2; shift 2
S=$(mktemp -d); trap 'rm -rf $S' EXIT   # scratch files for the settings plist and the Lua chunk
TD=~/github/guac/TrumpetDismiss
PASS=$(security find-generic-password -s trollstore -a $DEV -w)
C=$(ssh $DEV 'ls -t /rootfs/private/var/mobile/Containers/Data/Application/*/tmp/.trumpetdismiss.log | head -1')
C=${C%/tmp/.trumpetdismiss.log}
[[ -n $C ]] || { echo "no game container on $DEV"; exit 1; }
SETTLE=${SETTLE:-15}; WIN=${WIN:-60}
[[ -f $OUT ]] || print -r -- $'native_target\tfg\tpreset\tnative_fps\tshown_fps\tint_mean_ms\tint_sd_ms\tint_max_ms\tb10\tb19\tb27\tb27plus\tgame_cpu\tgame_mW\tgpu_pct\tthermal\tbatt_C\ttd_fps\tfg_state\tgpu_err\tsys_mW' > $OUT

for cfg in "$@"; do
  IFS=: read native fg preset <<< "$cfg"
  case $preset in
    0) m=0.50 g=0.14 u=0.038 z=0.0004 ;;
    2) m=0.50 g=0.24 u=0.028 z=0.0002 ;;
    *) m=0.50 g=0.18 u=0.035 z=0.0003 ;;
  esac
  en=$([[ $fg == on ]] && echo true || echo false)
  cat > $S/mfg.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>prefsVersion</key><string>2.3.0</string><key>isEnabled</key><$en/><key>currentPreset</key><integer>$preset</integer>
<key>motionScale</key><real>$m</real><key>disocclusionThreshold</key><real>$g</real>
<key>uiSensitivity</key><real>$u</real><key>motionDeadzone</key><real>$z</real><key>debugTint</key><false/>
</dict></plist>
EOF
  scp -q $S/mfg.plist $DEV:/var/tmp/mfg.plist
  ssh $DEV "echo '$PASS' | sudo -S sh -c 'mkdir -p $C/Library/Preferences; cp /var/tmp/mfg.plist $C/Library/Preferences/com.dnullptr.metalfg.plist; chown 501:501 $C/Library/Preferences/com.dnullptr.metalfg.plist' 2>/dev/null; notifyutil -p com.dnullptr.metalfg.reload"
  print -r -- "CS.UnityEngine.Application.targetFrameRate = $native
return 'target ' .. CS.UnityEngine.Application.targetFrameRate" > $S/fps.lua
  TD_DEV=$DEV zsh $TD/tools/tdlua.sh $S/fps.lua | grep -o 'target [0-9]*' | head -1
  sleep $SETTLE
  ssh $DEV "notifyutil -p com.dnullptr.metalfg.stats"
  ps_out=$(ssh $DEV "/usr/local/bin/pstat -i $WIN ZRouteRedemption")
  print -r -- "== $cfg $(date -u +%H:%M:%S)
$ps_out" >> ${OUT%.tsv}-pstat.log
  ssh $DEV "notifyutil -p com.dnullptr.metalfg.stats"
  sleep 1
  td=$(ssh $DEV "notifyutil -g com.az.trumpetdismiss.fps" | awk '{print $2}')
  win=$(ssh $DEV "echo '$PASS' | sudo -S grep 'window ' $C/tmp/.metalfg.log 2>/dev/null | tail -1")
  row=$(python3 -I - "$win" "$ps_out" <<'PY'
import re, sys
w, p = sys.argv[1], sys.argv[2]
def f(rx, s, n=1):
    m = re.search(rx, s); return m.groups() if m else ('?',) * n
nat, shown = f(r'native ([\d.]+) fps, shown ([\d.]+) fps', w, 2)
mean, sd, mx = f(r'mean ([\d.]+) ms sd ([\d.]+) max ([\d.]+)', w, 3)
b = f(r'<=10ms (\d+) <=19ms (\d+) <=27ms (\d+) >27ms (\d+)', w, 4)
cpu, mw = f(r'\d+\s+([\d.]+)\s+(\d+)\s+\d+\s+ZRouteRedemption', p, 2)
gpu, = f(r'gpu: device ([\d.]+)%', p)
th, = f(r'thermal: (\S+)', p)
bc, = f(r'([\d.]+) C\s*$', p)
fgs, ge = f(r'\| FG (\w+) preset \d+ \| gpu errors (\d+)', w, 2)
sysw, = f(r'system load ([\d.]+) mW mean', p)
print('\t'.join([nat, shown, mean, sd, mx, *b, cpu, mw, gpu, th, bc]) + '\x01' + fgs + '\t' + ge + '\t' + sysw)
PY
)
  print -r -- "$native	$fg	$preset	${row%%$'\x01'*}	$td	${row#*$'\x01'}" | tee -a $OUT
done
