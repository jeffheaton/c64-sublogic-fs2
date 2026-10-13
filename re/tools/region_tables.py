#!/usr/bin/env python3
"""Regenerates the region tables in re/docs/memory-map.md and re/docs/excluded.md from
re/symbols.json (plus any re/symbols.d/*.json fragments, merged the way SymbolDatabase.load
merges them).

    python3 re/tools/region_tables.py          # rewrite both docs in place
    python3 re/tools/region_tables.py --check  # exit 1 when a doc is out of date

Each doc keeps its generated part between `<!-- generated:NAME:begin -->` and
`<!-- generated:NAME:end -->`. Only names, addresses and comments are used: no disk bytes."""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # re/
EXCLUDED_KINDS = ('residue', 'crack', 'loader', 'protection')
OVERLAYS = [
    (None, 'Resident image'),
    ('coldStart', 'Overlay 0: cold start (stage 3, blocks 2-4)'),
    ('editor', 'Overlay 1: editor (blocks 42-47)'),
    ('war', 'Overlay 2: war (blocks 158-160)'),
    ('flight', 'Overlay 3: flight (block 65) + root block 66 at $A800'),
    ('databaseInfo', 'Overlay 4: database info (block 64)'),
]


def load_database():
    with open(os.path.join(ROOT, 'symbols.json'), encoding='utf-8') as f:
        db = json.load(f)
    for path in sorted(glob.glob(os.path.join(ROOT, 'symbols.d', '*.json'))):
        with open(path, encoding='utf-8') as f:
            fragment = json.load(f)
        for kind in ('regions', 'variables', 'routines', 'tables'):
            key = 'start' if kind == 'regions' else 'addr'
            for item in fragment.get(kind) or []:
                same = [i for i, e in enumerate(db[kind]) if (e[key], e.get('overlay')) == (item[key], item.get('overlay'))]
                if same:
                    db[kind][same[0]] = item
                else:
                    db[kind].append(item)
        db['notes'] = (db.get('notes') or []) + (fragment.get('notes') or [])
    return db


def address(text):
    return int(text[1:], 16)


SENTENCE_END = re.compile(r'(?<=[.!?])\s+(?=[A-Z$`\'(])')
ABBREVIATIONS = ('e.g.', 'i.e.', 'vs.', 'approx.', 'cf.')
# A single quote that is not an apostrophe inside a word: it opens or closes a quoted string.
QUOTE = re.compile(r"(?<![A-Za-z])'|'(?![A-Za-z])")


def first_sentence(comment):
    text = comment.strip()
    if text.startswith('NOT PORTED.'):
        text = text[len('NOT PORTED.'):].strip()
    for match in SENTENCE_END.finditer(text):
        head = text[:match.start()]
        if head.lower().endswith(ABBREVIATIONS):
            continue
        if len(QUOTE.findall(head)) % 2:                # inside a quoted string ('A. COLOR ...')
            continue
        return head
    return text


def cell(text):
    return text.replace('|', '\\|').replace('\n', ' ')


def memory_map_tables(db):
    lines = ['The excluded kinds are shown in **bold**: residue, crack, loader and protection. "Notes" is the',
             "first sentence of the region's comment in `symbols.json`.", '']
    for overlay, title in OVERLAYS:
        regions = sorted((r for r in db['regions'] if r.get('overlay') == overlay), key=lambda r: address(r['start']))
        lines += [f'### {title}', '', '| Range | Kind | Name | Subsystem | Notes |', '|---|---|---|---|---|']
        for r in regions:
            kind = f"**{r['kind']}**" if r['kind'] in EXCLUDED_KINDS else r['kind']
            lines.append(f"| {r['start']}-{r['end']} | {kind} | `{r['name']}` | {r['subsystem']} | {cell(first_sentence(r['comment']))} |")
        lines.append('')
    return '\n'.join(lines).rstrip('\n')


def excluded_table(db):
    order = {o: i for i, (o, _) in enumerate(OVERLAYS)}
    regions = [r for r in db['regions'] if r['kind'] in EXCLUDED_KINDS]
    regions.sort(key=lambda r: (EXCLUDED_KINDS.index(r['kind']), order[r.get('overlay')], address(r['start'])))
    lines = ['| Kind | Range | Overlay | Name | Bytes | What |', '|---|---|---|---|---|---|']
    for r in regions:
        size = address(r['end']) - address(r['start']) + 1
        comment = r['comment'].strip()
        if comment.startswith('NOT PORTED.'):
            comment = comment[len('NOT PORTED.'):].strip()
        lines.append(f"| {r['kind']} | {r['start']}-{r['end']} | {r.get('overlay') or 'resident'} | `{r['name']}` | {size} | {cell(comment)} |")
    return '\n'.join(lines)


def replace_block(text, name, body, path):
    begin, end = f'<!-- generated:{name}:begin -->', f'<!-- generated:{name}:end -->'
    if begin not in text or end not in text:
        sys.exit(f'{path}: missing the {begin} / {end} markers')
    head, rest = text.split(begin, 1)
    _, tail = rest.split(end, 1)
    return f'{head}{begin}\n{body}\n{end}{tail}'


def main():
    check = '--check' in sys.argv[1:]
    db = load_database()
    targets = [
        (os.path.join(ROOT, 'docs', 'memory-map.md'), 'regions', memory_map_tables(db)),
        (os.path.join(ROOT, 'docs', 'excluded.md'), 'excluded-regions', excluded_table(db)),
    ]
    stale = []
    for path, name, body in targets:
        with open(path, encoding='utf-8') as f:
            text = f.read()
        new = replace_block(text, name, body, path)
        if new != text:
            stale.append(os.path.relpath(path, os.path.dirname(ROOT)))
            if not check:
                with open(path, 'w', encoding='utf-8') as f:
                    f.write(new)
    if check:
        if stale:
            sys.exit('out of date: ' + ', '.join(stale) + ' (run python3 re/tools/region_tables.py)')
        print('up to date')
    else:
        print('rewrote ' + ', '.join(stale) if stale else 'already up to date')


if __name__ == '__main__':
    main()
