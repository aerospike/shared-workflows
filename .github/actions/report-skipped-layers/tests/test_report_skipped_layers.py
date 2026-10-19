"""Tests for the skipped-layer report."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "report_skipped_layers.py"


def load():
    spec = importlib.util.spec_from_file_location("report_skipped_layers", SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {SCRIPT}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["report_skipped_layers"] = mod
    spec.loader.exec_module(mod)
    return mod


rsl = load()

L2_EE = {
    "layer": "L2 EE",
    "tests": "N-6, N-14, multi-node cluster",
    "reason": "Enterprise feature key secret is absent",
}
L3 = {
    "layer": "L3",
    "tests": "K suite (K-1 to K-6)",
    "reason": "AKO image pull and JFrog OIDC are not available to fork PRs; feature key secret is absent",
}


def run_main(layers_text: str) -> tuple[int, str, str, str, str]:
    """Run main() with the action's environment and return code, stdout, stderr, summary, output."""
    with tempfile.TemporaryDirectory() as tmp:
        summary_path = Path(tmp) / "summary.md"
        output_path = Path(tmp) / "output"
        summary_path.touch()
        output_path.touch()
        env = {
            "SKIPPED_LAYERS": layers_text,
            "GITHUB_STEP_SUMMARY": str(summary_path),
            "GITHUB_OUTPUT": str(output_path),
        }
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, env), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = rsl.main()
        summary = summary_path.read_text(encoding="utf-8")
        output = output_path.read_text(encoding="utf-8")
    return code, stdout.getvalue(), stderr.getvalue(), summary, output


class ParseLayersTest(unittest.TestCase):
    def test_one_row(self):
        text = json.dumps([L2_EE])
        layers = rsl.parse_layers(text)
        expected = rsl.SkippedLayer("L2 EE", L2_EE["tests"], L2_EE["reason"])
        self.assertEqual(layers, [expected])

    def test_several_rows_keep_order(self):
        text = json.dumps([L2_EE, L3])
        layers = rsl.parse_layers(text)
        names = [item.layer for item in layers]
        self.assertEqual(names, ["L2 EE", "L3"])

    def test_empty_array(self):
        layers = rsl.parse_layers("[]")
        self.assertEqual(layers, [])

    def test_tests_and_reason_preserved_exactly(self):
        row = {"layer": " L3 ", "tests": "K-1,K-2 (kind)  ", "reason": "  AKO: image pull 100% denied"}
        text = json.dumps([row])
        layers = rsl.parse_layers(text)
        self.assertEqual(layers[0].layer, " L3 ")
        self.assertEqual(layers[0].tests, "K-1,K-2 (kind)  ")
        self.assertEqual(layers[0].reason, "  AKO: image pull 100% denied")

    def test_missing_field(self):
        for field in rsl.FIELDS:
            row = dict(L2_EE)
            del row[field]
            text = json.dumps([row])
            with self.subTest(field=field):
                with self.assertRaisesRegex(rsl.ReportError, rf"layers\[0\]: missing {field}"):
                    rsl.parse_layers(text)

    def test_empty_field(self):
        row = dict(L2_EE, reason="   ")
        text = json.dumps([row])
        with self.assertRaisesRegex(rsl.ReportError, r"layers\[0\]\.reason must be a non-empty string"):
            rsl.parse_layers(text)

    def test_non_string_field(self):
        row = dict(L2_EE, tests=["N-6", "N-14"])
        text = json.dumps([row])
        with self.assertRaisesRegex(rsl.ReportError, r"layers\[0\]\.tests must be a non-empty string"):
            rsl.parse_layers(text)

    def test_unknown_field(self):
        row = dict(L2_EE, reasons="typo")
        text = json.dumps([row])
        with self.assertRaisesRegex(rsl.ReportError, r"layers\[0\]: unknown field reasons"):
            rsl.parse_layers(text)

    def test_row_not_an_object(self):
        with self.assertRaisesRegex(rsl.ReportError, r"layers\[1\] must be an object"):
            rsl.parse_layers('[{"layer": "L3", "tests": "K", "reason": "r"}, "L3"]')

    def test_invalid_json(self):
        with self.assertRaisesRegex(rsl.ReportError, "layers is not valid JSON"):
            rsl.parse_layers('[{"layer": "L3",')

    def test_non_array(self):
        text = json.dumps(L2_EE)
        with self.assertRaisesRegex(rsl.ReportError, "layers must be a JSON array"):
            rsl.parse_layers(text)

    def test_empty_input(self):
        with self.assertRaisesRegex(rsl.ReportError, r"layers is required; pass \[\]"):
            rsl.parse_layers("  \n")


class RenderTest(unittest.TestCase):
    def test_table_names_layer_tests_and_reason(self):
        layers = [rsl.SkippedLayer(**L2_EE), rsl.SkippedLayer(**L3)]
        markdown = rsl.render_markdown(layers)
        self.assertIn("## Skipped layers", markdown)
        self.assertIn("| Layer | Tests not run | Reason |", markdown)
        self.assertIn(f"| L2 EE | {L2_EE['tests']} | {L2_EE['reason']} |", markdown)
        self.assertIn(f"| L3 | {L3['tests']} | {L3['reason']} |", markdown)

    def test_empty_says_nothing_skipped(self):
        markdown = rsl.render_markdown([])
        self.assertEqual(markdown, "## Skipped layers\n\nNo secret-gated layers skipped.\n")

    def test_cell_escapes_pipe_and_newline(self):
        layers = [rsl.SkippedLayer("L3", "K-1 | K-2", "no AKO image\nno OIDC")]
        markdown = rsl.render_markdown(layers)
        self.assertIn("| L3 | K-1 \\| K-2 | no AKO image no OIDC |", markdown)

    def test_notice_per_row(self):
        layers = [rsl.SkippedLayer(**L2_EE), rsl.SkippedLayer(**L3)]
        notices = rsl.render_notices(layers)
        self.assertEqual(
            notices,
            [
                f"::notice title=Skipped layer L2 EE::{L2_EE['tests']} did not run: {L2_EE['reason']}",
                f"::notice title=Skipped layer L3::{L3['tests']} did not run: {L3['reason']}",
            ],
        )

    def test_notice_escapes_workflow_command_characters(self):
        layers = [rsl.SkippedLayer("L2: EE, N", "N-6", "100% absent\nsee docs")]
        notices = rsl.render_notices(layers)
        self.assertEqual(notices, ["::notice title=Skipped layer L2%3A EE%2C N::N-6 did not run: 100%25 absent%0Asee docs"])

    def test_no_notice_when_nothing_skipped(self):
        notices = rsl.render_notices([])
        self.assertEqual(notices, [])


class MainTest(unittest.TestCase):
    def test_one_row_writes_summary_stdout_notice_and_count(self):
        text = json.dumps([L2_EE])
        code, stdout, stderr, summary, output = run_main(text)
        self.assertEqual(code, 0)
        self.assertEqual(stderr, "")
        self.assertIn(f"| L2 EE | {L2_EE['tests']} | {L2_EE['reason']} |", summary)
        printed_summary = stdout[: len(summary)]
        self.assertEqual(printed_summary, summary)
        self.assertIn("::notice title=Skipped layer L2 EE::", stdout)
        self.assertNotIn("::warning", stdout)
        self.assertNotIn("::error", stdout)
        self.assertEqual(output, "skipped-count=1\n")

    def test_several_rows_count(self):
        text = json.dumps([L2_EE, L3])
        code, stdout, _, summary, output = run_main(text)
        self.assertEqual(code, 0)
        notice_count = stdout.count("::notice ")
        self.assertEqual(notice_count, 2)
        self.assertIn("| L3 |", summary)
        self.assertEqual(output, "skipped-count=2\n")

    def test_empty_array_stays_green(self):
        code, stdout, _, summary, output = run_main("[]")
        self.assertEqual(code, 0)
        self.assertIn("No secret-gated layers skipped.", summary)
        self.assertNotIn("::notice", stdout)
        self.assertEqual(output, "skipped-count=0\n")

    def test_invalid_input_fails_without_summary_or_count(self):
        for text in ('{"layer": "L3"}', "not json", '[{"layer": "L3", "tests": "K"}]', ""):
            with self.subTest(text=text):
                code, stdout, stderr, summary, output = run_main(text)
                self.assertEqual(code, 1)
                self.assertRegex(stderr, "^Error: ")
                self.assertEqual(stdout, "")
                self.assertEqual(summary, "")
                self.assertEqual(output, "")

    def test_without_step_summary_prints_only(self):
        text = json.dumps([L3])
        stdout = io.StringIO()
        env = {"SKIPPED_LAYERS": text}
        with mock.patch.dict(os.environ, env, clear=True), contextlib.redirect_stdout(stdout):
            code = rsl.main()
        printed = stdout.getvalue()
        self.assertEqual(code, 0)
        self.assertIn(f"| L3 | {L3['tests']} | {L3['reason']} |", printed)


if __name__ == "__main__":
    unittest.main()
