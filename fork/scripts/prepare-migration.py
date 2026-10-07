#!/usr/bin/env python3
"""Validate/copy a capture into a NEW staging seed. Never write the live recovery state."""
import hashlib
import json
import pathlib
import sys
import uuid
if len(sys.argv) != 3:
    raise SystemExit('Usage: prepare-migration.py /completed/capture /new/staging-migration-seed')
source, destination = map(pathlib.Path, sys.argv[1:])
if not (source/'CAPTURE-COMPLETE').is_file() or destination.exists():
    raise SystemExit('A complete capture and a NEW destination are required.')
completion = json.loads((source/'CAPTURE-COMPLETE').read_bytes())
expected_files = ['surface-bindings.json', 'agent-recovery.json', 'agent-recovery-migration.json']
if completion.get('schema') != 1 or set(completion.get('files_sha256', {})) != set(expected_files):
    raise SystemExit('Unsupported completion receipt.')
for name in expected_files:
    actual = hashlib.sha256((source/name).read_bytes()).hexdigest()
    if actual != completion['files_sha256'][name]:
        raise SystemExit('Capture output changed after completion; no seed prepared.')
capture = json.loads((source/'surface-bindings.json').read_bytes())
marker = json.loads((source/'agent-recovery-migration.json').read_bytes())
raw = json.loads((source/'agent-recovery.json').read_bytes())
if capture.get('schema') != 1 or marker.get('version') != 1 or not isinstance(raw, list) or len(raw) % 2:
    raise SystemExit('Unsupported capture, migration marker or Swift UUID dictionary format.')
def normalize(value):
    return str(uuid.UUID(value))
surfaces = {normalize(row['surface']['surfaceID']): row for row in capture['surfaces']}
if len(surfaces) != len(capture['surfaces']):
    raise SystemExit('Duplicate captured surface UUID.')
records = {}
for index in range(0, len(raw), 2):
    identifier = normalize(raw[index])
    if identifier in records:
        raise SystemExit('Duplicate journal UUID.')
    records[identifier] = raw[index+1]
if set(records) != set(surfaces) or set(map(normalize, marker['surfaceIDs'])) != set(surfaces):
    raise SystemExit('Capture/journal/allowlist UUID sets disagree; no seed prepared.')
for identifier, record in records.items():
    row = surfaces[identifier]
    if record.get('binding') != row.get('binding'):
        raise SystemExit('Journal binding differs from verified captured binding.')
    binding = record.get('binding')
    if binding:
        normalize(binding['sessionID'])
        if binding['tool'] not in ('claude', 'codex') or not binding['sessionRoot'].startswith('/'):
            raise SystemExit('Invalid typed binding.')
        if record['phase'] == 'pending':
            if row.get('ownerPID', 0) <= 0 or row.get('ownerStartSeconds', 0) <= 0 or row.get('reason'):
                raise SystemExit('Pending binding lacks process birth evidence or has unresolved uncertainty.')
        elif record['phase'] != 'failed' or not record.get('reason'):
            raise SystemExit('Uncertain binding must retain visible failed state.')
    elif record.get('phase') != 'failed' or not record.get('reason'):
        raise SystemExit('Unknown surfaces must remain unbound with visible failure reason.')
destination.mkdir(parents=True)
files = ['agent-recovery.json', 'agent-recovery-migration.json', 'surface-bindings.json']
for name in files:
    data = (source/name).read_bytes()
    temporary = destination/(name + '.tmp')
    temporary.write_bytes(data)
    temporary.replace(destination/name)
manifest = {'capture_source': str(source.resolve()), 'capturedAt': capture['capturedAt'],
            'appPath': capture['appPath'], 'appPID': capture['appPID'],
            'surfaceIDs': sorted(surfaces), 'bound_count': sum(bool(x.get('binding')) for x in records.values()),
            'files_sha256': {name: hashlib.sha256((destination/name).read_bytes()).hexdigest() for name in files},
            'staging_only': True, 'refresh_before_quit_required': True}
(destination/'migration-seed-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Prepared staging seed for {len(records)} exact surfaces; {manifest["bound_count"]} bindings. No live journal written.')
