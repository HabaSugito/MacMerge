#!/usr/bin/env python3
"""Adds or updates Japanese translations. Usage: add-ja.py 'English=日本語' ..."""
import re, sys
path = 'Resources/ja.lproj/Localizable.strings'
text = open(path, encoding='utf-8').read()
def esc(s): return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
for arg in sys.argv[1:]:
    key, value = arg.split('=', 1)
    line = f'"{esc(key)}" = "{esc(value)}";'
    pattern = re.compile(r'^"' + re.escape(esc(key)) + r'" = .*$', re.M)
    text = pattern.sub(line, text) if pattern.search(text) else text + line + '\n'
open(path, 'w', encoding='utf-8').write(text)
