#!/usr/bin/env python3
"""Writes README.md's "Missing for daily use" section from site/roadmap.js (the website reads the same file)."""
import json, os, re, sys

TOP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
STATUS = {'todo': '❌ Not started', 'partial': '🟡 Partly works', 'wip': '🚧 In progress'}
EFFORT = {'S': 'Small', 'M': 'Medium', 'L': 'Large', 'XL': 'Very large'}


def load():
    src = open(os.path.join(TOP, 'site/roadmap.js'), encoding='utf-8').read()
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = src.split('=', 1)[1].strip().rstrip(';')
    src = re.sub(r'([{,]\s*)(area|items)\s*:', r'\1"\2":', src)
    return json.loads(src)


def render(data):
    n = sum(len(a['items']) for a in data)
    out = [f'{n} features stand between this port and a phone for every day, listed one by one. '
           'Effort is a rough guess. The website shows the same list (site/roadmap.js).', '']
    for a in data:
        out += [f'### {a["area"]}', '', '| Feature | Why it matters | Status | Effort |', '| --- | --- | --- | --- |']
        out += [f'| {t} | {why} | {STATUS[st]} | {EFFORT[ef]} |' for t, why, st, ef in a['items']]
        out.append('')
    return '\n'.join(out)


def main():
    path = os.path.join(TOP, 'README.md')
    readme = open(path, encoding='utf-8').read()
    start, end = '<!-- roadmap:start -->', '<!-- roadmap:end -->'
    if start not in readme:
        sys.exit('README.md has no roadmap markers')
    head, rest = readme.split(start, 1)
    tail = rest.split(end, 1)[1]
    open(path, 'w', encoding='utf-8').write(head + start + '\n' + render(load()) + end + tail)
    print('README.md: roadmap written')


if __name__ == '__main__':
    main()
