import os, pathlib, tempfile, subprocess, pty, select, time, errno, json

source = (pathlib.Path(__file__).resolve().parents[1] / 'bin' / 'codex-auth.js').read_text()
with tempfile.TemporaryDirectory(prefix='codex-auth-test-') as tmp:
    root = pathlib.Path(tmp)
    fake = root / 'fake-auth'
    fake.write_text('''#!/usr/bin/env python3
import os, pathlib, sys, json
if '--restart-daemon' in sys.argv:
 if '--json' in sys.argv:
  assert sys.argv[1:] == ['switch', 'fixture-user::selected', '--json', '--restart-daemon'], sys.argv
 pathlib.Path(os.environ['TEST_MARKER']).write_text('recovered')
 print(json.dumps({'email':'private@example.com'}))
 sys.exit(int(os.environ.get('TEST_RESTART_EXIT', '0')))
if os.environ['TEST_MODE'] == 'failed': sys.exit(7)
if os.environ['TEST_MODE'] != 'unchanged' and '--help' not in sys.argv:
 pathlib.Path(os.environ['CODEX_HOME'], 'auth.json').write_text('new fixture')
 pathlib.Path(os.environ['CODEX_HOME'], 'accounts', 'registry.json').write_text(json.dumps({'active_account_key':'fixture-user::selected'}))
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
        ('Recovery failure exits nonzero', 'changed', ['switch','fixture'], '\n', True, True, 1, True, 9),
        ('Explicit recovery avoids prompt', 'changed', ['switch','fixture','--restart-daemon'], None, False, True, 0, True, 0),
        ('Explicit stale recovery', 'unchanged', ['switch','fixture','--restart-daemon'], None, False, True, 0, False, 0),
        ('Previous switch recovers selected key', 'changed', ['switch','-'], '\n', True, True, 0, True, 0),
        ('Concurrent auth change is preserved', 'concurrent-auth', ['switch','fixture'], '\n', True, False, 1, True, 0),
        ('Concurrent account change is preserved', 'concurrent-key', ['switch','fixture'], '\n', True, False, 1, True, 0),
        ('Live exit preserves prompt', 'changed', ['switch','--live'], '\n', True, True, 0, True, 0),
    ]
    (root / 'accounts').mkdir()
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
                    if mode == 'concurrent-auth':
                        (root / 'auth.json').write_text('concurrent fixture')
                    if mode == 'concurrent-key':
                        (root / 'accounts' / 'registry.json').write_text(json.dumps({'active_account_key': 'another-user::account'}))
                    os.write(master,answer.encode()); sent = True
                if proc.poll() is not None: break
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                raise AssertionError(name+': timed out')
            os.close(master)
        else:
            proc = subprocess.run(['node',str(launcher),*args], input='', capture_output=True, text=True, env=env, timeout=5)
            output = (proc.stdout+proc.stderr).encode()
        assert (b'[Y/n]' in output) == want_prompt, name+': prompt mismatch'
        assert marker.exists() == want_restart, name+': restart mismatch'
        assert proc.returncode == want_exit, name+': exit mismatch'
        if restart_exit: assert b'daemon recovery failed' in output, name+': missing error'
        if want_prompt: assert b'private@example.com' not in output, name+': internal JSON leaked'
        assert output.count(b'[Y/n]') == int(want_prompt), name+': duplicate prompt'
        if mode == 'concurrent-auth': assert (root / 'auth.json').read_text() == 'concurrent fixture'
        if mode == 'concurrent-key': assert json.loads((root / 'accounts' / 'registry.json').read_text())['active_account_key'] == 'another-user::account'
        print('PASS '+name)

# Integration boundary: real launcher and native CLI, isolated auth files and a
# fake managed Codex executable. No real account or daemon is accessed.
import base64

project = pathlib.Path(__file__).resolve().parents[1]
native = project / 'zig-out' / 'bin' / 'codex-auth'


def run_prompt(command, env, answer):
    master, slave = pty.openpty()
    proc = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    output = bytearray()
    sent = False
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            if not select.select([master], [], [], 0.05)[0]:
                if proc.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
            if not sent and b'[Y/n]' in output:
                os.write(master, answer.encode())
                sent = True
        proc.wait(timeout=2)
        return proc.returncode, bytes(output)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        os.close(master)


for mode, answer in [('reload', '\n'), ('fallback', 'yes\n'), ('busy', '\n'),
                     ('failure', '\n'), ('reload', 'n\n'), ('previous', '\n'),
                     ('unchanged', None)]:
    with tempfile.TemporaryDirectory(prefix='codex-auth-native-recovery-') as tmp:
        root = pathlib.Path(tmp)
        env = dict(os.environ, HOME=tmp, CODEX_HOME=tmp, NO_COLOR='1',
                   CODEX_AUTH_SKIP_SERVICE_RECONCILE='1', TEST_DAEMON_MODE=mode)
        (root / 'accounts').mkdir()
        records = []
        for number, name in enumerate(['alpha', 'beta'], 1):
            account_id = f'{number:08}-1111-4111-8111-111111111111'
            claims = {'email': f'{name}@example.com', 'https://api.openai.com/auth': {
                'chatgpt_user_id': f'fixture-{name}', 'chatgpt_account_id': account_id,
                'chatgpt_plan_type': 'plus'}}
            payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip('=')
            auth = {'tokens': {'id_token': f'e30.{payload}.fixture',
                              'access_token': f'fake-access-{name}', 'account_id': account_id}}
            key = f'fixture-{name}::{account_id}'
            filename = base64.urlsafe_b64encode(key.encode()).decode().rstrip('=') + '.auth.json'
            (root / 'accounts' / filename).write_text(json.dumps(auth))
            records.append({'account_key': key, 'chatgpt_user_id': f'fixture-{name}',
                            'chatgpt_account_id': account_id, 'email': f'{name}@example.com',
                            'alias': name, 'plan': 'plus', 'auth_mode': 'chatgpt', 'created_at': 1})
        (root / 'accounts' / 'registry.json').write_text(json.dumps({
            'schema_version': 4, 'active_account_key': None,
            'interval_seconds': 60, 'accounts': records}))
        initial = 'beta' if mode in ['previous', 'unchanged'] else 'alpha'
        subprocess.run([str(native), 'switch', initial, '--json'], env=env,
                       capture_output=True, timeout=5, check=True)
        if mode == 'previous':
            # Establish alpha as the previous account before using switch -.
            subprocess.run([str(native), 'switch', 'alpha', '--json'], env=env,
                           capture_output=True, timeout=5, check=True)
            subprocess.run([str(native), 'switch', 'beta', '--json'], env=env,
                           capture_output=True, timeout=5, check=True)
        managed = root / 'packages' / 'app-server-daemon' / 'current' / 'bin' / 'codex'
        managed.parent.mkdir(parents=True)
        endpoint = root / 'app-server-control' / 'app-server-control.sock'
        endpoint.parent.mkdir()
        endpoint.touch()
        managed.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
home = pathlib.Path(os.environ['CODEX_HOME'])
assert sys.argv[1:3] == ['app-server', 'daemon']
command = sys.argv[3]
with (home / 'lifecycle-calls').open('a') as log: log.write(command + '\\n')
mode = os.environ['TEST_DAEMON_MODE']
if command == 'version':
 print(json.dumps({'status': 'running', 'appServerVersion': 'fixture'})); sys.exit(0)
if command == 'reload-auth':
 if mode in ['fallback', 'failure']: sys.exit(92)
 if mode == 'busy': print('Daemon skipped the auth reload because a turn is running.')
 else: print('Daemon reloaded auth; the account changed.')
 sys.exit(0)
if command == 'restart': sys.exit(42 if mode == 'failure' else 0)
sys.exit(93)
''')
        managed.chmod(0o700)
        args = ['switch', '-' if mode == 'previous' else 'beta']
        if mode == 'unchanged':
            result = subprocess.run(['node', str(project / 'bin' / 'codex-auth.js'),
                                     *args, '--json', '--restart-daemon'], env=env,
                                    capture_output=True, timeout=10)
            code, output = result.returncode, result.stdout + result.stderr
            assert json.loads(result.stdout)['command'] == 'switch'
            assert b'[Y/n]' not in output
        else:
            code, output = run_prompt(['node', str(project / 'bin' / 'codex-auth.js'), *args], env, answer)
            assert output.count(b'[Y/n]') == 1, (mode, output)
            assert b'"switched_to"' not in output, (mode, 'internal JSON exposed')
            assert b'alpha@example.com' not in output and b'beta@example.com' not in output
        assert code == (1 if mode == 'failure' else 0), (mode, code, output)
        calls = (root / 'lifecycle-calls').read_text().splitlines()
        if answer == 'n\n': expected = ['version']
        elif mode in ['fallback', 'failure']:
            expected = ['version', 'version', 'reload-auth', 'version', 'restart']
        elif mode == 'unchanged': expected = ['version', 'reload-auth']
        else: expected = ['version', 'version', 'reload-auth']
        assert calls == expected, (mode, calls, output)
        reg = json.loads((root / 'accounts' / 'registry.json').read_text())
        selected = 'alpha' if mode == 'previous' else 'beta'
        selected_record = next(a for a in reg['accounts'] if a['alias'] == selected)
        assert reg['active_account_key'] == selected_record['account_key']
        if mode != 'unchanged':
            previous = next(a for a in reg['accounts'] if a['alias'] != selected)
            assert reg['previous_active_account_key'] == previous['account_key']
        print(f'PASS real launcher/native recovery: {mode}, answer={answer!r}')

print('All recovery tests used isolated credentials and fake daemons; real accounts/daemon untouched.')
