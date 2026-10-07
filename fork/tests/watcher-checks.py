"""Execute actual embedded watcher scripts with only fake command endpoints."""
import pathlib, re, subprocess, sys, tempfile, time, os
repo = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='ghostty-watchers-') as tmp:
    root = pathlib.Path(tmp)
    def exe(name, content):
        path = root/name; path.write_text('#!/bin/sh\n' + content); path.chmod(0o700); return str(path)
    log = root/'opened'
    fake_open = exe('open', 'printf "%s\\n" "$*" >> "' + str(log) + '"\n')
    listing = root/'ps-output'; listing.write_text('')
    fake_ps = exe('ps', 'cat "' + str(listing) + '"\n')
    source = (repo/'macos/Sources/Features/KeepAlive/KeepAliveRelaunchJob.swift').read_text()
    watcher = re.search(r'watcherScript = """\n(.*?)\n    """', source, re.S)[1]
    watcher = '\n'.join(line.removeprefix('    ') for line in watcher.splitlines())
    watcher = 'kill() { return 1; }\n' + watcher.replace('/bin/ps', fake_ps).replace('/usr/bin/open', fake_open)
    marker = root/'clean-quit'; app = str(root/'Canonical.app')
    marker.touch()
    subprocess.run(['/bin/sh', '-c', watcher, 'watcher', '12345', app, str(marker), 'birth'], check=True)
    assert not log.exists(), 'clean quit must not reopen'
    listing.write_text(app + '/Contents/MacOS/ghostty\n')
    subprocess.run(['/bin/sh', '-c', watcher, 'watcher', '12345', app, str(marker), 'birth'], check=True)
    assert not log.exists(), 'already reopened canonical executable must not duplicate'
    listing.write_text('/other/Ghostty.app/Contents/MacOS/ghostty\n')
    subprocess.run(['/bin/sh', '-c', watcher, 'watcher', '12345', app, str(marker), 'birth'], check=True)
    assert log.read_text().strip() == app, 'watcher must address owning bundle path'
    source = (repo/'macos/Sources/Features/SleepGuard/SleepGuard.swift').read_text()
    recovery = re.search(r'let script = #"""\n(.*?)\n        """#', source, re.S)[1]
    recovery = '\n'.join(line.removeprefix('        ') for line in recovery.splitlines())
    lock = root/'sleep.lock'; lease = root/'sleep.lease'; lock.touch(); lease.write_text('owner')
    changed = root/'late-mutation'
    # Child and grandchild ignore TERM. Both must die before lease ownership is released.
    fake_sudo = exe('sudo', 'trap "" TERM\n(sleep 3; touch "' + str(changed) + '") &\nwait\n')
    subprocess.run([sys.argv[2], fake_sudo], timeout=5, check=True)
    time.sleep(3.2)
    assert not changed.exists(), 'bounded command child/grandchild must not mutate late'
    recovery = recovery.replace("'/usr/bin/sudo'", repr(fake_sudo)).replace('time() + 15', 'time() + 1')
    outcome = subprocess.run(['/usr/bin/perl', '-e', recovery, str(lock), str(lease), 'owner'], timeout=5)
    assert outcome.returncode == 1 and lease.exists(), 'timeout retains recovery lease'
    time.sleep(3.2)
    assert not changed.exists(), 'timed-out descendant must not mutate after recovery exits'
    # Kill only the fixture app owner while its acquisition supervisor/child is alive.
    # The inherited flock must keep real recovery from releasing before that setter exits.
    crash_root = root/'crash-owner'; crash_root.mkdir()
    state = crash_root/'fake-sleep'; state.write_text('0')
    started = crash_root/'started'; receipt = crash_root/'recovered'
    delayed = exe('delayed-acquire', 'touch "' + str(started) + '"\nsleep 1\nprintf 1 > "' + str(state) + '"\n')
    recovered = exe('recover-fake', 'printf 0 > "' + str(state) + '"\ntouch "' + str(receipt) + '"\n')
    owner = subprocess.Popen([sys.argv[3], str(crash_root), delayed])
    deadline = time.monotonic() + 3
    while not started.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert started.exists(), 'fixture acquisition must be in flight'
    crash_lease = crash_root/'sleep-guard.lease'; token = crash_lease.read_text()
    crash_recovery = recovery.replace(repr(fake_sudo), repr(recovered)).replace('time() + 1', 'time() + 3')
    recovering = subprocess.Popen(['/usr/bin/perl', '-e', crash_recovery,
                                  str(crash_root/'sleep-guard.lock'), str(crash_lease), token])
    owner.kill(); owner.wait(timeout=2)
    time.sleep(0.2)
    assert not receipt.exists(), 'recovery must wait for inherited mutation lock after owner crash'
    recovering.wait(timeout=5)
    assert recovering.returncode == 0 and receipt.exists() and not crash_lease.exists()
    time.sleep(1.2)
    assert state.read_text() == '0', 'no orphaned late block after parent crash recovery'
    print('Crash during acquisition check passed (disposable owner and fake pmset only)')
    # Successful recovery clears only the matching token, never a newer owner's lease.
    fake_success = exe('success', 'exit 0\n')
    recovery = recovery.replace(repr(fake_sudo), repr(fake_success))
    lease.write_text('new-owner')
    subprocess.run(['/usr/bin/perl', '-e', recovery, str(lock), str(lease), 'owner'], check=True)
    assert lease.read_text() == 'new-owner'
    lease.write_text('owner')
    subprocess.run(['/usr/bin/perl', '-e', recovery, str(lock), str(lease), 'owner'], check=True)
    assert not lease.exists()
print('Actual watcher script checks passed (fake commands only)')
