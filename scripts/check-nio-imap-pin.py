#!/usr/bin/env python3
"""Fail if a resolved swift-nio-imap is 0.5.0 or later (item 146).

0.5.0 is the first tag declaring platforms .macOS(.v15); the app targets
macOS 14, so builds fail with "requires minimum platform version 15.0".
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = [
    ROOT / "Packages/SentwiseMail/Package.resolved",
    ROOT / "Sentwise/Sentwise.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
]
LIMIT = (0, 5, 0)


def parse(version):
    return tuple(int(p) for p in version.split("-")[0].split(".")[:3])


bad = False
for f in FILES:
    if not f.exists():
        print(f"::error::{f.relative_to(ROOT)} is missing; it must be committed")
        bad = True
        continue
    data = json.loads(f.read_text())
    pins = data.get("pins") or data.get("object", {}).get("pins", [])
    for pin in pins:
        if pin.get("identity", "").lower() != "swift-nio-imap":
            continue
        version = pin["state"].get("version")
        if version is None or parse(version) >= LIMIT:
            print(f"::error::swift-nio-imap resolved to {version} in "
                  f"{f.relative_to(ROOT)}; must stay below 0.5.0 (macOS 15 floor)")
            bad = True
        else:
            print(f"ok: swift-nio-imap {version} in {f.relative_to(ROOT)}")
sys.exit(1 if bad else 0)
