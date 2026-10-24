#!/usr/bin/env python3
"""The electronic kit for Tonora's house, hip-hop and trip-hop beats: a Roland TR-808 sampled by Michael Fischer (Technopolis,
1994, free to use), published CC0 by the Tidal Cycles project. Same pipeline and layout as fetch_percussion.py (General MIDI
notes, four layers: the soft ones are the same hits at a lower level, the loud ones two knob settings as two takes), into
assets/Percussion808. The 808 has no tambourine: the cowbell stands in; the maracas play the shaker."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json
import fetch_percussion as fp
fp.SOURCES['fischer']=('tidalcycles/sounds-tr808-fischer','85fbecf1bec32553395625ea659e2a56dfd7c0e1','')
fp.DEST=Path(__file__).resolve().parents[1]/'assets'/'Percussion808'
def hits(soft1,soft2,loud1,loud2): return [[('fischer',soft1,.55)],[('fischer',soft2,.55)],[('fischer',loud1,1.0)],[('fischer',loud2,1.0)]]
fp.KIT=[
    (36,'kick',1.2,.36,hits('bd8/BD2525.WAV','bd8/BD2550.WAV','bd8/BD2550.WAV','bd8/BD2575.WAV')),
    (37,'side-stick',.4,.18,hits('rs8/RS.WAV','rs8/RS.WAV','rs8/RS.WAV','rs8/RS.WAV')),
    (38,'snare',.8,.28,hits('sd8/SD5025.WAV','sd8/SD5050.WAV','sd8/SD5050.WAV','sd8/SD7550.WAV')),
    (39,'clap',.6,.20,hits('cp8/CP.WAV','cp8/CP.WAV','cp8/CP.WAV','cp8/CP.WAV')),
    (42,'hihat-closed',.4,.12,hits('ch8/CH.WAV','ch8/CH.WAV','ch8/CH.WAV','ch8/CH.WAV')),
    (46,'hihat-open',1.2,.12,hits('oh8/OH25.WAV','oh8/OH50.WAV','oh8/OH25.WAV','oh8/OH50.WAV')),
    (54,'cowbell',.6,.12,hits('cb8/CB.WAV','cb8/CB.WAV','cb8/CB.WAV','cb8/CB.WAV')),
    (63,'conga-high',.6,.20,hits('hc8/HC25.WAV','hc8/HC50.WAV','hc8/HC25.WAV','hc8/HC50.WAV')),
    (64,'conga-low',.7,.20,hits('lc8/LC25.WAV','lc8/LC50.WAV','lc8/LC25.WAV','lc8/LC50.WAV')),
    (70,'maracas',.3,.10,hits('ma8/MA.WAV','ma8/MA.WAV','ma8/MA.WAV','ma8/MA.WAV')),
]
if __name__=='__main__':
    DEST=fp.DEST; DEST.mkdir(parents=True,exist_ok=True)
    for old in DEST.glob('*.flac'): old.unlink()
    jobs,layers=fp.plan()
    with ThreadPoolExecutor(max_workers=6) as pool: facts={f['file']:f for f in pool.map(fp.prepare,jobs)}
    gains,lines={},[]
    for note,target,layer,file in layers:
        if layer>=2: gains[note]=max(gains.get(note,0),facts[file]['level'])
    for note,target,layer,file in layers: lines.append(f'{note} {file} {round(min(16,target/gains[note]),3)} 0 {layer} 0\n')
    (DEST/'index.txt').write_text(''.join(lines))
    (DEST/'manifest.json').write_text(json.dumps({'sources':{'fischer':{'repository':fp.SOURCES['fischer'][0],'commit':fp.SOURCES['fischer'][1]}},
        'layers':['soft 1','soft 2','loud 1','loud 2'],'sounds':{str(n):nm for n,nm,*_ in fp.KIT},
        'files':[{k:f[k] for k in ('file','mix','sha256')} for f in sorted(facts.values(),key=lambda f:f['file'])]},indent=2)+'\n')
    (DEST/'ATTRIBUTION.txt').write_text(
        'Electronic kit — Roland TR-808 Sound Sample Set 1.0.0 (1994), recorded by Michael Fischer (Technopolis), free to use;\n'
        'published CC0 1.0 Universal (public domain) by the Tidal Cycles project: https://creativecommons.org/publicdomain/zero/1.0/\n'
        f'https://github.com/{fp.SOURCES["fischer"][0]}\nPinned commit: {fp.SOURCES["fischer"][1]}\n'
        'Bass drum, rim shot, snare, hand clap, closed and open hi-hat, cowbell, hi and low conga, maracas.\n'
        'Every hit cut at its attack, shortened with a fade, converted to FLAC and level-matched; the soft layers are the same hits at a lower level. No author endorsement implied.\n')
    print(len(facts),'recordings,',len(lines),'layers in',DEST)
