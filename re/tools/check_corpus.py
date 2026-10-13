#!/usr/bin/env python3
"""Consistency checks of the reverse-engineering corpus in re/ (no disk image needed).

    python3 re/tools/check_corpus.py      # exit 1 and list the problems, if any

1. No byte dumps: no file in re/ (docs, sessions, symbols, tools) holds a run of 12 or more hex
   byte values, the rule `SymbolDatabaseFile.containsNoByteDumps` applies to symbols.json.
2. The generated region tables of docs/memory-map.md and docs/excluded.md are current
   (tools/region_tables.py).
3. Every test a doc cites as `SuiteTests.method` or `SuiteTests.swift` exists under Tests/.
4. Every `Sources/...` or `Tests/...` Swift file a doc cites exists."""
import glob
import importlib.util
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # re/
REPO = os.path.dirname(ROOT)
BYTE_RUN = re.compile(r'(\$?[0-9A-Fa-f]{2}[ ,]+){12,}')
TEST_REF = re.compile(r'\b([A-Z]\w*Tests)\.(?!swift\b)([a-z]\w*)\b')
TEST_FILE_REF = re.compile(r'\b([A-Z]\w*Tests\.swift)\b')
FILE_REF = re.compile(r'`((?:Sources|Tests)/[\w/.-]+\.swift)`')


def corpus_files():
    for pattern in ('**/*.md', '**/*.txt', '**/*.json', '**/*.py'):
        for path in glob.glob(os.path.join(ROOT, pattern), recursive=True):
            if os.sep + 'out' + os.sep not in path:
                yield path


def main():
    problems = []
    rel = lambda p: os.path.relpath(p, REPO)
    for path in sorted(set(corpus_files())):
        with open(path, encoding='utf-8') as f:
            text = f.read()
        match = BYTE_RUN.search(text)
        if match:
            problems.append(f'{rel(path)}: a run of hex byte values: {match.group(0)[:60]}...')

    spec = importlib.util.spec_from_file_location('region_tables', os.path.join(ROOT, 'tools', 'region_tables.py'))
    tables = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tables)
    db = tables.load_database()
    for doc, name, body in (('memory-map.md', 'regions', tables.memory_map_tables(db)),
                            ('excluded.md', 'excluded-regions', tables.excluded_table(db))):
        path = os.path.join(ROOT, 'docs', doc)
        with open(path, encoding='utf-8') as f:
            text = f.read()
        if tables.replace_block(text, name, body, path) != text:
            problems.append(f'{rel(path)}: region table out of date (run python3 re/tools/region_tables.py)')

    test_source = ''
    test_files = set()
    for path in glob.glob(os.path.join(REPO, 'Tests', '**', '*.swift'), recursive=True):
        test_files.add(os.path.basename(path))
        with open(path, encoding='utf-8') as f:
            test_source += f.read()
    test_names = set(re.findall(r'(?:func|let|var|struct|class|enum)\s+(\w+)', test_source))
    for path in sorted(glob.glob(os.path.join(ROOT, '**', '*.md'), recursive=True)):
        with open(path, encoding='utf-8') as f:
            text = f.read()
        for suite, method in sorted(set(TEST_REF.findall(text))):
            if suite not in test_names or method not in test_names:
                problems.append(f'{rel(path)}: cites {suite}.{method}, which is not in Tests/')
        for name in sorted(set(TEST_FILE_REF.findall(text)) - test_files):
            problems.append(f'{rel(path)}: cites {name}, which is not in Tests/')
        for ref in sorted(set(FILE_REF.findall(text))):
            if not os.path.exists(os.path.join(REPO, ref)):
                problems.append(f'{rel(path)}: cites {ref}, which does not exist')

    for p in problems:
        print(p)
    if problems:
        sys.exit(1)
    print('ok: no byte dumps, region tables current, cited tests and files exist')


if __name__ == '__main__':
    main()
