"""Check actual launcher help ordering and terminal colors without account access."""
import errno
import os
import pathlib
import pty
import re
import subprocess
import tempfile

launcher = pathlib.Path(__file__).resolve().parents[1] / 'bin' / 'codex-auth.js'


def check(output, colored):
    text = output.decode()
    plain = re.sub(r'\x1b\[[0-9;]*m', '', text)
    assert plain.index('Personal commands:') < plain.index('codex-auth 0.'), repr(text)
    assert plain.count('Personal commands:') == 1, text
    assert 'aliases: tickle, ping' in plain, text
    if colored:
        assert '\x1b[1;35mPersonal commands:\x1b[0m' in text, repr(text)
        assert '\x1b[35mpoke\x1b[0m' in text, repr(text)
    else:
        # The upstream native binary controls its own color policy.
        personal = text[:text.index('(aliases: tickle, ping)') + len('(aliases: tickle, ping)')]
        assert '\x1b[' not in personal, repr(personal)


with tempfile.TemporaryDirectory(prefix='codex-help-test-') as home:
    env = dict(os.environ, HOME=home, CODEX_HOME=home, TERM='xterm-256color')
    env.pop('NO_COLOR', None)
    for args in [[], ['help'], ['--help'], ['-h']]:
        result = subprocess.run(['node', str(launcher), *args], env=env,
                                capture_output=True, timeout=5, check=True)
        check(result.stdout, False)
        print('PASS plain help:', args)

    for no_color in [False, True]:
        tty_env = dict(env)
        if no_color:
            tty_env['NO_COLOR'] = ''
        master, slave = pty.openpty()
        proc = subprocess.Popen(['node', str(launcher), 'help'], env=tty_env,
                                stdin=subprocess.DEVNULL, stdout=slave,
                                stderr=subprocess.DEVNULL)
        os.close(slave)
        output = bytearray()
        try:
            # Native top-level help does no account work and exits immediately.
            proc.wait(timeout=5)
            while True:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
            assert proc.returncode == 0
            check(output, not no_color)
            print('PASS TTY help:', 'NO_COLOR' if no_color else 'colored')
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            os.close(master)
    assert not list(pathlib.Path(home).iterdir()), 'Help modified isolated account home'
print('Help ordering/colors verified; no accounts or daemon accessed.')
