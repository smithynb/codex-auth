"""Offline CLI regression: python3 tests/list_terminal_test.py after zig build."""

from datetime import datetime
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
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

    def capture_tty(self, color, cols=180):
        master, slave = pty.openpty()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, cols, 0, 0))
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
                rows = lines[1:]
                self.assertEqual(len(rows), 2)
                for index, row in enumerate(rows):
                    self.assertEqual(header.index("ACCOUNT"), row.index("use***@e***.com"))
                    self.assertEqual(header.index("5H"), row.index(f"{90-index}%"))
                    self.assertEqual(header.index("WEEKLY"), row.index(f"{80-index}%"))

    def test_narrow_list_keeps_reset_credit_count_without_partial_expiry(self):
        registry = Path(self.home.name) / "accounts" / "registry.json"
        data = json.loads(registry.read_text())
        data["time_format"] = "12h"
        registry.write_text(json.dumps(data))
        output = ANSI.sub(b"", self.capture_tty(False, cols=60))
        self.assertNotIn(b"(exp ", output)
        self.assertEqual(len(re.findall(rb"(?<!\S)3(?!\S)", output)), 2)

    def test_redirected_output_has_no_cursor_controls(self):
        result = subprocess.run(["node", str(CLI), "list", "--skip-api"],
                                capture_output=True, env=self.env, check=True, timeout=10)
        self.assertNotIn(b"\x1b", result.stdout)
        self.assertNotIn(b"\r", result.stdout)
        self.assertTrue(result.stdout.startswith(b"    ACCOUNT"))

    def test_list_and_cancelled_switch_mask_emails_without_changing_registry(self):
        registry = Path(self.home.name) / "accounts" / "registry.json"
        before = json.loads(registry.read_text())
        for command in ["list", "switch"]:
            with self.subTest(command=command):
                result = subprocess.run(["node", str(CLI), command, "--skip-api"],
                                        input=b"q\n", capture_output=True, env=self.env,
                                        check=True, timeout=10)
                self.assertIn(b"use***@e***.com", result.stdout)
                self.assertNotIn(b"user0@example.com", result.stdout)
                self.assertNotIn(b"user1@example.com", result.stdout)
        after = json.loads(registry.read_text())
        self.assertEqual(before["active_account_key"], after["active_account_key"])
        self.assertEqual([a["email"] for a in before["accounts"]],
                         [a["email"] for a in after["accounts"]])

    def test_save_and_json_keep_legacy_expiry_and_upstream_cards(self):
        registry = Path(self.home.name) / "accounts" / "registry.json"
        data = json.loads(registry.read_text())
        expected = data["accounts"][0]["last_usage"]["reset_credits_expires_at"]
        cards = [{"id": "fixture-card", "status": "available",
                  "expires_at": "2100-01-01T00:00:00Z", "title": "Fixture"}]
        data["accounts"][0]["last_usage"]["reset_credit"] = cards
        registry.write_text(json.dumps(data))
        subprocess.run(["node", str(CLI), "config", "time", "--format", "12h"],
                       capture_output=True, env=self.env, check=True, timeout=10)
        saved = json.loads(registry.read_text())
        self.assertEqual(saved["time_format"], "12h")
        self.assertEqual(saved["accounts"][0]["last_usage"]["reset_credits_expires_at"], expected)
        result = subprocess.run(["node", str(CLI), "list", "--skip-api", "--json"],
                                capture_output=True, env=self.env, check=True, timeout=10)
        usage = json.loads(result.stdout)["accounts"][0]["usage"]
        self.assertEqual(usage["reset_credits_expires_at"], expected)
        self.assertEqual(usage["reset_credit"], cards)

    def test_responsive_twelve_hour_output_keeps_complete_clocks(self):
        registry = Path(self.home.name) / "accounts" / "registry.json"
        data = json.loads(registry.read_text())
        data["time_format"] = "12h"
        for account in data["accounts"]:
            account["access_token_expires_at"] = int(time.time()) + 3600
        registry.write_text(json.dumps(data))
        for cols in [20, 40, 60, 100, 180, 220]:
            with self.subTest(cols=cols):
                plain = ANSI.sub(b"", self.capture_tty(False, cols=cols)).decode()
                for line in plain.splitlines():
                    self.assertLessEqual(len(line), cols)
                for clock in re.finditer(r"\b\d{1,2}:\d{2}(?: [AP]M)?", plain):
                    self.assertTrue(clock.group().endswith((" AM", " PM")), clock.group())
                if cols == 220:
                    self.assertIn("TOKEN EXPIRE", plain)
                    self.assertRegex(plain, r"\d{4}-\d{2}-\d{2} \d{1,2}:\d{2} [AP]M")

    def test_plain_list_shows_earliest_available_card_expiry(self):
        registry = Path(self.home.name) / "accounts" / "registry.json"
        data = json.loads(registry.read_text())
        for account in data["accounts"]:
            usage = account["last_usage"]
            usage.pop("reset_credits_expires_at")
            usage["reset_credit"] = [
                {"id": "used", "status": "used", "expires_at": "2099-01-01T00:00:00Z"},
                {"id": "new", "status": "available", "expires_at": "2100-01-01T12:00:00Z"},
            ]
        registry.write_text(json.dumps(data))
        output = ANSI.sub(b"", self.capture_tty(False, cols=220))
        local_date = datetime.fromisoformat("2100-01-01T12:00:00+00:00").astimezone().strftime("%m-%d")
        self.assertEqual(output.count(f"3 (exp {local_date})".encode()), 2)

    def test_live_list_keeps_group_identity_and_quits_with_q(self):
        registry = Path(self.home.name) / "accounts" / "registry.json"
        data = json.loads(registry.read_text())
        data["time_format"] = "12h"
        for account, alias in zip(data["accounts"], ["first", "second"]):
            account["email"] = "shared@example.com"
            account["alias"] = alias
            account["access_token_expires_at"] = int(time.time()) + 3600
        registry.write_text(json.dumps(data))
        master, slave = pty.openpty()
        proc = None
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 200, 0, 0))
            env = {**self.env, "HOME": self.home.name, "NO_COLOR": "1"}
            proc = subprocess.Popen(["node", str(CLI), "list", "--live", "--skip-api"],
                                    stdin=slave, stdout=slave, stderr=slave, env=env)
            os.close(slave)
            slave = None
            output = bytearray()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    chunk = os.read(master, 65536)
                    output.extend(chunk)
                    if b"first" in output and b"second" in output:
                        break
            plain = ANSI.sub(b"", output).decode()
            self.assertIn("sha***@e***.com", plain)
            self.assertIn("first", plain)
            self.assertIn("second", plain)
            self.assertNotIn("shared@example.com", plain)
            self.assertRegex(plain, r"\d{1,2}:\d{2} [AP]M")
            os.write(master, b"q")
            proc.wait(timeout=5)
            self.assertEqual(proc.returncode, 0)
        finally:
            if proc is not None and proc.poll() is None:
                proc.kill()
                proc.wait()
            os.close(master)
            if slave is not None:
                os.close(slave)


if __name__ == "__main__":
    unittest.main()
