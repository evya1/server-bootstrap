#!/usr/bin/env python3
"""Run with ml-env python: require complete doctor results and exact lock pins."""
import argparse
from collections import Counter
from importlib import metadata
import json
from pathlib import Path
import re


def check_doctor(report, gpu):
    expected = {"pass": 37 if gpu else 36, "fail": 0, "skip": 0, "n/a": 0 if gpu else 1}
    checks = report["checks"]
    actual = Counter(check["status"] for check in checks)
    assert len({check["name"] for check in checks}) == len(checks), "duplicate doctor check"
    assert set(actual) <= set(expected), "unknown doctor status"
    assert report["summary"] == expected, f"doctor summary: {report['summary']}; expected {expected}"
    assert all(actual[key] == count for key, count in expected.items()), "doctor checks disagree with summary"


def check_versions(lock):
    pins = re.findall(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==(\S+)", lock, re.M)
    assert pins, "lock has no pinned packages"
    assert len({re.sub(r"[-_.]+", "-", name).lower() for name, _ in pins}) == len(pins), "duplicate lock package"
    for name, expected in pins:
        actual = metadata.version(name)
        assert actual == expected, f"{name}: installed {actual}; expected {expected}"
    return len(pins)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--doctor", type=Path, required=True)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--gpu", action="store_true")
    args = parser.parse_args()
    check_doctor(json.loads(args.doctor.read_text()), args.gpu)
    count = check_versions(args.lock.read_text())
    print(f"doctor: {'37 passed, 0 N/A' if args.gpu else '36 passed, 1 N/A'}, 0 failed, 0 skipped; {count} exact package versions")
