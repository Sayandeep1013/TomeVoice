"""Tap or list phone UI elements by label (uiautomator dump). Usage:
  ui.py list [regex]        list labelled nodes (optionally filtered)
  ui.py tap REGEX [n]       tap the n-th (0) node whose text/desc matches REGEX; exit 1 if none
"""
import re, subprocess, sys, xml.etree.ElementTree as ET
def dump():
    subprocess.run(['adb','shell','uiautomator','dump','/sdcard/tvui.xml'],capture_output=True,env={**__import__('os').environ,'MSYS_NO_PATHCONV':'1'})
    x=subprocess.run(['adb','exec-out','cat','/sdcard/tvui.xml'],capture_output=True).stdout.decode('utf8','replace')
    return ET.fromstring(x[x.index('<'):])
def nodes(root):
    for n in root.iter('node'):
        lab=(n.get('text') or '')+' | '+(n.get('content-desc') or '')
        if lab.strip(' |'):
            b=[int(v) for v in re.findall(r'\d+',n.get('bounds'))]
            yield lab.strip(), b, n.get('clickable')
cmd=sys.argv[1]
import os
want=os.environ.get('TV_PKG','app.tomevoice.test')
focus=subprocess.run(['adb','shell','dumpsys','window'],capture_output=True).stdout.decode('utf8','replace')
line=next((l for l in focus.splitlines() if 'mCurrentFocus' in l),'')
if cmd in ('tap','tapmid') and (want+'/') not in line:
    print('REFUSED: the window in front is not',want,'->',line.strip()); sys.exit(2)
root=dump()
if cmd=='list':
    pat=re.compile(sys.argv[2],re.S|re.I) if len(sys.argv)>2 else None
    for lab,b,c in nodes(root):
        if not pat or pat.search(lab): print(repr(lab[:90]), b, c)
elif cmd=='tapmid':
    pat=re.compile(sys.argv[2],re.S)
    hits=[(lab,b) for lab,b,c in nodes(root) if pat.search(lab)]
    if not hits: print('NOT FOUND',sys.argv[2]); sys.exit(1)
    lab,b=min(hits,key=lambda h: abs((h[1][1]+h[1][3])//2-1196))
    x=(b[0]+b[2])//2; y=(b[1]+b[3])//2
    subprocess.run(['adb','shell','input','tap',str(x),str(y)]); print('tapped',repr(lab[:60]),x,y)
elif cmd=='tap':
    pat=re.compile(sys.argv[2],re.S); k=int(sys.argv[3]) if len(sys.argv)>3 else 0
    hits=[(lab,b) for lab,b,c in nodes(root) if pat.search(lab)]
    if len(hits)<=k: print('NOT FOUND',sys.argv[2]); sys.exit(1)
    lab,b=hits[k]; x=(b[0]+b[2])//2; y=(b[1]+b[3])//2
    subprocess.run(['adb','shell','input','tap',str(x),str(y)]); print('tapped',repr(lab[:60]),x,y)
