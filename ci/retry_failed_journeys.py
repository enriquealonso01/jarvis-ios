#!/usr/bin/env python3
"""Give each Maestro journey that failed one more try, and print the lane's final word on it.

The QA lane's 3-core runner stalls the stub host often enough (a lost confirmation, a dropped
socket) that one red journey in twelve was the usual result. A journey that fails again on its
own is a real failure; one that passes was the runner.

    python3 ci/retry_failed_journeys.py --report qa-out/report.xml --flows qa/maestro \
        --device <udid> --out qa-out/maestro-retry

Prints one line per failed journey, which `ios-ci-wait --journeys` reads:

    PASSED-ON-RETRY: <journey name>
    FINAL-FAILED: <journey name>

Exits 0 when every failed journey passed its retry, 1 otherwise. More than --max failures is a
broken build, not a flake: none is retried and all are final. A report that cannot be read fails
too, so a crashed first pass never turns green here.
"""

import argparse
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def failed_journeys(report):
    """(name, flow file or None) for each journey the JUnit report marks failed, in order."""
    root = ET.parse(report).getroot()
    failed = []
    for case in root.iter("testcase"):
        status = (case.get("status") or "").upper()
        if case.find("failure") is None and case.find("error") is None and status != "ERROR":
            continue
        name = case.get("name") or case.get("id") or ""
        if name:
            failed.append((name, case.get("file")))
    return failed


def flow_file(name, reported, flows):
    """The journey's file: the report's own path, else the flow in `flows` with that `name:`."""
    if reported and Path(reported).is_file():
        return Path(reported)
    for path in sorted(Path(flows).glob("*.yaml")):
        try:
            head = path.read_text(encoding="utf-8").split("\n---", 1)[0]
        except OSError:
            continue
        if re.search(r"^name:\s*%s\s*$" % re.escape(name), head, re.MULTILINE):
            return path
    return None


def slug(name):
    return re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-").lower() or "journey"


def retry_command(device, out, name, path):
    target = Path(out) / slug(name)
    return ["maestro", "--device", device, "test", "--format", "junit",
            "--output", str(target) + ".xml", "--test-output-dir", str(target), str(path)]


def run(report, flows, device, out, limit=4, call=subprocess.call, say=print):
    """Retries what failed and returns the exit code; `call` runs one command."""
    try:
        failed = failed_journeys(report)
    except (OSError, ET.ParseError) as error:
        say("RETRY-SKIPPED: the first pass left no readable report (%s)" % error)
        return 1
    if not failed:
        say("RETRY-SKIPPED: the report names no failed journey, so the first pass failed outside one")
        return 1
    if len(failed) > limit:
        say("RETRY-SKIPPED: %d journeys failed, more than %d: a broken build, not a flake" % (len(failed), limit))
        for name, _ in failed:
            say("FINAL-FAILED: %s" % name)
        return 1
    Path(out).mkdir(parents=True, exist_ok=True)
    final = 0
    for name, reported in failed:
        path = flow_file(name, reported, flows)
        if path is None:
            say("FINAL-FAILED: %s" % name)
            say("  (no flow file found for it under %s)" % flows)
            final = 1
            continue
        say("---- retrying: %s" % name)
        sys.stdout.flush()
        if call(retry_command(device, out, name, path)) == 0:
            say("PASSED-ON-RETRY: %s" % name)
        else:
            say("FINAL-FAILED: %s" % name)
            final = 1
    return final


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--report", required=True, help="the first pass's JUnit report")
    parser.add_argument("--flows", required=True, help="the folder the journeys live in")
    parser.add_argument("--device", required=True, help="the simulator's UDID")
    parser.add_argument("--out", required=True, help="where the retries' reports and screenshots go")
    parser.add_argument("--max", type=int, default=4, dest="limit",
                        help="more failures than this are not retried (default 4)")
    args = parser.parse_args(argv)
    return run(args.report, args.flows, args.device, args.out, args.limit)


if __name__ == "__main__":
    sys.exit(main())
