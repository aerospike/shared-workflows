"""Tests for conformance report aggregation."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "collect_report.py"
spec = importlib.util.spec_from_file_location("collect_report", SCRIPT)
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

VERSION = "1.0.0"
FILE = "discovery/translate/port-map.yaml"
CASE = "host-port-key-hit"
TLS_FILE = "tls/name-matching.yaml"


class CollectReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.work)
        self.reports = self.work / "reports"
        self.fixtures = self.work / "fixtures"
        self.declarations = self.work / "declarations"
        for directory in (self.reports, self.fixtures, self.declarations):
            directory.mkdir()

    def fixture_set(self, cases, blocked=()):
        (self.fixtures / "VERSION").write_text(f"{VERSION}\n", encoding="utf-8")
        by_file: dict[str, list[str]] = {}
        for file_name, case_name in cases:
            by_file.setdefault(file_name, []).append(case_name)
        for file_name, case_names in by_file.items():
            lines = [f"kind: {'tls' if file_name.startswith('tls/') else 'translate'}", "rows:"]
            for case_name in case_names:
                lines.append(f"  - case: {case_name}")
                if (file_name, case_name) in blocked:
                    lines.append("    state: blocked")
            path = self.fixtures / file_name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def report(self, rows, version=VERSION):
        body = {"runtime": "java", "clientVersion": "9.1.0", "fixtureSetVersion": version, "counts": {}, "rows": rows}
        (self.reports / "conformance-report.json").write_text(json.dumps(body), encoding="utf-8")

    def declare(self, text):
        (self.declarations / "java-declared.yaml").write_text(text, encoding="utf-8")

    def collect(self):
        return cr.collect(self.reports, self.fixtures, self.declarations)

    def test_declared_unsupported_and_declared_fail_pass_the_gate(self) -> None:
        self.fixture_set([(FILE, CASE), (TLS_FILE, "cn-only-no-san")])
        self.report(
            [
                {"file": FILE, "case": CASE, "result": "unsupported", "reason": "no translator API"},
                {"file": TLS_FILE, "case": "cn-only-no-san", "result": "fail", "reason": "legacy CN fallback"},
            ]
        )
        self.declare(
            f"{FILE}:\n  {CASE}: {{ result: unsupported, reason: no translator API }}\n"
            f"{TLS_FILE}:\n  cn-only-no-san: {{ result: fail, reason: legacy CN fallback }}\n"
        )
        markdown, failed = self.collect()
        self.assertFalse(failed)
        self.assertIn("| java | 9.1.0 | 1.0.0 | 0 | 1 | 1 | 0 | ok |", markdown)
        self.assertIn("no translator API", markdown)

    def test_each_gate_rule_fails(self) -> None:
        cases = [(FILE, "broken"), (FILE, "unsupported"), (FILE, "blocked"), (FILE, "missing")]
        self.fixture_set(cases)
        self.report(
            [
                {"file": FILE, "case": "broken", "result": "fail"},
                {"file": FILE, "case": "unsupported", "result": "unsupported"},
                {"file": FILE, "case": "blocked", "result": "blocked"},
                {"file": FILE, "case": "renamed", "result": "pass"},
            ]
        )
        markdown, failed = self.collect()
        self.assertTrue(failed)
        for kind in ("pass-to-fail", "undeclared-unsupported", "undeclared-blocked", "unknown-case", "missing-row"):
            self.assertIn(f"| {kind} |", markdown)

    def test_empty_report_fails_for_every_case(self) -> None:
        self.fixture_set([(FILE, CASE), (TLS_FILE, "cn-only-no-san")])
        self.report([])
        markdown, failed = self.collect()
        self.assertTrue(failed)
        self.assertEqual(markdown.count("| missing-row |"), 2)

    def test_fixture_blocked_case_is_declared_blocked(self) -> None:
        self.fixture_set([(FILE, CASE)], blocked=[(FILE, CASE)])
        self.report([{"file": FILE, "case": CASE, "result": "blocked"}])
        self.assertFalse(self.collect()[1])

    def test_declaration_for_an_unknown_case_is_an_error(self) -> None:
        self.fixture_set([(FILE, CASE)])
        self.report([{"file": FILE, "case": CASE, "result": "pass"}])
        self.declare(f"{FILE}:\n  removed-case: {{ result: unsupported, reason: gone }}\n")
        with self.assertRaisesRegex(cr.CollectError, "removed-case is not a fixture case"):
            self.collect()

    def test_unreadable_inputs_are_errors(self) -> None:
        self.fixture_set([(FILE, CASE)])
        with self.assertRaisesRegex(cr.CollectError, "no conformance-report.json"):
            self.collect()
        self.report([{"file": FILE, "case": CASE, "result": "skip"}])
        with self.assertRaisesRegex(cr.CollectError, "invalid result skip"):
            self.collect()
        self.report([{"file": FILE, "case": CASE, "result": "pass"}], version="9.9.9")
        with self.assertRaisesRegex(cr.CollectError, "does not match fixtures VERSION 1.0.0"):
            self.collect()

    def test_files_that_are_not_fixtures_are_skipped(self) -> None:
        self.fixture_set([(FILE, CASE)])
        (self.fixtures / ".trunk").mkdir()
        (self.fixtures / ".trunk" / "trunk.yaml").write_text("version: 0.1\n", encoding="utf-8")
        (self.fixtures / "docs").mkdir()
        (self.fixtures / "docs" / "notes.yaml").write_text("title: not a fixture\n", encoding="utf-8")
        self.assertEqual(list(cr.load_fixtures(self.fixtures)[1]), [(FILE, CASE)])

    def test_main_writes_the_summary_and_the_gate(self) -> None:
        self.fixture_set([(FILE, CASE)])
        self.report([{"file": FILE, "case": CASE, "result": "pass"}])
        summary, output = self.work / "summary.md", self.work / "output.txt"
        env = {
            "REPORTS_DIRECTORY": str(self.reports),
            "FIXTURES_DIRECTORY": str(self.fixtures),
            "DECLARATIONS_DIRECTORY": "",
            "GITHUB_STEP_SUMMARY": str(summary),
            "GITHUB_OUTPUT": str(output),
        }
        with mock.patch.dict(os.environ, env):
            self.assertEqual(cr.main(), 0)
        self.assertIn("## Conformance", summary.read_text(encoding="utf-8"))
        self.assertIn("gate=success", output.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
