#!/usr/bin/env python3
"""Wiring test for .github/workflows/qa-build.yml (item 123).

Extracts the "Build the QA DMG" step's run script and executes it under
/bin/bash (Bash 3.2 on macOS runners, where `set -u` treats an empty array as
unbound) with qa-build.sh and `security` stubbed out, for every signing mode
and require_checkout value. Asserts the script exits 0 and passes exactly the
expected flags. Also syntax-checks Distribution/scripts/qa-build.sh.
"""
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "qa-build.yml")
SCRIPT = os.path.join(ROOT, "Distribution", "scripts", "qa-build.sh")


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


if __name__ == "__main__":
    sys.exit(unittest.main())
