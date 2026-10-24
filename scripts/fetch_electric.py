#!/usr/bin/env python3
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.request import urlopen
from urllib.parse import quote
import hashlib,json
COMMIT='8c3e581acda3594b553948ff0222d4f84a698376'
ROOT=Path(__file__).resolve().parents[1]/'assets'
with urlopen(f'https://api.github.com/repos/sfzinstruments/GregSullivan.E-Pianos/git/trees/{COMMIT}?recursive=1',timeout=60) as r: tree=json.load(r)['tree']
for prefix,folder,title in [('CP80','CP80','Yamaha CP80'),('Pianet T','Pianet','Hohner Pianet T')]:
    dest=ROOT/folder;dest.mkdir(parents=True,exist_ok=True)
    paths=[x['path'] for x in tree if x['path'].startswith(prefix+'/Samples/') and x['path'].endswith('-MP.flac' if folder=='CP80' else '_P.flac')]
    def fetch(path):
        name=path.split('/')[-1];url=f'https://raw.githubusercontent.com/sfzinstruments/GregSullivan.E-Pianos/{COMMIT}/{quote(path)}'
        f=dest/name
        if not f.exists():
            with urlopen(url,timeout=90) as r: data=r.read()
            if not data.startswith(b'fLaC'):raise ValueError(name)
            f.write_bytes(data)
        midi=int(name.split('-')[0] if folder=='CP80' else name.split('_')[0])
        return {'file':name,'midi':midi,'sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'url':url}
    with ThreadPoolExecutor(max_workers=4) as pool: files=list(pool.map(fetch,paths))
    files.sort(key=lambda x:x['midi'])
    (dest/'index.txt').write_text(''.join(f"{x['midi']} {x['file']}\n" for x in files))
    (dest/'manifest.json').write_text(json.dumps({'commit':COMMIT,'files':files},indent=2)+'\n')
    with urlopen(f'https://raw.githubusercontent.com/sfzinstruments/GregSullivan.E-Pianos/{COMMIT}/LICENSE',timeout=60) as r:(dest/'LICENSE.txt').write_bytes(r.read())
    (dest/'ATTRIBUTION.txt').write_text(f'{title} — Greg Sullivan. CC BY 3.0 Unported.\nhttps://creativecommons.org/licenses/by/3.0/\nhttps://github.com/sfzinstruments/GregSullivan.E-Pianos\nPinned commit: {COMMIT}\nUnmodified medium/soft-velocity subset, decoded/resampled and enveloped during playback.\nNo author endorsement implied.\n')
    print(title,len(files),'recordings')
