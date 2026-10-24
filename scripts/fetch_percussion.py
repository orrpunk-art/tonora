#!/usr/bin/env python3
"""Drums for Tonora's beats, both libraries CC0. The kit — kick, snare, side stick, closed and open hi-hat — is Karoryfer's
Big Rusty Drums (a 24" kick, a 14" snare and hi-hat), each hit mixed to stereo from its own microphone and the overheads.
Hand percussion — claps, tambourine, conga and tumba, shaker — is the Versilian Community Sample Library.
Notes follow General MIDI drums; layers (the fifth column of index.txt): 0-1 soft (two takes), 2-3 loud (two takes).
Each hit starts at its attack, is cut to its useful length with a 40 ms fade, converted to FLAC with macOS afconvert and
level-matched by role (the loud layer sets the gain, the soft layer keeps its own level)."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.request import urlopen
from urllib.parse import quote
import hashlib,json,math,struct,subprocess,tempfile,wave
SOURCES={
    'rusty':('sfzinstruments/karoryfer.big-rusty-drums','f07ce00df34a46b6b08375be56fe116cf15782bc','Samples/'),
    'vcsl':('sgossner/VCSL','c1ea7bcc3c7309650ab0da9d15c9cd1fbc4a4c7e',''),
}
DEST=Path(__file__).resolve().parents[1]/'assets'/'Percussion'
def rusty(folder,stem,mics,soft,loud):
    """Four layers of a Big Rusty articulation: soft and loud velocity layer, takes 1 and 2; each a mix of microphones."""
    return [[('rusty',f'{folder}/{mic}/{stem}_vl{v}_rr{r}.flac',gain) for mic,gain in mics] for v in (soft,loud) for r in (1,2)]
def vcsl(*paths): return [[('vcsl',p,1.0)] for p in paths]
S='Idiophones/Struck Idiophones/'; M='Membranophones/Struck Membranophones/'
# note, name, seconds kept, loudest 10 ms RMS of the loud layer, layers (soft 1, soft 2, loud 1, loud 2), each a list of
# (source, path, gain) mixed together. The overheads bring the kit's room; the close microphone its body and low end.
KIT=[
    (36,'kick',1.0,.36,rusty('kick_24/kick','k',(('kick',1.0),('oh',.5)),8,13)),
    (37,'side-stick',.5,.18,rusty('snare_14/sidestick','sn_ss',(('top',1.0),('oh',.6)),2,4)),
    (38,'snare',.8,.28,rusty('snare_14/center','sn_center',(('top',1.0),('oh',.6)),5,9)),
    (39,'clap',.6,.20,vcsl(S+'Claps/Clap_rr1.wav',S+'Claps/Clap_rr2.wav',S+'Claps/Clap_rr3.wav',S+'Claps/Clap_rr4.wav')),
    (42,'hihat-closed',.5,.12,rusty('hihat_14/cl','ht_cl',(('cl',1.0),('oh',.5)),3,5)),
    (46,'hihat-open',1.5,.12,rusty('hihat_14/open','ht_open',(('cl',1.0),('oh',.5)),3,5)),
    (54,'tambourine',.8,.12,vcsl(*[S+'Tambourine 1/Tamb1_Hit_v1_rr1_Mid.wav']*2,*[S+'Tambourine 1/Tamb1_Hit_v2_rr1_Mid.wav']*2)),
    (63,'conga-high',.8,.20,vcsl(M+'Conga/Conga_HitN_v1_rr1_Sum.wav',M+'Conga/Conga_HitN_v1_rr2_Sum.wav',M+'Conga/Conga_HitN_v3_rr1_Sum.wav',M+'Conga/Conga_HitN_v3_rr2_Sum.wav')),
    (64,'conga-low',.9,.20,vcsl(M+'Conga/Tumba_HitN_v2_rr1_Sum.wav',M+'Conga/Tumba_HitN_v2_rr2_Sum.wav',M+'Conga/Tumba_HitN_v4_rr1_Sum.wav',M+'Conga/Tumba_HitN_v4_rr2_Sum.wav')),
    (70,'shaker',.35,.10,vcsl(S+'Shaker, Small/Mid_ShakerDouble_Up_rr1.wav',S+'Shaker, Small/Mid_ShakerDouble_Up_rr2.wav',S+'Shaker, Small/Mid_ShakerDouble_Down_rr1.wav',S+'Shaker, Small/Mid_ShakerDouble_Down_rr2.wav')),
]
def url_of(source,path): repo,commit,root=SOURCES[source]; return f'https://raw.githubusercontent.com/{repo}/{commit}/{quote(root+path)}'
def stereo(data):
    """Interleaved 16-bit stereo at 44.1 kHz (a mono microphone on both sides) of a downloaded file, as floats."""
    with tempfile.TemporaryDirectory() as tmp:
        src=Path(tmp)/'in'; src.write_bytes(data); out=Path(tmp)/'s.wav'
        subprocess.run(['afconvert','-f','WAVE','-d','LEI16@44100','-c','2',str(src),str(out)],check=True)
        w=wave.open(str(out)); n=w.getnframes(); return [v/32768 for v in struct.unpack('<%dh'%(n*2),w.readframes(n))]
def loudest(x):
    """Loudest 10 ms RMS (both channels), 0…1."""
    best=0
    for i in range(0,max(1,len(x)//2-441),110):
        seg=x[i*2:(i+441)*2]; best=max(best,math.sqrt(sum(v*v for v in seg)/max(1,len(seg))))
    return best
def prepare(item):
    """Download a layer's microphones, mix them, cut at the attack (2 ms before the first sample over 5 % of the peak) to
    its length with a 40 ms fade, and write FLAC. Returns its facts."""
    mics,name,seconds=item; out=DEST/name; mix=[]; sources=[]
    for source,path,gain in mics:
        url=url_of(source,path)
        with urlopen(url,timeout=120) as r: data=r.read()
        sources.append({'source':f'{SOURCES[source][0]}/{SOURCES[source][2]}{path}','gain':gain,'source_sha256':hashlib.sha256(data).hexdigest(),'url':url})
        x=stereo(data); mix=[a+b*gain for a,b in zip(mix,x)]+[b*gain for b in x[len(mix):]] if mix else [b*gain for b in x]
    peak=max(abs(v) for v in mix); first=next(i for i,v in enumerate(mix) if abs(v)>.05*peak)//2
    start=max(0,first-88); n=min(len(mix)//2-start,int(seconds*44100)); fade=1764; y=mix[start*2:(start+n)*2]
    for i in range(max(0,n-fade),n): k=(n-i)/fade; y[i*2]*=k; y[i*2+1]*=k
    scale=min(1,.98/max(abs(v) for v in y))   # a mix of microphones may go over full scale: bring it under
    pcm=[max(-32767,min(32767,int(v*scale*32767))) for v in y]
    with tempfile.TemporaryDirectory() as tmp:
        cut=Path(tmp)/'cut.wav'; w=wave.open(str(cut),'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100); w.writeframes(struct.pack('<%dh'%len(pcm),*pcm)); w.close()
        subprocess.run(['afconvert','-f','flac','-d','flac',str(cut),str(out)],check=True)
    return {'file':name,'mix':sources,'level':loudest([v*scale for v in y]),'sha256':hashlib.sha256(out.read_bytes()).hexdigest()}
def plan():
    """One output file per distinct layer mix of each sound; every layer names its file."""
    jobs,layers=[],[]
    for note,name,seconds,target,mixes in KIT:
        files={}
        for layer,mics in enumerate(mixes):
            key=tuple(mics)
            if key not in files:
                files[key]=f'{note:03d}-{name}-{len(files)+1}.flac'; jobs.append((mics,files[key],seconds))
            layers.append((note,target,layer,files[key]))
    return jobs,layers
if __name__=='__main__':
    DEST.mkdir(parents=True,exist_ok=True)
    for old in DEST.glob('*.flac'): old.unlink()
    jobs,layers=plan()
    with ThreadPoolExecutor(max_workers=6) as pool: facts={f['file']:f for f in pool.map(prepare,jobs)}
    gains,lines={},[]
    for note,target,layer,file in layers:   # the loudest layer of a sound sets its gain
        if layer>=2: gains[note]=max(gains.get(note,0),facts[file]['level'])
    for note,target,layer,file in layers:
        lines.append(f'{note} {file} {round(min(16,target/gains[note]),3)} 0 {layer} 0\n')
    (DEST/'index.txt').write_text(''.join(lines))
    (DEST/'manifest.json').write_text(json.dumps({'sources':{k:{'repository':r,'commit':c} for k,(r,c,_) in SOURCES.items()},
        'layers':['soft 1','soft 2','loud 1','loud 2'],'sounds':{str(n):nm for n,nm,*_ in KIT},
        'files':[{k:f[k] for k in ('file','mix','sha256')} for f in sorted(facts.values(),key=lambda f:f['file'])]},indent=2)+'\n')
    (DEST/'ATTRIBUTION.txt').write_text(
        'Drum kit — Big Rusty Drums, Karoryfer Samples (Dawid Bebenek).\nCC0 1.0 Universal (public domain): https://creativecommons.org/publicdomain/zero/1.0/\n'
        f'https://github.com/{SOURCES["rusty"][0]}\nPinned commit: {SOURCES["rusty"][1]}\n'
        '24" kick, 14" snare (centre hit and side stick), 14" hi-hat (closed and open); close microphone and overheads mixed to stereo.\n\n'
        'Hand percussion — Versilian Community Sample Library (VCSL), Versilian Studios (Sam Gossner and contributors).\n'
        f'CC0 1.0 Universal (public domain).\nhttps://github.com/{SOURCES["vcsl"][0]}\nPinned commit: {SOURCES["vcsl"][1]}\n'
        'Claps, tambourine, conga and tumba, small shaker.\n\n'
        'Every hit cut at its attack, shortened with a fade, converted to FLAC and level-matched. No author endorsement implied.\n')
    print(len(facts),'recordings,',len(lines),'layers in',DEST)
