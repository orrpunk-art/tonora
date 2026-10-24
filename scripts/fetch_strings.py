#!/usr/bin/env python3
"""Bowed strings for Tonora from VS Chamber Orchestra 2: Community Edition (CC0): cello section below B2, violin section
from B2 up. Layers (the fifth column of index.txt): 0 sustain p, 1 sustain f, 2-5 spiccato (p take 1, p take 2,
f take 1, f take 2), 6-9 pizzicato (same order). WAV downloads are converted to FLAC with macOS afconvert."""
from concurrent.futures import ProcessPoolExecutor,ThreadPoolExecutor
from pathlib import Path
from urllib.request import urlopen
from urllib.parse import quote
import hashlib,json,math,struct,subprocess,tempfile,wave
COMMIT='440300901dfe9275fd84e0b7763af1f8443ae62e'
REPO='sgossner/VSCO-2-CE'
DEST=Path(__file__).resolve().parents[1]/'assets'/'Strings'
# VSCO names octaves one lower than scientific pitch (its cello C1 is MIDI 36, violin G2 is MIDI 55); verified by pitch detection.
CELLO=('C1','E1','G1','B1','D2','F2','A2'); VIOLINS=('B2','D3','F#3','A3','C4','E4','G4','B4','D5')
PITCH={'C':0,'D':2,'E':4,'F':5,'G':7,'A':9,'B':11}
def midi_of(note): return 12*(int(note[-1])+2)+PITCH[note[0]]+(1 if '#' in note else 0)
def plan():
    """(source path, output name, layer, note) for every recording."""
    out=[]
    for n in CELLO:
        m=midi_of(n)
        out.append((f'Strings/Cello Section/susvib/susvib_{n}_v1_1.wav',f'{m:03d}-cello.flac',0,n))   # 1.0 names kept
        out.append((f'Strings/Cello Section/susvib/susvib_{n}_v3_1.wav',f'{m:03d}-cello-f.flac',1,n))
        for i,(v,r) in enumerate(((1,1),(1,2),(2,1),(2,2))):
            out.append((f'Strings/Cello Section/spic/spic_{n}_v{v}_RR{r}.wav',f'{m:03d}-cello-spic-{v}{r}.flac',2+i,n))
            out.append((f'Strings/Cello Section/pizzT/pizzT_{n}_v{v}_RR{r}.wav',f'{m:03d}-cello-pizz-{v}{r}.flac',6+i,n))
    for n in VIOLINS:
        m=midi_of(n)
        out.append((f'Strings/Violin Section/susVib/VlnEns_susVib_{n}_v1.wav',f'{m:03d}-violins.flac',0,n))
        out.append((f'Strings/Violin Section/susVib/VlnEns_susVib_{n}_v2.wav',f'{m:03d}-violins-f.flac',1,n))
        for i,(v,r) in enumerate(((1,1),(1,2),(2,1),(2,2))):
            out.append((f'Strings/Violin Section/Spic/VlnEns_Spic_{n}_v{v}_rr{r}.wav',f'{m:03d}-violins-spic-{v}{r}.flac',2+i,n))
            out.append((f'Strings/Violin Section/Pizz/VlnEns_Pizz_{n}_v{v}_rr{r}.wav',f'{m:03d}-violins-pizz-{v}{r}.flac',6+i,n))
    return out
SUSTAIN=.03  # sustained RMS (seconds 2-6) of every sustain recording: just under the grand piano's first second
SHORT=.07    # loudest 50 ms RMS of every short note
SPEAKS=.5    # a sustain recording starts where its bow stroke reaches this share of its sustained level (minus 30 ms)
OLD={x['file']:x for x in json.loads((DEST/'manifest.json').read_text())['files']} if (DEST/'manifest.json').exists() else {}
def measure(flac,layer):
    """Gain and skip in seconds; mono analysis."""
    with tempfile.TemporaryDirectory() as tmp:
        out=Path(tmp)/'m.wav'; subprocess.run(['afconvert','-f','WAVE','-d','LEI16@44100','-c','1',str(flac),str(out)],check=True)
        w=wave.open(str(out)); n=w.getnframes(); x=struct.unpack('<%dh'%n,w.readframes(n))
    rms=lambda a,b: math.sqrt(sum(v*v for v in x[a:b])/max(1,b-a))/32768
    if layer<2:
        level=rms(2*44100,6*44100); onset=next(i for i in range(0,n-441,441) if rms(i,i+441)>=SPEAKS*level)
        return round(SUSTAIN/level,3),round(max(0,onset/44100-.03),3)
    peak=max(rms(i,i+2205) for i in range(0,max(1,n-2205),441))
    return round(SHORT/peak,3),0.0
def fetch(item):
    path,name,layer,note=item; url=f'https://raw.githubusercontent.com/{REPO}/{COMMIT}/{quote(path)}'; out=DEST/name
    if not out.exists():
        with urlopen(url,timeout=120) as r: data=r.read()
        if data[:4]!=b'RIFF' or data[8:12]!=b'WAVE': raise ValueError(path)
        with tempfile.TemporaryDirectory() as tmp:
            wav=Path(tmp)/'in.wav'; wav.write_bytes(data)
            subprocess.run(['afconvert','-f','flac','-d','flac',str(wav),str(out)],check=True)
        source=hashlib.sha256(data).hexdigest()
    else: source=OLD.get(name,{}).get('source_sha256')
    gain,skip=measure(out,layer)
    return {'file':name,'midi':midi_of(note),'layer':layer,'gain':gain,'skip':skip,'cents':0,'source':path,'source_sha256':source,'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),'url':url}
def tuning(entry):
    """Cents the recording is off its note (autocorrelation within ±1.5 semitones of the expected period, the steadiest of
    several windows). 0 when the measurement is unsure (correlation < 0.8) or the recording is within 8 cents."""
    with tempfile.TemporaryDirectory() as tmp:
        out=Path(tmp)/'m.wav'; subprocess.run(['afconvert','-f','WAVE','-d','LEI16@44100','-c','1',str(DEST/entry['file']),str(out)],check=True)
        w=wave.open(str(out)); n=w.getnframes(); x=[v/32768 for v in struct.unpack('<%dh'%n,w.readframes(n))]
    period=44100/(440*2**((entry['midi']-69)/12)); lo=int(period*2**(-1.5/12)); hi=int(period*2**(1.5/12))+1
    def corr(seg,lag):
        k=len(seg)-lag; a=sum(seg[i]*seg[i+lag] for i in range(k)); e=math.sqrt(sum(seg[i]**2 for i in range(k))*sum(seg[i+lag]**2 for i in range(k)))
        return a/e if e else 0
    first=next((i for i,v in enumerate(x) if abs(v)>.002),0)
    starts=[2*44100] if entry['layer']<2 else [first+int(t*44100) for t in (.02,.05,.1,.2)]
    best=(0,0)
    for start in starts:
        for size in ((6000,) if entry['layer']<2 else (2048,4096,8192)):
            seg=x[start:start+size]
            if len(seg)<hi*2: continue
            cs={lag:corr(seg,lag) for lag in range(lo,hi+1)}; lag=max(cs,key=cs.get); frac=0
            if lo<lag<hi: y0,y1,y2=cs[lag-1],cs[lag],cs[lag+1]; d=y0-2*y1+y2; frac=.5*(y0-y2)/d if d else 0
            if cs[lag]>best[0]: best=(cs[lag],1200*math.log2(period/(lag+frac)))
    return round(best[1]) if best[0]>=.8 and abs(best[1])>8 else 0
if __name__=='__main__':
  DEST.mkdir(parents=True,exist_ok=True)
  with ThreadPoolExecutor(max_workers=6) as pool: files=sorted(pool.map(fetch,plan()),key=lambda x:(x['layer'],x['midi']))
  with ProcessPoolExecutor() as pool: cents=list(pool.map(tuning,files))
  for x,c in zip(files,cents): x['cents']=c
  (DEST/'index.txt').write_text(''.join(f"{x['midi']} {x['file']} {x['gain']} {x['skip']} {x['layer']} {x['cents']}\n" for x in files))
  (DEST/'manifest.json').write_text(json.dumps({'repository':REPO,'commit':COMMIT,'layers':['sustain p','sustain f','spiccato p 1','spiccato p 2','spiccato f 1','spiccato f 2','pizzicato p 1','pizzicato p 2','pizzicato f 1','pizzicato f 2'],'files':files},indent=2)+'\n')
  (DEST/'ATTRIBUTION.txt').write_text(f'Strings — VS Chamber Orchestra 2: Community Edition, Versilian Studios (Sam Gossner, Simon Dalzell; sample cutting Elan Hickler).\nCC0 1.0 Universal (public domain): https://creativecommons.org/publicdomain/zero/1.0/\nhttps://github.com/{REPO}\nPinned commit: {COMMIT}\nCello section and violin section: sustain vibrato (soft and loud), spiccato and pizzicato (two dynamics, two takes); converted to FLAC, level-matched, looped and enveloped during playback.\nNo author endorsement implied.\n')
  print(len(files),'recordings in',DEST)
