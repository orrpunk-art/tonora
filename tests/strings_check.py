#!/usr/bin/env python3
"""Every Russian interface string has an English translation in src/strings_en.m.

Russian is the key in the code: T(@"…") literals, the static NSString constants and C tables of the
ObjC files that reach T(), and the C core's name tables that reach T() through S(). Usage: strings_check.py <src dir>
"""
import re, sys, pathlib

src = pathlib.Path(sys.argv[1])
cyrillic = re.compile('[А-Яа-яЁё]')
table = src.joinpath('strings_en.m').read_text()
english = {bytes(k, 'utf8').decode('unicode_escape').encode('latin1').decode('utf8') for k in re.findall(r'^\s*@"((?:[^"\\]|\\.)*)":@"', table, re.M)}

def unescape(text):
    return bytes(text, 'utf8').decode('unicode_escape').encode('latin1').decode('utf8') if '\\' in text else text

bilingual = {'Язык · Language', 'Русский'}   # the language switch reads the same in both languages
keys, bare = set(), []
for name in ['main.m', 'pianoroll.m', 'mididrag.m', 'midiio.m']:
    text = src.joinpath(name).read_text()
    if name == 'main.m':
        text = text.split('int main(int argc')[0]          # the self-test compares against Russian on purpose
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)      # comments
    text = re.sub(r'//[^\n]*', '', text)
    keys.update(re.findall(r'T\(@"((?:[^"\\\n]|\\.)*)"\)', text))
    for line in text.split('\n'):                          # a Russian ObjC literal must go through T() (constants: at their use)
        if line.startswith('static NSString *const'):
            continue
        for m in re.finditer(r'@"((?:[^"\\\n]|\\.)*)"', line):
            if cyrillic.search(m.group(1)) and line[max(0, m.start() - 2):m.start()] != 'T(' and m.group(1) not in bilingual:
                bare.append(f'{name}: {m.group(1)}')
    for constants in re.findall(r'static NSString \*const \w+(?:\[\])?=\{?(.*?);', text):
        keys.update(re.findall(r'@"((?:[^"\\\n]|\\.)*)"', constants))
    keys.update(m.group(1) for m in re.finditer(r'(?<![@\\])"((?:[^"\\\n]|\\.)*)"', text) if text[m.start() - 1] != '@')
for name, functions in [('music.c', ['kv_mode_name']),
                        ('performance.c', ['kv_pattern_russian', 'kv_arpeggio_name', 'kv_division_name', 'kv_string_texture_name', 'kv_articulation_name', 'kv_beat_name'])]:
    text = src.joinpath(name).read_text()
    for function in functions:
        start = text.index('const char *' + function + '(')
        keys.update(re.findall(r'"([^"]*)"', text[start:text.index('\n}', start) if text[start:text.index('\n', start)].rstrip().endswith('{') else text.index('\n', start)]))

missing = sorted(k for k in (unescape(k) for k in keys) if cyrillic.search(k) and k not in english)
for key in missing:
    print('No English for:', key)
for literal in bare:
    print('Not wrapped in T():', literal)
print(f'{len(english)} English strings, {len(missing)} missing, {len(bare)} not wrapped')
sys.exit(1 if missing or bare else 0)
