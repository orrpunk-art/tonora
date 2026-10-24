#!/usr/bin/env python3
"""Fetch the pinned, unmodified Salamander v8 recording subset (CC BY 3.0)."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.request import urlopen
from urllib.parse import quote
import hashlib
import json

COMMIT = '3382bf9496bba2486f5ab0de55a264d1dfc38404'
ROOT = Path(__file__).resolve().parents[1] / 'assets' / 'piano'
NAMES = ['A2','C3','D#3','F#3','A3','C4','D#4','F#4','A4','C5','D#5','F#5','A5','C6','D#6','F#6','A6']
ROOT.mkdir(parents=True, exist_ok=True)
def fetch(name):
    filename = name + 'v8.flac'
    url = f'https://raw.githubusercontent.com/sfzinstruments/SalamanderGrandPiano/{COMMIT}/Samples/{quote(filename)}'
    target = ROOT / filename
    if not target.exists():
        with urlopen(url, timeout=90) as response:
            data = response.read()
        if not data.startswith(b'fLaC'):
            raise ValueError(f'Not FLAC: {filename}')
        target.write_bytes(data)
    return {'file': filename, 'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'url': url}
with ThreadPoolExecutor(max_workers=4) as pool:
    files = list(pool.map(fetch, NAMES))
(ROOT / 'manifest.json').write_text(json.dumps({'commit': COMMIT, 'velocity_layer': 8, 'files': files}, indent=2) + '\n')
print(f'Fetched {len(files)} pinned piano recordings.')
