#!/usr/bin/env python3
"""Wiring test for .github/workflows/qa-build.yml (item 123).

Extracts the "Build the QA DMG" step's run script and executes it under
/bin/bash (Bash 3.2 on macOS runners, where `set -u` treats an empty array as
unbound) with qa-build.sh and `security` stubbed out, for every signing mode
and require_checkout value. Asserts the script exits 0 and passes exactly the
expected flags. Also syntax-checks Distribution/scripts/qa-build.sh, and runs
the --require-checkout value validation (Distribution/scripts/lib/
qa-checkout-values.sh) against placeholder, live, production, and valid
sandbox values.
"""
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "qa-build.yml")
SCRIPT = os.path.join(ROOT, "Distribution", "scripts", "qa-build.sh")
VALUES_LIB = os.path.join(ROOT, "Distribution", "scripts", "lib", "qa-checkout-values.sh")
EXAMPLE = os.path.join(ROOT, "Sentwise", "Config", "QA.local.xcconfig.example")

# Paddle's own sandbox test catalog shape (the values in PaddleConfig+TestSandbox).
VALID = {
    "clerk": "https://example-dev.clerk.accounts.dev",
    "token": "test_7a55409b65e7f906b94b863e63a",
    "starter": "pri_01m1syd7nfarp8pggpcnvjbgyy",
    "pro": "pri_01m1symsxarc4c3jdea0ntb09w",
    "unlimited": "pri_01m1syrdg05f49kz705gbzn6tz",
}
ORDER = ["clerk", "token", "starter", "pro", "unlimited"]


def build_step_script() -> str:
    lines = open(WORKFLOW, encoding="utf-8").read().splitlines()
    start = next(i for i, l in enumerate(lines) if l.strip() == "- name: Build the QA DMG")
    run = next(i for i in range(start, len(lines)) if lines[i].strip() == "run: |")
    indent = len(lines[run]) - len(lines[run].lstrip()) + 2
    body = []
    for line in lines[run + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) < indent:
            break
        body.append(line[indent:] if line.strip() else "")
    return "\n".join(body) + "\n"


class QABuildWorkflowWiring(unittest.TestCase):
    def run_step(self, signing: str, require_checkout: str) -> list:
        script = build_step_script()
        self.assertIn("qa-build.sh", script)
        with tempfile.TemporaryDirectory() as tmp:
            calls = os.path.join(tmp, "calls")
            stub_dir = os.path.join(tmp, "Distribution", "scripts")
            os.makedirs(stub_dir)
            stub = os.path.join(stub_dir, "qa-build.sh")
            with open(stub, "w", encoding="utf-8") as f:
                f.write('#!/bin/bash\nprintf "%s\\n" "$#" "$@" > "$CALLS"\n')
            os.chmod(stub, 0o755)
            bin_dir = os.path.join(tmp, "bin")
            os.makedirs(bin_dir)
            with open(os.path.join(bin_dir, "security"), "w", encoding="utf-8") as f:
                f.write("#!/bin/bash\nexit 0\n")
            os.chmod(os.path.join(bin_dir, "security"), 0o755)
            env = {
                "PATH": bin_dir + os.pathsep + os.environ.get("PATH", ""),
                "CALLS": calls,
                "SIGNING_MODE": signing,
                "REQUIRE_CHECKOUT": require_checkout,
                "SIGNING_KEYCHAIN_PW": "pw",
                "SIGNING_KEYCHAIN": "kc",
            }
            result = subprocess.run(
                ["/bin/bash", "-c", script], cwd=tmp, env=env, capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, f"{signing}/{require_checkout}: {result.stderr}")
            out = open(calls, encoding="utf-8").read().splitlines()
            count = int(out[0])
            return out[1:1 + count]

    def test_every_mode_passes_the_expected_flags(self):
        expected = {
            "developer-id": ["--notarize"],
            "developer-id-unnotarized": [],
            "unsigned": ["--unsigned"],
        }
        for signing, flags in expected.items():
            self.assertEqual(self.run_step(signing, "false"), flags, signing)
            self.assertEqual(self.run_step(signing, "true"), flags + ["--require-checkout"], signing)

    def test_qa_build_script_parses(self):
        result = subprocess.run(["/bin/bash", "-n", SCRIPT], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


def example_placeholders() -> dict:
    keys = {
        "SENTWISE_CLERK_FRONTEND_API_URL": "clerk",
        "SENTWISE_PADDLE_CLIENT_TOKEN": "token",
        "SENTWISE_PADDLE_STARTER_PRICE_ID": "starter",
        "SENTWISE_PADDLE_PRO_PRICE_ID": "pro",
        "SENTWISE_PADDLE_UNLIMITED_PRICE_ID": "unlimited",
    }
    values = {}
    with open(EXAMPLE, encoding="utf-8") as example:
        for line in example:
            name, sep, value = line.partition("=")
            if sep and name.strip() in keys:
                values[keys[name.strip()]] = value.strip().replace("$(SLASH)", "/")
    assert len(values) == len(keys), values
    return values


class QACheckoutValueValidation(unittest.TestCase):
    def check(self, **overrides) -> subprocess.CompletedProcess:
        values = dict(VALID, **overrides)
        return subprocess.run(
            ["/bin/bash", "-c", 'set -euo pipefail; source "$0"; qa_checkout_problems "$@"', VALUES_LIB]
            + [values[k] for k in ORDER],
            capture_output=True, text=True,
        )

    def host(self, url: str) -> str:
        result = subprocess.run(
            ["/bin/bash", "-c", 'set -euo pipefail; source "$0"; qa_normalized_host "$1"', VALUES_LIB, url],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def assertRejected(self, label: str, **overrides):
        result = self.check(**overrides)
        output = f"stdout={result.stdout!r} stderr={result.stderr!r}"
        self.assertNotEqual(result.returncode, 0, f"{label} was accepted; {output}")
        self.assertTrue(result.stdout.strip(), f"{label}: no problem reported; {output}")

    def test_valid_sandbox_values_are_accepted(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")

    def test_example_file_placeholders_are_rejected(self):
        placeholders = example_placeholders()
        self.assertRejected("all placeholders", **placeholders)
        for key, value in placeholders.items():
            self.assertRejected(f"placeholder {key}", **{key: value})

    def test_app_test_values_are_accepted(self):
        # The well-formed QA values BuildConfigurationTests resolves to a sandbox config.
        result = self.check(token="test_0qa1token2", starter="pri_01qastarter",
                            pro="pri_01qapro", unlimited="pri_01qaunlimited")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_alphanumeric_placeholder_token_is_rejected(self):
        self.assertRejected("YOUR token", token="test_YOURSANDBOXCLIENTTOKEN")
        self.assertRejected("lowercase your token", token="test_yoursandboxclienttoken")

    def test_clerk_url_with_query_fragment_or_userinfo_is_rejected(self):
        for clerk in ["https://example-dev.clerk.accounts.dev?x=1", "https://example-dev.clerk.accounts.dev/#x",
                      "https://example-dev.clerk.accounts.dev?", "https://user@example-dev.clerk.accounts.dev"]:
            self.assertRejected(f"clerk {clerk!r}", clerk=clerk)

    def test_live_token_is_rejected(self):
        self.assertRejected("live token", token="live_3affc7e38f8efd6ebd94616ab39")

    def test_production_price_ids_are_read_from_paddle_config(self):
        result = subprocess.run(
            ["/bin/bash", "-c", 'set -euo pipefail; source "$0"; qa_production_price_ids', VALUES_LIB],
            capture_output=True, text=True,
        )
        ids = result.stdout.split()
        self.assertEqual(result.returncode, 0, f"ids={ids} stderr={result.stderr!r}")
        self.assertEqual(ids, ["pri_01m307sdxtk64vb7yjn4vptrcx", "pri_01m307vkn7zf0k194trcmx0qg1",
                               "pri_01m307xfej4zjp0n7wkf4rf9cd"], f"ids={ids} stderr={result.stderr!r}")

    def test_moved_production_price_literals_fail_with_clear_message(self):
        source = """private enum ProductionValues {
        static let starterPriceID = starterReference
        static let proPriceID = proReference
        static let unlimitedPriceID = unlimitedReference
    }
    // Literals elsewhere must not make the independent validator constants look valid.
    let moved = [\"pri_movedstarter\", \"pri_movedpro\", \"pri_movedunlimited\"]
"""
        with tempfile.TemporaryDirectory() as tmp:
            config_dir = os.path.join(tmp, "Sentwise", "Sentwise", "Services", "Billing")
            os.makedirs(config_dir)
            with open(os.path.join(config_dir, "PaddleConfig.swift"), "w", encoding="utf-8") as config:
                config.write(source)
            result = subprocess.run(
                ["/bin/bash", "-c", 'set -euo pipefail; source "$0"; '
                 'QA_VALUES_REPO_ROOT="$1"; qa_production_price_ids', VALUES_LIB, tmp],
                capture_output=True, text=True,
            )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("expected exactly three literal production price ids in ProductionValues", result.stderr)

    def test_unreadable_production_price_ids_are_a_problem(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(
                ["/bin/bash", "-c", 'set -euo pipefail; source "$0"; QA_VALUES_REPO_ROOT="$1"; shift; '
                 'qa_checkout_problems "$@"', VALUES_LIB, tmp] + [VALID[k] for k in ORDER],
                capture_output=True, text=True,
            )
        self.assertNotEqual(result.returncode, 0, f"stdout={result.stdout!r} stderr={result.stderr!r}")
        self.assertIn("could not read the production price ids from PaddleConfig.swift", result.stdout)
        self.assertIn("PaddleConfig.swift", result.stderr)

    def test_production_price_ids_are_rejected(self):
        self.assertRejected("production starter", starter="pri_01m307sdxtk64vb7yjn4vptrcx")
        self.assertRejected("production pro", pro="pri_01m307vkn7zf0k194trcmx0qg1")
        self.assertRejected("production unlimited", unlimited="pri_01m307xfej4zjp0n7wkf4rf9cd")

    def test_malformed_missing_or_duplicate_price_ids_are_rejected(self):
        self.assertRejected("not a price id", starter="pro_01m1syd7nfarp8pggpcnvjbgyy")
        self.assertRejected("empty price id", pro="")
        self.assertRejected("duplicate price ids", pro=VALID["starter"])

    def test_production_or_malformed_clerk_url_is_rejected(self):
        for clerk in ["https://clerk.sentwise.ai", "https://CLERK.sentwise.ai/", "https://clerk.sentwise.ai.",
                      "https://clerk.sentwise.ai../", "http://example-dev.clerk.accounts.dev", "", "not a url"]:
            self.assertRejected(f"clerk {clerk!r}", clerk=clerk)

    def test_hosts_are_normalized(self):
        self.assertEqual(self.host("https://Clerk.Sentwise.AI./v1"), "clerk.sentwise.ai")
        self.assertEqual(self.host("https://sentwise-inference.sentwise-service.workers.dev.:443/"),
                         "sentwise-inference.sentwise-service.workers.dev")
        self.assertEqual(self.host("http://example.com"), "")
        self.assertEqual(self.host("https://user@example.com"), "")


if __name__ == "__main__":
    sys.exit(unittest.main())
