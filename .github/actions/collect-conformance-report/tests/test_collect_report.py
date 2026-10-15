"""Tests for conformance report aggregation."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "collect_report.py"

# Same shape as aerospike-client-java java-declared.yaml. Kept inline so the
# formatter does not rewrite the flow mappings the parser accepts.
JAVA_DECLARED = """\
# Expected Java result per conformance row. A row not listed here is declared pass (blocked when the
# fixture row is blocked). The conformance test fails when any row's actual result differs.
discovery/translate/port-map.yaml:
  host-port-key-hit: { result: unsupported, reason: "CLIENT-5641 not implemented" }
  host-port-key-null-tls-name: { result: unsupported, reason: "CLIENT-5641 not implemented" }
  host-port-key-other-port-misses: { result: unsupported, reason: "CLIENT-5641 not implemented" }
  node-name-key-hit: { result: unsupported, reason: "CLIENT-5641 not implemented" }
  node-name-key-any-advertised-address: { result: unsupported, reason: "CLIENT-5641 not implemented" }
  node-name-key-misses-other-node: { result: unsupported, reason: "CLIENT-5641 not implemented" }
  ipv6-host-port-key-hit: { result: unsupported, reason: "CLIENT-5641 not implemented" }
  standard-map-alternate-endpoint-first-node: { result: unsupported, reason: "CLIENT-5641 not implemented" }
  standard-map-alternate-endpoint-second-node: { result: unsupported, reason: "CLIENT-5641 not implemented" }
  standard-map-alternate-endpoint-strict: { result: unsupported, reason: "CLIENT-5641 not implemented" }

discovery/translate/on-miss.yaml:
  static-map-explicit-pass-through: { result: unsupported, reason: "CLIENT-5640 not implemented" }
  static-map-strict-hit-translates: { result: unsupported, reason: "CLIENT-5640 not implemented" }
  static-map-strict-miss-fails: { result: unsupported, reason: "CLIENT-5640 not implemented" }
  static-map-strict-empty-map-fails: { result: unsupported, reason: "CLIENT-5640 not implemented" }
  port-map-default-pass-through: { result: unsupported, reason: "CLIENT-5641 not implemented" }
  port-map-strict-miss-fails: { result: unsupported, reason: "CLIENT-5641 not implemented" }

tls/name-matching.yaml:
  cn-only-no-san:
    result: fail
    reason: "legacy CN fallback kept until the next major (decided 2026-10-06)"
  cn-equal-dns-name-differs:
    result: fail
    reason: "legacy CN fallback kept until the next major (decided 2026-10-06)"
  ip-id-only-as-dns-name:
    result: fail
    reason: "legacy CN fallback kept until the next major (decided 2026-10-06)"
  ci-server-certificate-shape:
    result: fail
    reason: "legacy CN fallback kept until the next major (decided 2026-10-06)"
"""


def load():
    spec = importlib.util.spec_from_file_location("collect_report", SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {SCRIPT}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["collect_report"] = mod
    spec.loader.exec_module(mod)
    return mod


cr = load()

FILE = "discovery/translate/port-map.yaml"
CASE = "host-port-key-hit"


def report(rows, counts=None, runtime="java", version="0.1.0"):
    if counts is None:
        counts = {"pass": 0, "fail": 0, "unsupported": 0, "blocked": 0}
        for row in rows:
            counts[row["result"]] += 1
    return {
        "runtime": runtime,
        "clientVersion": "9.1.0",
        "fixtureSetVersion": version,
        "counts": counts,
        "rows": rows,
    }


def write_report(directory: Path, body: dict, name="conformance-report.json") -> None:
    path = directory / name
    path.write_text(json.dumps(body), encoding="utf-8")


class CollectReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.work)

    def test_parses_the_java_declaration_file(self) -> None:
        parsed = cr.parse_declarations(JAVA_DECLARED)
        port_map = parsed["discovery/translate/port-map.yaml"]
        hit = port_map["host-port-key-hit"]
        self.assertEqual(hit["result"], "unsupported")
        self.assertEqual(hit["reason"], "CLIENT-5641 not implemented")
        tls_row = parsed["tls/name-matching.yaml"]["cn-only-no-san"]
        self.assertEqual(tls_row["result"], "fail")
        self.assertIn("legacy CN fallback", tls_row["reason"])
        self.assertNotIn("some-other-case", port_map)

    def test_declared_unsupported_does_not_fail(self) -> None:
        reports = self.work / "reports"
        declarations = self.work / "declarations"
        reports.mkdir()
        declarations.mkdir()
        row = {
            "file": FILE,
            "case": CASE,
            "result": "unsupported",
            "reason": "CLIENT-5641 not implemented",
        }
        write_report(reports, report([row]))
        declared = declarations / "java-declared.yaml"
        declared.write_text(
            'discovery/translate/port-map.yaml:\n'
            '  host-port-key-hit: { result: unsupported, reason: "CLIENT-5641 not implemented" }\n',
            encoding="utf-8",
        )
        result = cr.collect(reports, declarations)
        self.assertFalse(result["failed"])
        self.assertEqual(result["unsupported"][0]["reason"], "CLIENT-5641 not implemented")
        markdown = cr.render_markdown(result)
        self.assertIn("CLIENT-5641 not implemented", markdown)
        self.assertIn("| java |", markdown)

    def test_undeclared_unsupported_fails(self) -> None:
        reports = self.work / "reports"
        reports.mkdir()
        row = {
            "file": FILE,
            "case": CASE,
            "result": "unsupported",
            "reason": "no translator API",
        }
        write_report(reports, report([row]))
        result = cr.collect(reports, None)
        self.assertTrue(result["failed"])
        self.assertEqual(result["findings"][0]["kind"], "undeclared-unsupported")

    def test_pass_to_fail_fails_and_declared_fail_does_not(self) -> None:
        reports = self.work / "reports"
        declarations = self.work / "declarations"
        reports.mkdir()
        declarations.mkdir()
        rows = [
            {"file": FILE, "case": "now-broken", "result": "fail", "reason": "expected host, got other"},
            {
                "file": "tls/name-matching.yaml",
                "case": "cn-only-no-san",
                "result": "fail",
                "reason": "legacy CN fallback kept until the next major (decided 2026-10-06)",
            },
        ]
        write_report(reports, report(rows))
        declared = declarations / "java-declared.yaml"
        declared.write_text(
            "tls/name-matching.yaml:\n"
            "  cn-only-no-san:\n"
            "    result: fail\n"
            '    reason: "legacy CN fallback kept until the next major (decided 2026-10-06)"\n',
            encoding="utf-8",
        )
        result = cr.collect(reports, declarations)
        self.assertTrue(result["failed"])
        kinds = [item["kind"] for item in result["findings"]]
        self.assertEqual(kinds, ["pass-to-fail"])
        self.assertEqual(result["findings"][0]["case"], "now-broken")

    def test_blocked_without_a_declaration_does_not_fail(self) -> None:
        reports = self.work / "reports"
        reports.mkdir()
        row = {"file": FILE, "case": "fr-22", "result": "blocked", "reason": "TG-16"}
        write_report(reports, report([row]))
        result = cr.collect(reports, None)
        self.assertFalse(result["failed"])
        self.assertEqual(result["differences"], [])

    def test_count_mismatch_and_missing_reports_fail(self) -> None:
        reports = self.work / "reports"
        reports.mkdir()
        body = report(
            [{"file": FILE, "case": CASE, "result": "pass"}],
            counts={"pass": 2, "fail": 0, "unsupported": 0, "blocked": 0},
        )
        write_report(reports, body)
        with self.assertRaises(cr.CollectError) as caught:
            cr.collect(reports, None)
        self.assertIn("counts", str(caught.exception))

        empty = self.work / "empty"
        empty.mkdir()
        with self.assertRaises(cr.CollectError) as missing:
            cr.collect(empty, None)
        self.assertIn("no conformance-report.json", str(missing.exception))

    def test_fixture_versions_must_agree(self) -> None:
        reports = self.work / "reports"
        java = reports / "java"
        go = reports / "go"
        java.mkdir(parents=True)
        go.mkdir()
        row = {"file": FILE, "case": CASE, "result": "pass"}
        write_report(java, report([row], runtime="java", version="0.1.0"))
        write_report(go, report([row], runtime="go", version="0.2.0"))
        with self.assertRaises(cr.CollectError) as caught:
            cr.collect(reports, None, "0.1.0")
        self.assertIn("disagree", str(caught.exception))

    def test_main_writes_summary_and_returns_the_gate(self) -> None:
        reports = self.work / "reports"
        reports.mkdir()
        row = {"file": FILE, "case": CASE, "result": "pass"}
        write_report(reports, report([row]))
        summary = self.work / "summary.md"
        output = self.work / "output.txt"
        previous = os.environ.get("GITHUB_STEP_SUMMARY")
        previous_output = os.environ.get("GITHUB_OUTPUT")
        previous_reports = os.environ.get("REPORTS_DIRECTORY")
        previous_declarations = os.environ.get("DECLARATIONS_DIRECTORY")
        os.environ["REPORTS_DIRECTORY"] = str(reports)
        os.environ["DECLARATIONS_DIRECTORY"] = ""
        os.environ["GITHUB_STEP_SUMMARY"] = str(summary)
        os.environ["GITHUB_OUTPUT"] = str(output)
        try:
            code = cr.main()
        finally:
            self._restore("GITHUB_STEP_SUMMARY", previous)
            self._restore("GITHUB_OUTPUT", previous_output)
            self._restore("REPORTS_DIRECTORY", previous_reports)
            self._restore("DECLARATIONS_DIRECTORY", previous_declarations)
        self.assertEqual(code, 0)
        text = summary.read_text(encoding="utf-8")
        self.assertIn("## Conformance", text)
        self.assertIn("gate=success", output.read_text(encoding="utf-8"))

    def _restore(self, name: str, value: str | None) -> None:
        if value is None:
            os.environ.pop(name, None)
            return
        os.environ[name] = value


if __name__ == "__main__":
    unittest.main()
