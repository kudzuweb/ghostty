"""Stage signed inert fixture bundles; never read/copy/replace the actual daily app/state."""
import os, pathlib, plistlib, shutil, subprocess, sys, tempfile
repo = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='ghostty-staging-') as tmp:
    root = pathlib.Path(tmp)
    def bundle(name, revision):
        app = root/name
        (app/'Contents/MacOS').mkdir(parents=True)
        shutil.copyfile('/usr/bin/true', app/'Contents/MacOS/ghostty')
        (app/'Contents/MacOS/ghostty').chmod(0o755)
        with (app/'Contents/Info.plist').open('wb') as f:
            plistlib.dump({'CFBundleIdentifier': 'com.mitchellh.ghostty', 'CFBundleExecutable': 'ghostty',
                          'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'GhosttyForkRevision': revision}, f)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        return app
    candidate, installed = bundle('Candidate.app', 'candidate-fixture'), bundle('Installed.app', 'previous-installed-fixture')
    active = bundle('Active.app', 'previous-active-fixture')
    home = root/'fixture-home'; config = home/'.config/ghostty/config.ghostty'
    config.parent.mkdir(parents=True); config.write_text('fixture-state\n')
    destination = root/'stage'
    environment = dict(os.environ, GHOSTTY_STAGE_INSTALLED_APP=str(installed), GHOSTTY_STAGE_SNAPSHOT_HOME=str(home), GHOSTTY_STAGE_ACTIVE_APP=str(active))
    helper = str(repo/'fork/scripts/stage-daily.sh')
    subprocess.run([helper, 'dry-run', str(candidate), str(destination)], env=environment, check=True, capture_output=True)
    assert not destination.exists(), 'dry-run must create no stage or backups'
    subprocess.run([helper, 'prepare', str(candidate), str(destination)], env=environment, check=True, capture_output=True)
    assert not list(destination.rglob('*.app')), 'staging must retain no runnable app copies'
    assert not list(destination.rglob('*.zip')), 'staging must retain no application archives'
    assert any(p.read_text() == 'fixture-state\n' for p in (destination/'state').rglob('config.ghostty'))
    import json
    mapping = json.loads((destination/'transaction.json').read_text())
    assert mapping['candidate']['source_path'] == str(candidate)
    assert mapping['previous_active']['source_path'] == str(active)
    assert mapping['previous_installed']['source_path'] == str(installed)
    assert all('backup' not in mapping[key] for key in ('candidate', 'previous_active', 'previous_installed'))
    assert (destination/'INSTALL.txt').exists()
    duplicate = subprocess.run([helper, 'prepare', str(candidate), str(destination)], env=environment, capture_output=True)
    assert duplicate.returncode != 0, 'existing receipts must not be overwritten'
    assert config.read_text() == 'fixture-state\n', 'preparation must not alter source state'
print('Staging dry-run/prepare/receipt checks passed (signed inert fixtures only)')
