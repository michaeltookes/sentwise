#!/usr/bin/env python3
"""Checks that every env-gated live test is wired into the live pipeline.

A live test only runs on Lucius if (1) its variables are in the LIVE_VARS
allowlist of Distribution/scripts/inject-live-env.sh, (2) each required
variable is passed from a repository secret in .github/workflows/live-tests.yml,
and (3) its class is in that workflow's -only-testing list. Missing any of the
three means provisioning the secrets silently never runs the test (the item-104
GmailOAuthLiveTests gap). Optional *_HOST / *_PORT overrides only need (1).
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
TESTS = ROOT / "Sentwise" / "SentwiseTests"
INJECT = ROOT / "Distribution" / "scripts" / "inject-live-env.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "live-tests.yml"

VAR_PATTERN = re.compile(r'"(SENTWISE_(?:LIVE_[A-Z0-9_]+|INFERENCE_URL))"')
CLASS_PATTERN = re.compile(r"final class (\w+)\s*:\s*XCTestCase")
OPTIONAL_SUFFIXES = ("_HOST", "_PORT")


def live_test_files():
    for path in sorted(TESTS.glob("*.swift")):
        text = path.read_text()
        names = set(VAR_PATTERN.findall(text))
        if any(name.startswith("SENTWISE_LIVE_") for name in names):
            yield path, text, names


def allowlisted_vars():
    script = INJECT.read_text()
    block = re.search(r"LIVE_VARS=\((.*?)\)", script, re.S)
    assert block, "LIVE_VARS array not found in inject-live-env.sh"
    return set(block.group(1).split())


class LiveEnvWiringTests(unittest.TestCase):
    def setUp(self):
        self.files = list(live_test_files())
        self.workflow = WORKFLOW.read_text()
        self.allowlist = allowlisted_vars()

    def test_there_are_live_tests(self):
        self.assertTrue(self.files, "no env-gated live tests found")

    def test_every_variable_is_allowlisted_for_injection(self):
        for path, _, names in self.files:
            for name in names:
                self.assertIn(name, self.allowlist, f"{name} ({path.name}) missing from inject-live-env.sh")

    def test_every_required_variable_comes_from_a_repository_secret(self):
        for path, _, names in self.files:
            for name in names:
                if name.endswith(OPTIONAL_SUFFIXES):
                    continue
                self.assertIn(
                    f"{name}: ${{{{ secrets.{name} }}}}",
                    self.workflow,
                    f"{name} ({path.name}) is not passed from secrets in live-tests.yml",
                )

    def test_every_live_test_class_is_in_only_testing(self):
        for path, text, _ in self.files:
            for cls in CLASS_PATTERN.findall(text):
                self.assertIn(
                    f"-only-testing:SentwiseTests/{cls}",
                    self.workflow,
                    f"{cls} ({path.name}) is not in the live workflow's -only-testing list",
                )

    def test_live_workflow_stays_dispatch_only(self):
        on_block = re.search(r"^on:\n((?:[ #].*\n|\n)*)", self.workflow, re.M)
        self.assertTrue(on_block, "no on: block in live-tests.yml")
        triggers = re.findall(r"^  ([a-z_]+):", on_block.group(1), re.M)
        self.assertEqual(triggers, ["workflow_dispatch"])


if __name__ == "__main__":
    unittest.main()
