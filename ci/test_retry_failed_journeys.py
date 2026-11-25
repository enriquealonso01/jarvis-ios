"""Run with: python3 -m unittest discover -s ci -p 'test_*.py' -v"""

from pathlib import Path
import tempfile
import unittest

import retry_failed_journeys as retry


def report(cases):
    """A JUnit report as Maestro writes it: `cases` is (name, file, failure text or None)."""
    rows = []
    for name, file, failure in cases:
        attrs = 'id="%s" name="%s" classname="%s" file="%s" time="1.0"' % (name, name, name, file)
        if failure is None:
            rows.append('<testcase %s status="SUCCESS"/>' % attrs)
        else:
            rows.append('<testcase %s status="ERROR"><failure>%s</failure></testcase>' % (attrs, failure))
    return ("<?xml version='1.0' encoding='UTF-8'?>\n<testsuites><testsuite name=\"Test Suite\" tests=\"%d\">%s"
            "</testsuite></testsuites>" % (len(cases), "".join(rows)))


class RetryFailedJourneysTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.flows = self.dir / "flows"
        self.flows.mkdir()
        self.out = self.dir / "out"
        self.said = []
        self.calls = []

    def flow(self, file, name):
        path = self.flows / file
        path.write_text("appId: com.example\nname: %s\n---\n- launchApp\n" % name, encoding="utf-8")
        return path

    def write(self, cases):
        path = self.dir / "report.xml"
        path.write_text(report(cases), encoding="utf-8")
        return path

    def run_retry(self, cases, results=(), limit=4):
        codes = list(results)

        def call(command):
            self.calls.append(command)
            return codes.pop(0)

        return retry.run(self.write(cases), self.flows, "UDID", self.out, limit, call=call, say=self.said.append)

    def test_a_journey_that_passes_its_retry_turns_the_lane_green(self):
        three = self.flow("03-new-session.yaml", "03 new session")
        code = self.run_retry([("01 sign in", self.flow("01.yaml", "01 sign in"), None),
                               ("03 new session", three, "Assertion is false")], results=[0])
        self.assertEqual(code, 0)
        self.assertIn("PASSED-ON-RETRY: 03 new session", self.said)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][-1], str(three))
        self.assertEqual(self.calls[0][:4], ["maestro", "--device", "UDID", "test"])

    def test_a_journey_that_fails_twice_is_final(self):
        code = self.run_retry([("03 new session", self.flow("03.yaml", "03 new session"), "x"),
                               ("06 voice note", self.flow("06.yaml", "06 voice note"), "y")], results=[1, 0])
        self.assertEqual(code, 1)
        self.assertIn("FINAL-FAILED: 03 new session", self.said)
        self.assertIn("PASSED-ON-RETRY: 06 voice note", self.said)

    def test_more_failures_than_the_limit_are_not_retried(self):
        cases = [("%02d journey" % n, self.flow("%02d.yaml" % n, "%02d journey" % n), "x") for n in range(1, 4)]
        code = self.run_retry(cases, limit=2)
        self.assertEqual(code, 1)
        self.assertEqual(self.calls, [])
        self.assertEqual([line for line in self.said if line.startswith("FINAL-FAILED: ")],
                         ["FINAL-FAILED: 01 journey", "FINAL-FAILED: 02 journey", "FINAL-FAILED: 03 journey"])

    def test_a_missing_or_broken_report_fails_without_retrying(self):
        code = retry.run(self.dir / "none.xml", self.flows, "UDID", self.out, say=self.said.append,
                         call=self.calls.append)
        self.assertEqual(code, 1)
        broken = self.dir / "broken.xml"
        broken.write_text("<testsuites><testsuite>", encoding="utf-8")
        self.assertEqual(retry.run(broken, self.flows, "UDID", self.out, say=self.said.append,
                                   call=self.calls.append), 1)
        self.assertEqual(self.calls, [])
        self.assertTrue(all(line.startswith("RETRY-SKIPPED: ") for line in self.said))

    def test_a_failed_first_pass_with_no_failed_journey_stays_failed(self):
        code = self.run_retry([("01 sign in", self.flow("01.yaml", "01 sign in"), None)])
        self.assertEqual(code, 1)
        self.assertEqual(self.calls, [])

    def test_a_report_without_the_file_finds_the_flow_by_its_name(self):
        path = self.flow("12-first-send.yaml", "12 first send loading row shows immediately")
        self.flow("11.yaml", "11 plan strip")
        code = self.run_retry([("12 first send loading row shows immediately", "/gone/12.yaml", "x")], results=[0])
        self.assertEqual(code, 0)
        self.assertEqual(self.calls[0][-1], str(path))

    def test_a_journey_with_no_flow_file_is_final(self):
        code = self.run_retry([("99 nowhere", "/gone/99.yaml", "x")])
        self.assertEqual(code, 1)
        self.assertEqual(self.calls, [])
        self.assertIn("FINAL-FAILED: 99 nowhere", self.said)

    def test_each_retry_keeps_its_own_report_and_screenshots(self):
        self.run_retry([("03 new session send approve and reply", self.flow("03.yaml", "03 new session send approve and reply"), "x")],
                       results=[0])
        command = self.calls[0]
        target = str(self.out / "03-new-session-send-approve-and-reply")
        self.assertEqual(command[command.index("--output") + 1], target + ".xml")
        self.assertEqual(command[command.index("--test-output-dir") + 1], target)


if __name__ == "__main__":
    unittest.main()
