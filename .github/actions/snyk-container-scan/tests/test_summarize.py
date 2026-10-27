#!/usr/bin/env python3
"""Unit tests for summarize.py.

Run: python3 -m unittest discover -s .github/actions/snyk-container-scan/tests

No network, registry, or Snyk CLI: these fixtures stand in for what `snyk container test`
writes, and cover the part that decides PASS vs FAIL — how a threshold selects which
severities block, and that a CVE reported down several paths is counted once.
"""
import importlib.util
import pathlib
import sys
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "summarize.py"
spec = importlib.util.spec_from_file_location("summarize", SCRIPT)
summarize = importlib.util.module_from_spec(spec)
sys.modules["summarize"] = summarize
spec.loader.exec_module(summarize)


def vuln(vid, severity, package="pkg"):
    return {"id": vid, "severity": severity, "packageName": package, "version": "1.0.0"}


class CountsBySeverity(unittest.TestCase):
    def test_counts_each_severity(self):
        report = {"vulnerabilities": [
            vuln("A", "critical"), vuln("B", "high"), vuln("C", "high"),
            vuln("D", "medium"), vuln("E", "low"),
        ]}
        self.assertEqual(
            summarize.counts_by_severity(report),
            {"critical": 1, "high": 2, "medium": 1, "low": 1},
        )

    def test_same_id_on_many_paths_counts_once(self):
        report = {"vulnerabilities": [vuln("CVE-1", "high"), vuln("CVE-1", "high")]}
        self.assertEqual(summarize.counts_by_severity(report)["high"], 1)

    def test_ignores_unknown_severity(self):
        report = {"vulnerabilities": [vuln("A", "moderate"), vuln("B", "high")]}
        counts = summarize.counts_by_severity(report)
        self.assertEqual(counts["high"], 1)
        self.assertEqual(sum(counts.values()), 1)

    def test_merges_multi_target_array_report(self):
        report = [
            {"vulnerabilities": [vuln("A", "critical")]},
            {"vulnerabilities": [vuln("B", "high"), vuln("A", "critical")]},
        ]
        counts = summarize.counts_by_severity(report)
        self.assertEqual(counts["critical"], 1)  # A shared across targets, counted once
        self.assertEqual(counts["high"], 1)

    def test_no_vulnerabilities_key(self):
        self.assertEqual(
            summarize.counts_by_severity({"ok": True}),
            {"critical": 0, "high": 0, "medium": 0, "low": 0},
        )


class Threshold(unittest.TestCase):
    def setUp(self):
        self.counts = {"critical": 1, "high": 2, "medium": 4, "low": 8}

    def test_threshold_selects_level_and_above(self):
        self.assertEqual(summarize.at_or_above(self.counts, "critical"), 1)
        self.assertEqual(summarize.at_or_above(self.counts, "high"), 3)
        self.assertEqual(summarize.at_or_above(self.counts, "medium"), 7)
        self.assertEqual(summarize.at_or_above(self.counts, "low"), 15)

    def test_rejects_unknown_threshold(self):
        with self.assertRaises(ValueError):
            summarize.at_or_above(self.counts, "severe")


class Summarize(unittest.TestCase):
    def test_fail_when_a_finding_sits_at_or_above_threshold(self):
        report = {"vulnerabilities": [vuln("A", "high"), vuln("B", "low")]}
        summary = summarize.summarize(report, "high")
        self.assertEqual(summary["verdict"], "FAIL")
        self.assertEqual(summary["blocking"], 1)
        self.assertEqual(summary["total"], 2)

    def test_pass_when_findings_sit_below_threshold(self):
        report = {"vulnerabilities": [vuln("A", "medium"), vuln("B", "low")]}
        summary = summarize.summarize(report, "high")
        self.assertEqual(summary["verdict"], "PASS")
        self.assertEqual(summary["blocking"], 0)
        self.assertEqual(summary["total"], 2)

    def test_clean_report_passes(self):
        summary = summarize.summarize({"ok": True, "vulnerabilities": []}, "high")
        self.assertEqual(summary["verdict"], "PASS")
        self.assertEqual(summary["total"], 0)


if __name__ == "__main__":
    unittest.main()
