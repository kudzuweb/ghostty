"""Validate migration seeds with known-paused and unknown records; never touch live state."""
import hashlib, json, pathlib, subprocess, sys, tempfile, uuid
repo = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='ghostty-migration-') as tmp:
    root = pathlib.Path(tmp); capture = root/'capture'; capture.mkdir()
    known, unknown = str(uuid.uuid4()), str(uuid.uuid4())
    binding = {'tool': 'claude', 'sessionID': str(uuid.uuid4()), 'sessionRoot': '/fixture/.claude', 'launchCWD': '/fixture/project'}
    rows = [{'surface': {'surfaceID': known}, 'binding': binding, 'reason': 'Multiple globally live owners; recovery paused'},
            {'surface': {'surfaceID': unknown}, 'reason': 'No unique metadata; left unbound'}]
    metadata = {'schema': 1, 'capturedAt': 813000000, 'appPath': '/fixture/Ghostty.app', 'appPID': 12345, 'surfaces': rows}
    records = [known, {'binding': binding, 'phase': 'failed', 'reason': rows[0]['reason'], 'updatedAt': 813000000},
               unknown, {'phase': 'failed', 'reason': rows[1]['reason'], 'updatedAt': 813000000}]
    (capture/'surface-bindings.json').write_text(json.dumps(metadata))
    (capture/'agent-recovery.json').write_text(json.dumps(records))
    marker = {'version': 1, 'surfaceIDs': [known, unknown]}
    (capture/'agent-recovery-migration.json').write_text(json.dumps(marker))
    def complete():
        files = ['surface-bindings.json', 'agent-recovery.json', 'agent-recovery-migration.json']
        (capture/'CAPTURE-COMPLETE').write_text(json.dumps({'schema': 1, 'files_sha256':
            {name: hashlib.sha256((capture/name).read_bytes()).hexdigest() for name in files}}))
    complete()
    helper = repo/'fork/scripts/prepare-migration.py'
    subprocess.run([sys.executable, str(helper), str(capture), str(root/'seed')], check=True, capture_output=True)
    retained = json.loads((root/'seed/agent-recovery.json').read_text())
    assert retained[1]['binding'] == binding and retained[1]['phase'] == 'failed'
    assert 'binding' not in retained[3] and retained[3]['phase'] == 'failed'
    existing = subprocess.run([sys.executable, str(helper), str(capture), str(root/'seed')], capture_output=True)
    assert existing.returncode != 0, 'existing seed cannot be replaced'
    records[1]['binding'] = dict(binding, sessionID=str(uuid.uuid4()))
    (capture/'agent-recovery.json').write_text(json.dumps(records))
    tampered = subprocess.run([sys.executable, str(helper), str(capture), str(root/'tampered')], capture_output=True)
    assert tampered.returncode != 0 and not (root/'tampered').exists(), 'changed outputs must fail receipt hash'
    complete()
    inconsistent = subprocess.run([sys.executable, str(helper), str(capture), str(root/'inconsistent')], capture_output=True)
    assert inconsistent.returncode != 0 and not (root/'inconsistent').exists(), 'journal binding must agree with capture'
    records[1]['binding'] = binding
    (capture/'agent-recovery.json').write_text(json.dumps(records))
    marker['surfaceIDs'] = [known]
    (capture/'agent-recovery-migration.json').write_text(json.dumps(marker))
    complete()
    mismatch = subprocess.run([sys.executable, str(helper), str(capture), str(root/'bad-seed')], capture_output=True)
    assert mismatch.returncode != 0 and not (root/'bad-seed').exists(), 'mismatched UUID set may not produce partial seed'
    (capture/'CAPTURE-COMPLETE').unlink()
    incomplete = subprocess.run([sys.executable, str(helper), str(capture), str(root/'incomplete')], capture_output=True)
    assert incomplete.returncode != 0 and not (root/'incomplete').exists()
print('Migration seed validation checks passed (fixtures only)')
