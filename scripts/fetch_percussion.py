#!/usr/bin/env python3
"""Percussion for Tonora's acoustic beats from the Versilian Community Sample Library (CC0). Notes follow General MIDI
drums; layers (the fifth column of index.txt): 0-1 soft (two takes), 2-3 loud (two takes) — a sound with fewer
recordings repeats them. Each recording starts at its hit, is cut to its useful length with a short fade, converted to
FLAC with macOS afconvert and level-matched by role (the loud layer sets the gain, the soft layer keeps its own level)."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.request import urlopen
from urllib.parse import quote
import hashlib,json,math,struct,subprocess,tempfile,wave
COMMIT='c1ea7bcc3c7309650ab0da9d15c9cd1fbc4a4c7e'
REPO='sgossner/VCSL'
DEST=Path(__file__).resolve().parents[1]/'assets'/'Percussion'
S='Idiophones/Struck Idiophones/'; M='Membranophones/Struck Membranophones/'
# note, name, seconds kept, loudest 10 ms RMS of the loud layer, (soft take 1, soft take 2, loud take 1, loud take 2).
# The cajon's hit2 is its bass tone (79 % of the energy below 200 Hz), hit1 the slap (29 %): measured, the names do not say.
KIT=[
    (36,'cajon-bass',1.0,.30,[S+'Cajon/Cajon_hit2_mp_rr1.wav',S+'Cajon/Cajon_hit2_mp_rr2.wav',S+'Cajon/Cajon_hit2_f_rr1.wav',S+'Cajon/Cajon_hit2_f_rr2.wav']),
    (37,'side-stick',.5,.18,[M+'Snare Drum, Modern 1/Snare2_stick_v1_rr1_Mid.wav',M+'Snare Drum, Modern 1/Snare2_stick_v1_rr2_Mid.wav']*2),
    (38,'cajon-slap',.8,.24,[S+'Cajon/Cajon_hit1_mp_rr1.wav',S+'Cajon/Cajon_hit1_mp_rr2.wav',S+'Cajon/Cajon_hit1_f_rr1.wav',S+'Cajon/Cajon_hit1_f_rr2.wav']),
    (39,'clap',.6,.20,[S+'Claps/Clap_rr1.wav',S+'Claps/Clap_rr2.wav',S+'Claps/Clap_rr3.wav',S+'Claps/Clap_rr4.wav']),
    (42,'hihat-closed',.5,.12,[S+'Hi-Hat Cymbal/HiHat_HitC_v2_rr1_Mid.wav',S+'Hi-Hat Cymbal/HiHat_HitC_v2_rr2_Mid.wav',S+'Hi-Hat Cymbal/HiHat_HitC_v4_rr1_Mid.wav',S+'Hi-Hat Cymbal/HiHat_HitC_v4_rr2_Mid.wav']),
    (46,'hihat-open',1.5,.12,[S+'Hi-Hat Cymbal/HiHat_HitO_rr1_Mid.wav']*4),
    (54,'tambourine',.8,.12,[S+'Tambourine 1/Tamb1_Hit_v1_rr1_Mid.wav']*2+[S+'Tambourine 1/Tamb1_Hit_v2_rr1_Mid.wav']*2),
    (63,'conga-high',.8,.20,[M+'Conga/Conga_HitN_v1_rr1_Sum.wav',M+'Conga/Conga_HitN_v1_rr2_Sum.wav',M+'Conga/Conga_HitN_v3_rr1_Sum.wav',M+'Conga/Conga_HitN_v3_rr2_Sum.wav']),
    (64,'conga-low',.9,.20,[M+'Conga/Tumba_HitN_v2_rr1_Sum.wav',M+'Conga/Tumba_HitN_v2_rr2_Sum.wav',M+'Conga/Tumba_HitN_v4_rr1_Sum.wav',M+'Conga/Tumba_HitN_v4_rr2_Sum.wav']),
    (70,'shaker',.35,.10,[S+'Shaker, Small/Mid_ShakerDouble_Up_rr1.wav',S+'Shaker, Small/Mid_ShakerDouble_Up_rr2.wav',S+'Shaker, Small/Mid_ShakerDouble_Down_rr1.wav',S+'Shaker, Small/Mid_ShakerDouble_Down_rr2.wav']),
]
def frames_of(path):
    """Interleaved 16-bit stereo at 44.1 kHz."""
    with tempfile.TemporaryDirectory() as tmp:
        out=Path(tmp)/'s.wav'; subprocess.run(['afconvert','-f','WAVE','-d','LEI16@44100','-c','2',str(path),str(out)],check=True)
        w=wave.open(str(out)); n=w.getnframes(); return list(struct.unpack('<%dh'%(n*2),w.readframes(n)))
def loudest(x):
    """Loudest 10 ms RMS (both channels), 0…1."""
    best=0
    for i in range(0,max(1,len(x)//2-441),110):
        seg=x[i*2:(i+441)*2]; best=max(best,math.sqrt(sum(v*v for v in seg)/max(1,len(seg)))/32768)
    return best
def prepare(item):
    """Download one source once, cut it at its hit (2 ms before the first sample over 5 % of the peak) to its length with
    a 40 ms fade, and write FLAC. Returns its facts."""
    source,name,seconds=item; out=DEST/name
    url=f'https://raw.githubusercontent.com/{REPO}/{COMMIT}/{quote(source)}'
    with urlopen(url,timeout=120) as r: data=r.read()
    if data[:4]!=b'RIFF' or data[8:12]!=b'WAVE': raise ValueError(source)
    with tempfile.TemporaryDirectory() as tmp:
        src=Path(tmp)/'in.wav'; src.write_bytes(data); x=frames_of(src)
        peak=max(abs(v) for v in x); first=next(i for i,v in enumerate(x) if abs(v)>.05*peak)//2
        start=max(0,first-88); n=min(len(x)//2-start,int(seconds*44100)); fade=1764
        y=x[start*2:(start+n)*2]
        for i in range(max(0,n-fade),n): k=(n-i)/fade; y[i*2]=int(y[i*2]*k); y[i*2+1]=int(y[i*2+1]*k)
        cut=Path(tmp)/'cut.wav'; w=wave.open(str(cut),'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100); w.writeframes(struct.pack('<%dh'%len(y),*y)); w.close()
        subprocess.run(['afconvert','-f','flac','-d','flac',str(cut),str(out)],check=True)
        level=loudest(y)
    return {'file':name,'source':source,'source_sha256':hashlib.sha256(data).hexdigest(),'url':url,'level':level,'sha256':hashlib.sha256(out.read_bytes()).hexdigest()}
def plan():
    """One output file per distinct source of each sound; every layer names its file."""
    jobs,layers=[],[]
    for note,name,seconds,target,sources in KIT:
        files={}
        for layer,source in enumerate(sources):
            if source not in files:
                files[source]=f'{note:03d}-{name}-{len(files)+1}.flac'; jobs.append((source,files[source],seconds))
            layers.append((note,name,target,layer,files[source]))
    return jobs,layers
if __name__=='__main__':
    DEST.mkdir(parents=True,exist_ok=True)
    for old in DEST.glob('*.flac'): old.unlink()
    jobs,layers=plan()
    with ThreadPoolExecutor(max_workers=6) as pool: facts={f['file']:f for f in pool.map(prepare,jobs)}
    lines,files,gains=[],[],{}
    for note,name,target,layer,file in layers:   # the loudest layer of a sound sets its gain
        if layer>=2: gains[note]=max(gains.get(note,0),facts[file]['level'])
    for note,name,target,layer,file in layers:
        gain=round(min(16,target/gains[note]),3) if gains[note]>0 else 1
        lines.append(f'{note} {file} {gain} 0 {layer} 0\n')
    for f in sorted(facts.values(),key=lambda f:f['file']):
        files.append({k:f[k] for k in ('file','source','source_sha256','sha256','url')})
    (DEST/'index.txt').write_text(''.join(lines))
    (DEST/'manifest.json').write_text(json.dumps({'repository':REPO,'commit':COMMIT,'layers':['soft 1','soft 2','loud 1','loud 2'],
        'sounds':{str(n):nm for n,nm,*_ in KIT},'files':files},indent=2)+'\n')
    (DEST/'ATTRIBUTION.txt').write_text(f'Percussion — Versilian Community Sample Library (VCSL), Versilian Studios (Sam Gossner and contributors).\nCC0 1.0 Universal (public domain): https://creativecommons.org/publicdomain/zero/1.0/\nhttps://github.com/{REPO}\nPinned commit: {COMMIT}\nCajon (bass and slap), snare side stick, claps, closed and open hi-hat, tambourine, conga and tumba, small shaker; cut at the hit, shortened with a fade, converted to FLAC and level-matched.\nNo author endorsement implied.\n')
    print(len(files),'recordings,',len(lines),'layers in',DEST)
