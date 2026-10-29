#!/bin/zsh
# fgbench-tdrates.sh DEV OUT.tsv "state:fg" ...   e.g. fgbench-tdrates.sh ip7p r.tsv idle:off idle:on touch:on
# Leaves TrumpetDismiss's frame-rate throttle ON: state = idle (no touch: TD's on-screen rate) or touch (a hidtap
# drag every ~4 s: TD's touching rate); fg = on/off. Per config: MetalFG settings + reload, 15 s settle, then a WIN s
# window with MetalFG stats (native/shown fps, pacing) and pstat (game and all-process CPU, GPU, thermal) plus the
# game's footprint. For phones where pstat has no power reading (iPhone 7 Plus: no task energy, no gauge telemetry).
# Needs /var/tmp/mfg-on.plist and /var/tmp/mfg-off.plist (whole MetalFG settings files) on the phone, hidtap 0.3.0+.
DEV=$1; OUT=$2; shift 2
PASS=$(security find-generic-password -s trollstore -a $DEV -w)
C=$(ssh $DEV 'ls -t /rootfs/private/var/mobile/Containers/Data/Application/*/tmp/.trumpetdismiss.log | head -1')
C=${C%/tmp/.trumpetdismiss.log}
[[ -n $C ]] || { echo "no game container on $DEV"; exit 1; }
WIN=${WIN:-90}
[[ -f $OUT ]] || print -r -- $'state\tfg\tnative_fps\tshown_fps\tint_mean_ms\tint_sd_ms\tb10\tb19\tb27\tb27plus\tgame_cpu\tall_cpu\tgpu_pct\tthermal\tfoot_MB\tfg_state\tpaused' > $OUT
for cfg in "$@"; do
  IFS=: read state fg <<< "$cfg"
  ssh $DEV "echo '$PASS' | sudo -S sh -c 'cp /var/tmp/mfg-$fg.plist $C/Library/Preferences/com.dnullptr.metalfg.plist; chown 501:501 $C/Library/Preferences/com.dnullptr.metalfg.plist' 2>/dev/null; notifyutil -p com.dnullptr.metalfg.reload"
  out=$(ssh $DEV "
    drag() { hidtap drag 0.30 0.50 0.70 0.52 500; sleep 1; hidtap drag 0.70 0.52 0.30 0.50 500; sleep 2; }
    end=\$((\$(date +%s)+15)); while [ \$(date +%s) -lt \$end ]; do if [ $state = touch ]; then drag; else sleep 1; fi; done
    notifyutil -p com.dnullptr.metalfg.stats
    /usr/local/bin/pstat -i $WIN ZRouteRedemption > /var/tmp/ps7.txt 2>&1 &
    end=\$((\$(date +%s)+$WIN)); while [ \$(date +%s) -lt \$end ]; do if [ $state = touch ]; then drag; else sleep 1; fi; done
    wait
    notifyutil -p com.dnullptr.metalfg.stats; sleep 1
    echo '$PASS' | sudo -S grep 'window ' $C/tmp/.metalfg.log 2>/dev/null | tail -1
    cat /var/tmp/ps7.txt
    ps -A -o foot,command | grep -E 'ZRouteRedemption\$' | grep -v grep | awk '{print \"foot\", \$1}'")
  print -r -- "== $cfg $(date -u +%H:%M:%S)
$out" >> ${OUT%.tsv}-raw.log
  row=$(python3 -I - "$out" <<'PY'
import re, sys
o = sys.argv[1]
def f(rx, n=1):
    m = re.search(rx, o); return m.groups() if m else ('?',) * n
nat, shown = f(r'native ([\d.]+) fps, shown ([\d.]+) fps', 2)
mean, sd = f(r'mean ([\d.]+) ms sd ([\d.]+)', 2)
b = f(r'<=10ms (\d+) <=19ms (\d+) <=27ms (\d+) >27ms (\d+)', 4)
cpu, = f(r'\d+\s+([\d.]+)\s+\d+\s+\d+\s+ZRouteRedemption')
allcpu, = f(r'all processes: CPU ([\d.]+)%')
gpu, = f(r'gpu: device ([\d.]+)%')
th, = f(r'thermal: (\S+)')
foot, = f(r'foot (\d+)')
fgs, = f(r'\| FG (\w+) preset')
ps_, pf = f(r'paused slow (\d+) fast (\d+)', 2)
footmb = str(round(int(foot) / 1024)) if foot != '?' else '?'
print('\t'.join([nat, shown, mean, sd, *b, cpu, allcpu, gpu, th, footmb, fgs, ps_ + '/' + pf]))
PY
)
  print -r -- "$state	$fg	$row" | tee -a $OUT
done
