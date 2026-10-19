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

# Same content as aerospike-client-java java-declared.yaml for fixture set 1.0.0.
# Kept inline so the repository formatters do not rewrite its quoting.
JAVA_DECLARED = """\
# Expected Java result per conformance row. A row not listed here is declared pass (blocked when the
# fixture row is blocked). The conformance test fails when any row's actual result differs.
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
TLS_FILE = "tls/name-matching.yaml"
LEGACY_CN = "legacy CN fallback kept until the next major (decided 2026-10-06)"
version_file = ROOT.parent / "fetch-conformance-fixtures" / "fixture-set-version"
version_text = version_file.read_text(encoding="utf-8")
FIXTURE_VERSION = version_text.strip()
OTHER_FIXTURE_VERSION = "9.9.9"


def report(rows, counts=None, runtime="java", version=None):
    if version is None:
        version = FIXTURE_VERSION
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


def write_fixtures(
    directory: Path,
    cases: list[tuple[str, str]],
    blocked: list[tuple[str, str]] | None = None,
) -> None:
    """Write a fixture set with VERSION and one fixture file per distinct file name."""
    if blocked is None:
        blocked = []
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "VERSION").write_text(f"{FIXTURE_VERSION}\n", encoding="utf-8")
    by_file: dict[str, list[str]] = {}
    for file_name, case_name in cases:
        by_file.setdefault(file_name, []).append(case_name)

    for file_name, case_names in by_file.items():
        if file_name.startswith("tls/"):
            kind = "tls"
        else:
            kind = "translate"

        lines = [f"kind: {kind}", "rows:"]
        for case_name in case_names:
            lines.append(f"  - case: {case_name}")
            lines.append("    because: test row")
            if (file_name, case_name) in blocked:
                lines.append("    state: blocked")
                lines.append("    blockedBy: TG-16")

        path = directory / file_name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")


class CollectReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.work)
        self.reports = self.work / "reports"
        self.reports.mkdir()
        self.fixtures = self.work / "fixtures"
        self.declarations = self.work / "declarations"
        self.declarations.mkdir()

    def test_parses_the_java_declaration_file(self) -> None:
        parsed = cr.parse_declarations(JAVA_DECLARED)
        tls_cases = parsed.files[TLS_FILE]
        self.assertEqual(len(tls_cases), 4)
        self.assertEqual(tls_cases["cn-only-no-san"].result, "fail")
        self.assertIn("legacy CN fallback", tls_cases["cn-only-no-san"].reason)
        self.assertNotIn(FILE, parsed.files)

    def test_declared_unsupported_does_not_fail(self) -> None:
        write_fixtures(self.fixtures, [(FILE, CASE)])
        row = {"file": FILE, "case": CASE, "result": "unsupported", "reason": "CLIENT-5641 not implemented"}
        write_report(self.reports, report([row]))
        declared = self.declarations / "java-declared.yaml"
        declared.write_text(
            "discovery/translate/port-map.yaml:\n"
            '  host-port-key-hit: { result: unsupported, reason: "CLIENT-5641 not implemented" }\n',
            encoding="utf-8",
        )
        result = cr.collect(self.reports, self.fixtures, self.declarations)
        self.assertFalse(result.failed)
        self.assertEqual(result.unsupported[0].reason, "CLIENT-5641 not implemented")
        markdown = cr.render_markdown(result)
        self.assertIn("CLIENT-5641 not implemented", markdown)
        self.assertIn("| java |", markdown)

    def test_undeclared_unsupported_fails(self) -> None:
        write_fixtures(self.fixtures, [(FILE, CASE)])
        row = {"file": FILE, "case": CASE, "result": "unsupported", "reason": "no translator API"}
        write_report(self.reports, report([row]))
        result = cr.collect(self.reports, self.fixtures)
        self.assertTrue(result.failed)
        self.assertEqual(result.findings[0].kind, "undeclared-unsupported")

    def test_pass_to_fail_fails_and_declared_fail_does_not(self) -> None:
        declared_fail_cases = [
            "cn-only-no-san",
            "cn-equal-dns-name-differs",
            "ip-id-only-as-dns-name",
            "ci-server-certificate-shape",
        ]
        fixture_cases = [(FILE, "now-broken")]
        rows = [{"file": FILE, "case": "now-broken", "result": "fail", "reason": "expected host, got other"}]
        for case_name in declared_fail_cases:
            fixture_cases.append((TLS_FILE, case_name))
            rows.append({"file": TLS_FILE, "case": case_name, "result": "fail", "reason": LEGACY_CN})
        write_fixtures(self.fixtures, fixture_cases)
        write_report(self.reports, report(rows))
        declared = self.declarations / "java-declared.yaml"
        declared.write_text(JAVA_DECLARED, encoding="utf-8")
        result = cr.collect(self.reports, self.fixtures, self.declarations)
        self.assertTrue(result.failed)
        kinds = [item.kind for item in result.findings]
        self.assertEqual(kinds, ["pass-to-fail"])
        self.assertEqual(result.findings[0].case, "now-broken")

    def test_blocked_fixture_case_without_a_declaration_does_not_fail(self) -> None:
        write_fixtures(self.fixtures, [(FILE, "fr-22")], blocked=[(FILE, "fr-22")])
        row = {"file": FILE, "case": "fr-22", "result": "blocked", "reason": "TG-16"}
        write_report(self.reports, report([row]))
        result = cr.collect(self.reports, self.fixtures)
        self.assertFalse(result.failed)
        self.assertEqual(result.differences, [])

    def test_blocked_result_on_a_case_the_fixture_does_not_block_fails(self) -> None:
        write_fixtures(self.fixtures, [(FILE, CASE)])
        row = {"file": FILE, "case": CASE, "result": "blocked", "reason": "skipped"}
        write_report(self.reports, report([row]))
        result = cr.collect(self.reports, self.fixtures)
        self.assertTrue(result.failed)
        self.assertEqual(result.findings[0].kind, "undeclared-blocked")

    def test_an_empty_report_fails_for_every_fixture_case(self) -> None:
        write_fixtures(self.fixtures, [(FILE, CASE), (TLS_FILE, "cn-only-no-san")])
        write_report(self.reports, report([]))
        result = cr.collect(self.reports, self.fixtures)
        self.assertTrue(result.failed)
        kinds = [item.kind for item in result.findings]
        self.assertEqual(kinds, ["missing-row", "missing-row"])

    def test_a_partial_report_fails_for_the_missing_case(self) -> None:
        write_fixtures(self.fixtures, [(FILE, CASE), (FILE, "node-name-key-hit")])
        row = {"file": FILE, "case": CASE, "result": "pass"}
        write_report(self.reports, report([row]))
        result = cr.collect(self.reports, self.fixtures)
        self.assertTrue(result.failed)
        self.assertEqual(len(result.findings), 1)
        self.assertEqual(result.findings[0].kind, "missing-row")
        self.assertEqual(result.findings[0].case, "node-name-key-hit")

    def test_a_row_that_is_not_a_fixture_case_fails(self) -> None:
        write_fixtures(self.fixtures, [(FILE, CASE)])
        rows = [
            {"file": FILE, "case": CASE, "result": "pass"},
            {"file": FILE, "case": "renamed-case", "result": "pass"},
        ]
        write_report(self.reports, report(rows))
        result = cr.collect(self.reports, self.fixtures)
        self.assertTrue(result.failed)
        self.assertEqual(result.findings[0].kind, "unknown-case")
        self.assertEqual(result.findings[0].case, "renamed-case")

    def test_a_declaration_for_an_unknown_case_or_file_fails(self) -> None:
        write_fixtures(self.fixtures, [(FILE, CASE)])
        row = {"file": FILE, "case": CASE, "result": "pass"}
        write_report(self.reports, report([row]))
        declared = self.declarations / "java-declared.yaml"

        declared.write_text(
            "discovery/translate/port-map.yaml:\n"
            '  endpoint-port-map-strict-miss-fails: { result: unsupported, reason: "removed case" }\n',
            encoding="utf-8",
        )
        with self.assertRaises(cr.CollectError) as unknown_case:
            cr.collect(self.reports, self.fixtures, self.declarations)
        self.assertIn("endpoint-port-map-strict-miss-fails: unknown case", str(unknown_case.exception))

        declared.write_text(
            "discovery/translate/endpoint-port-map.yaml:\n"
            '  host-port-key-hit: { result: unsupported, reason: "removed file" }\n',
            encoding="utf-8",
        )
        with self.assertRaises(cr.CollectError) as unknown_file:
            cr.collect(self.reports, self.fixtures, self.declarations)
        self.assertIn("unknown fixture file discovery/translate/endpoint-port-map.yaml", str(unknown_file.exception))

    def test_fixture_loader_skips_files_that_are_not_fixtures(self) -> None:
        write_fixtures(self.fixtures, [(FILE, CASE)])
        trunk = self.fixtures / ".trunk" / "trunk.yaml"
        trunk.parent.mkdir()
        trunk.write_text("version: 0.1\n", encoding="utf-8")
        notes = self.fixtures / "docs" / "notes.yaml"
        notes.parent.mkdir()
        notes.write_text("title: not a fixture\n", encoding="utf-8")
        fixtures = cr.load_fixtures(self.fixtures)
        self.assertEqual(fixtures.version, FIXTURE_VERSION)
        self.assertEqual(list(fixtures.cases), [(FILE, CASE)])

    def test_count_mismatch_and_missing_reports_fail(self) -> None:
        write_fixtures(self.fixtures, [(FILE, CASE)])
        body = report(
            [{"file": FILE, "case": CASE, "result": "pass"}],
            counts={"pass": 2, "fail": 0, "unsupported": 0, "blocked": 0},
        )
        write_report(self.reports, body)
        with self.assertRaises(cr.CollectError) as caught:
            cr.collect(self.reports, self.fixtures)
        self.assertIn("counts", str(caught.exception))

        empty = self.work / "empty"
        empty.mkdir()
        with self.assertRaises(cr.CollectError) as missing:
            cr.collect(empty, self.fixtures)
        self.assertIn("no conformance-report.json", str(missing.exception))

    def test_report_version_must_match_the_fixtures(self) -> None:
        write_fixtures(self.fixtures, [(FILE, CASE)])
        row = {"file": FILE, "case": CASE, "result": "pass"}
        write_report(self.reports, report([row], version=OTHER_FIXTURE_VERSION))
        with self.assertRaises(cr.CollectError) as caught:
            cr.collect(self.reports, self.fixtures)
        self.assertIn(f"does not match fixtures VERSION {FIXTURE_VERSION}", str(caught.exception))

    def test_main_writes_summary_and_returns_the_gate(self) -> None:
        write_fixtures(self.fixtures, [(FILE, CASE)])
        row = {"file": FILE, "case": CASE, "result": "pass"}
        write_report(self.reports, report([row]))
        summary = self.work / "summary.md"
        output = self.work / "output.txt"
        names = [
            "GITHUB_STEP_SUMMARY",
            "GITHUB_OUTPUT",
            "REPORTS_DIRECTORY",
            "FIXTURES_DIRECTORY",
            "DECLARATIONS_DIRECTORY",
        ]
        previous = {}
        for name in names:
            previous[name] = os.environ.get(name)
        os.environ["REPORTS_DIRECTORY"] = str(self.reports)
        os.environ["FIXTURES_DIRECTORY"] = str(self.fixtures)
        os.environ["DECLARATIONS_DIRECTORY"] = ""
        os.environ["GITHUB_STEP_SUMMARY"] = str(summary)
        os.environ["GITHUB_OUTPUT"] = str(output)
        try:
            code = cr.main()
        finally:
            for name in names:
                self._restore(name, previous[name])
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
