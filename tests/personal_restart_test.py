import os, pathlib, tempfile, subprocess, pty, select, time, errno

source = (pathlib.Path(__file__).resolve().parents[1] / 'bin' / 'codex-auth.js').read_text()
with tempfile.TemporaryDirectory(prefix='codex-auth-test-') as tmp:
    root = pathlib.Path(tmp)
    fake = root / 'fake-auth'
    fake.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
if os.environ['TEST_MODE'] == 'failed': sys.exit(7)
if os.environ['TEST_MODE'] != 'unchanged' and '--help' not in sys.argv:
 pathlib.Path(os.environ['CODEX_HOME'], 'auth.json').write_text('new fixture')
''')
    fake.chmod(0o755)
    codex = root / 'codex'
    codex.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
assert sys.argv[1:] == ['app-server', 'daemon', 'restart']
pathlib.Path(os.environ['TEST_MARKER']).write_text('restarted')
sys.exit(int(os.environ.get('TEST_RESTART_EXIT', '0')))
''')
    codex.chmod(0o755)
    launcher = root / 'launcher.mjs'
    launcher.write_text(source.replace('const binaryPath = resolveBinary();', f'const binaryPath = {str(fake)!r};'))
    cases = [
        ('Enter defaults yes', 'changed', ['switch','fixture'], '\n', True, True, 0, True, 0),
        ('Explicit yes', 'changed', ['switch','fixture'], 'Y\n', True, True, 0, True, 0),
        ('No declines', 'changed', ['switch','fixture'], 'n\n', True, False, 0, True, 0),
        ('Cancelled/no change', 'unchanged', ['switch'], None, False, False, 0, True, 0),
        ('Failed switch', 'failed', ['switch','fixture'], None, False, False, 7, True, 0),
        ('Help', 'changed', ['switch','--help'], None, False, False, 0, True, 0),
        ('JSON', 'changed', ['switch','fixture','--json'], None, False, False, 0, True, 0),
        ('Other command', 'changed', ['list'], None, False, False, 0, True, 0),
        ('Noninteractive', 'changed', ['switch','fixture'], None, False, False, 0, False, 0),
        ('Restart failure reported', 'changed', ['switch','fixture'], '\n', True, True, 0, True, 9),
    ]
    for name, mode, args, answer, want_prompt, want_restart, want_exit, tty, restart_exit in cases:
        (root / 'auth.json').write_text('old fixture')
        marker = root / 'restart-marker'
        marker.unlink(missing_ok=True)
        env = dict(os.environ, CODEX_HOME=tmp, TEST_MODE=mode, TEST_MARKER=str(marker), TEST_RESTART_EXIT=str(restart_exit), PATH=tmp+':'+os.environ['PATH'])
        output = b''
        if tty:
            master, slave = pty.openpty()
            proc = subprocess.Popen(['node',str(launcher),*args], stdin=slave, stdout=slave, stderr=slave, env=env)
            os.close(slave)
            deadline = time.monotonic()+5
            sent = False
            while time.monotonic() < deadline:
                if select.select([master],[],[],0.05)[0]:
                    try: chunk = os.read(master,65536)
                    except OSError as e:
                        if e.errno == errno.EIO: break
                        raise
                    if not chunk: break
                    output += chunk
                if answer is not None and not sent and b'[Y/n]' in output:
                    os.write(master,answer.encode()); sent = True
                if proc.poll() is not None: break
            if proc.poll() is None:
                proc.kill(); raise AssertionError(name+': timed out')
            proc.wait()
            os.close(master)
        else:
            proc = subprocess.run(['node',str(launcher),*args], input='', capture_output=True, text=True, env=env, timeout=5)
            output = (proc.stdout+proc.stderr).encode()
        assert (b'[Y/n]' in output) == want_prompt, name+': prompt mismatch'
        assert marker.exists() == want_restart, name+': restart mismatch'
        assert proc.returncode == want_exit, name+': exit mismatch'
        if restart_exit: assert b'daemon restart failed' in output, name+': missing error'
        print('PASS '+name)
print('All tests used isolated fake credentials and a fake daemon; real accounts/daemon untouched.')
