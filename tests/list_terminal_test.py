"""Offline CLI regression: python3 tests/list_terminal_test.py after zig build."""

import fcntl
import json
import os
from pathlib import Path
import pty
import re
import struct
import subprocess
import tempfile
import termios
import time
import unittest


CLI = Path(__file__).resolve().parents[1] / "bin" / "codex-auth.js"
ANSI = re.compile(rb"\x1b\[[0-9;]*[A-Za-z]")


class ListTerminalTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory(prefix="list-terminal-test-")
        self.addCleanup(self.home.cleanup)
        accounts = Path(self.home.name) / "accounts"
        accounts.mkdir()
        now = int(time.time())
        records = []
        for index, plan in enumerate(["plus", "business"]):
            records.append({
                "account_key": f"fixture::{index}",
                "chatgpt_user_id": "fixture",
                "chatgpt_account_id": str(index),
                "email": f"user{index}@example.com",
                "alias": "", "plan": plan, "created_at": now,
                "last_usage_at": now,
                "last_usage": {
                    "primary": {"used_percent": 10 + index, "window_minutes": 300,
                                "resets_at": now + 18000},
                    "secondary": {"used_percent": 20 + index, "window_minutes": 10080,
                                  "resets_at": now + 604800},
                    "reset_credits": 3, "reset_credits_expires_at": now + 172800,
                    "plan_type": plan,
                },
            })
        (accounts / "registry.json").write_text(json.dumps({
            "schema_version": 4, "active_account_key": "fixture::1",
            "interval_seconds": 60, "accounts": records,
        }))
        self.env = {**os.environ, "CODEX_HOME": self.home.name, "TERM": "xterm-256color"}
        self.env.pop("CLICOLOR_FORCE", None)

    def capture_tty(self, color):
        master, slave = pty.openpty()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 180, 0, 0))
            os.write(slave, b"codex-auth pok")
            env = dict(self.env)
            env.pop("NO_COLOR", None)
            if not color:
                env["NO_COLOR"] = "1"
            subprocess.run(["node", str(CLI), "list", "--skip-api"],
                           stdout=slave, stderr=slave, env=env, check=True, timeout=10)
            os.close(slave)
            slave = None
            output = bytearray()
            while True:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
            return bytes(output)
        finally:
            os.close(master)
            if slave is not None:
                os.close(slave)

    def test_header_clears_pending_text_and_aligns_usage_with_or_without_color(self):
        for color in [True, False]:
            with self.subTest(color=color):
                output = self.capture_tty(color)
                self.assertTrue(output.startswith(b"codex-auth pok\r\x1b[2K"))
                lines = ANSI.sub(b"", output.split(b"\r\x1b[2K", 1)[1]).decode().splitlines()
                header = lines[0]
                rows = lines[2:]
                self.assertEqual(len(rows), 2)
                for index, row in enumerate(rows):
                    self.assertEqual(header.index("ACCOUNT"), row.index(f"user{index}@"))
                    self.assertEqual(header.index("5H"), row.index(f"{90-index}%"))
                    self.assertEqual(header.index("WEEKLY"), row.index(f"{80-index}%"))

    def test_redirected_output_has_no_cursor_controls(self):
        result = subprocess.run(["node", str(CLI), "list", "--skip-api"],
                                capture_output=True, env=self.env, check=True, timeout=10)
        self.assertNotIn(b"\x1b", result.stdout)
        self.assertNotIn(b"\r", result.stdout)
        self.assertTrue(result.stdout.startswith(b"     ACCOUNT"))


if __name__ == "__main__":
    unittest.main()
