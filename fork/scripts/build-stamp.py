#!/usr/bin/env python3
"""Identify all Git-visible source inputs, including untracked reliability helpers."""
import hashlib
import pathlib
import subprocess
root = pathlib.Path(__file__).resolve().parents[2]
head = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
files = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-co', '--exclude-standard', '-z']).split(b'\0')
source = hashlib.sha256()
for raw in sorted(set(files)):
    if not raw:
        continue
    path = root / raw.decode()
    source.update(raw + b'\0')
    if path.is_symlink():
        source.update(str(path.readlink()).encode())
    elif path.is_file():
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                source.update(chunk)
    else:
        source.update(b'<missing>')
    source.update(b'\0')
print(head + '.source-' + source.hexdigest()[:20])
