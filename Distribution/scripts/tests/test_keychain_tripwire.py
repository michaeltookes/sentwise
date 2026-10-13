#!/usr/bin/env python3
"""Exercise the real macOS metadata query using disposable keychains only."""

import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "keychain-tripwire.sh"
SERVICE = "com.tookes.Sentwise"
MAILBOX = "mail.appPassword.person@example.com"
SECRET = "tripwire-test-secret-canary"


class KeychainTripwireTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="keychain-tripwire-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.keychain = self.root / "fixture.keychain-db"
        self.state = self.root / "snapshot.jsonl"
        self.security("create-keychain", "-p", "fixture-password")
        self.addCleanup(self.security, "delete-keychain")

    def security(self, *arguments):
        result = subprocess.run(
            ["security", *arguments, str(self.keychain)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def add(self, account, service=SERVICE, secret=SECRET):
        self.security("add-generic-password", "-U", "-s", service,
                      "-a", account, "-w", secret)

    def tripwire(self, mode, expected=0, keychain=None):
        result = subprocess.run(
            [str(SCRIPT), mode, str(self.state), str(keychain or self.keychain)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        if self.state.exists():
            self.assertNotIn(SECRET, self.state.read_text())
        return result

    def records(self):
        return [json.loads(line) for line in self.state.read_text().splitlines() if line]

    def test_empty_service_is_stable(self):
        self.tripwire("snapshot")
        self.assertEqual(self.records(), [])
        self.tripwire("verify")

    def test_enumerates_all_accounts_and_escapes_names(self):
        accounts = [MAILBOX, "managed.clientToken", "future.provider.apiKey",
                    'mail.appPassword.quoted"\tline\n@example.com']
        for account in accounts:
            self.add(account)
        self.tripwire("snapshot")
        records = self.records()
        self.assertEqual({row["account"] for row in records}, set(accounts))
        self.assertTrue(all(row["service"] == SERVICE for row in records))
        self.assertTrue(all(set(row) == {"service", "account", "mdat"} for row in records))
        lines = self.state.read_text().splitlines()
        self.assertEqual(lines, sorted(lines))
        self.tripwire("verify")

    def test_detects_mailbox_added_to_empty_service(self):
        self.tripwire("snapshot")
        self.add(MAILBOX)
        self.tripwire("verify", expected=1)

    def test_detects_new_mailbox_beside_existing_account(self):
        self.add("managed.clientToken")
        self.tripwire("snapshot")
        self.add(MAILBOX)
        self.tripwire("verify", expected=1)

    def test_detects_mailbox_password_rewrite(self):
        self.add(MAILBOX)
        self.tripwire("snapshot")
        # File-based Keychain mdat has one-second resolution.
        time.sleep(1.1)
        self.add(MAILBOX, secret=SECRET + "-changed")
        self.tripwire("verify", expected=1)

    def test_detects_mailbox_removed_beside_existing_account(self):
        self.add("managed.clientToken")
        self.add(MAILBOX)
        self.tripwire("snapshot")
        self.security("delete-generic-password", "-s", SERVICE, "-a", MAILBOX)
        self.tripwire("verify", expected=1)

    def test_detects_last_account_removed(self):
        self.add(MAILBOX)
        self.tripwire("snapshot")
        self.security("delete-generic-password", "-s", SERVICE, "-a", MAILBOX)
        self.tripwire("verify", expected=1)

    def test_ignores_other_services(self):
        self.add(MAILBOX)
        self.add(MAILBOX, service=SERVICE + ".tests")
        self.tripwire("snapshot")
        self.assertEqual(len(self.records()), 1)
        self.add("future.account", service="unrelated.service")
        self.add(MAILBOX, service=SERVICE + ".tests", secret=SECRET + "-changed")
        self.tripwire("verify")

    def test_missing_snapshot_is_an_error(self):
        self.tripwire("verify", expected=2)

    def test_unavailable_keychain_fails_closed(self):
        self.add(MAILBOX)
        self.tripwire("snapshot")
        snapshot = self.state.read_bytes()
        missing = self.root / "missing.keychain-db"
        self.tripwire("verify", expected=3, keychain=missing)
        self.assertEqual(self.state.read_bytes(), snapshot)
        self.tripwire("snapshot", expected=3, keychain=missing)
        self.assertFalse(self.state.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
