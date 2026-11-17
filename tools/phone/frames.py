"""Frame pacing of the test app while an action runs. Usage: frames.py SECONDS [action...]
Actions run in a thread: 'tap:REGEX' (label tap via ui.py), 'sleep:S'.
Polls SurfaceFlinger --latency every 0.4 s, dedupes frames, prints interval stats."""
import re, subprocess, sys, threading, time, os
here=os.path.dirname(os.path.abspath(__file__))
def sh(*a): return subprocess.run(['adb','shell',*a],capture_output=True).stdout.decode('utf8','replace')
layers=[l for l in sh('dumpsys','SurfaceFlinger','--list').splitlines() if 'SurfaceView[app.tomevoice.test/' in l and '(BLAST)' in l]
if not layers: print('no layer'); sys.exit(1)
layer=layers[-1].strip()
secs=float(sys.argv[1]); acts=sys.argv[2:]
def run():
    for a in acts:
        k,_,v=a.partition(':')
        if k=='tapmid': subprocess.run([sys.executable,'-I','-X','utf8',os.path.join(here,'ui.py'),'tapmid',v],capture_output=True)
        elif k=='tap': subprocess.run([sys.executable,'-I','-X','utf8',os.path.join(here,'ui.py'),'tap',v],capture_output=True)
        elif k=='sleep': time.sleep(float(v))
sh('dumpsys','SurfaceFlinger','--latency-clear')
t=threading.Thread(target=run); t.start()
seen={}; period=None; end=time.time()+secs
while time.time()<end:
    out=sh("dumpsys SurfaceFlinger --latency '"+layer+"'").splitlines()
    if out and out[0].strip().isdigit(): period=int(out[0])
    for l in out[1:]:
        p=l.split()
        if len(p)==3 and p[1]!='0' and int(p[1])<10**18: seen[int(p[1])]=1
    time.sleep(0.4)
t.join()
ts=sorted(seen); iv=[(b-a)/1e6 for a,b in zip(ts,ts[1:])]
per=(period or 8333333)/1e6
busy=[x for x in iv if x<4*per]  # frames inside dense animation
jank=[x for x in busy if x>1.5*per]
iv_s=sorted(busy)
def pc(q): return iv_s[min(len(iv_s)-1,int(q*len(iv_s)))] if iv_s else 0
print(f'layer={layer}\nperiod={per:.2f}ms frames={len(ts)} dense_intervals={len(busy)} janky(>1.5p)={len(jank)} p50={pc(.5):.1f} p90={pc(.9):.1f} p99={pc(.99):.1f} max={max(busy) if busy else 0:.1f}')
from collections import Counter
h=Counter(round(x/per) for x in iv)
print('intervals in frames (count):',' '.join(f'{k}:{h[k]}' for k in sorted(h) if k<=12))
