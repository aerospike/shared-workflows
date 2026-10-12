#!/usr/bin/env python3
"""Unit tests for verify_cli_age.py.

Run: python3 -m unittest discover -s .github/actions/snyk-container-scan/tests

A fixed --now makes the bake arithmetic deterministic, so these run with no network and no
GitHub API. They cover: old enough passes (0), too new is refused (2), a missing publish time
is unknown (3), and the JSON-on-stdin path the install step actually uses.
"""
import importlib.util
import io
import pathlib
import sys
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "verify_cli_age.py"
spec = importlib.util.spec_from_file_location("verify_cli_age", SCRIPT)
verify = importlib.util.module_from_spec(spec)
sys.modules["verify_cli_age"] = verify
spec.loader.exec_module(verify)

NOW = "2026-01-10T00:00:00Z"


class AgeMath(unittest.TestCase):
    def test_age_hours_floors(self):
        self.assertEqual(verify.age_hours("2026-01-09T00:30:00Z", verify.parse_iso(NOW)), 23)

    def test_parse_iso_accepts_z_and_offset(self):
        self.assertEqual(verify.parse_iso("2026-01-01T00:00:00Z"),
                         verify.parse_iso("2026-01-01T00:00:00+00:00"))

    def test_published_from_json(self):
        self.assertEqual(verify.published_from_json('{"published_at":"2026-01-01T00:00:00Z"}'),
                         "2026-01-01T00:00:00Z")
        self.assertEqual(verify.published_from_json("not json"), "")
        self.assertEqual(verify.published_from_json("[]"), "")


class ExitCodes(unittest.TestCase):
    def test_old_enough_returns_0(self):
        # published 3 days before NOW, min 48h -> pass
        rc = verify.main(["--published-at", "2026-01-07T00:00:00Z", "--now", NOW, "--min-age-hours", "48"])
        self.assertEqual(rc, 0)

    def test_too_new_returns_2(self):
        # published 10h before NOW, min 48h -> refuse
        rc = verify.main(["--published-at", "2026-01-09T14:00:00Z", "--now", NOW, "--min-age-hours", "48"])
        self.assertEqual(rc, 2)

    def test_exactly_at_threshold_passes(self):
        rc = verify.main(["--published-at", "2026-01-08T00:00:00Z", "--now", NOW, "--min-age-hours", "48"])
        self.assertEqual(rc, 0)

    def test_missing_publish_time_returns_3(self):
        stdin = sys.stdin
        try:
            sys.stdin = io.StringIO("")  # empty body, as when the API call failed
            rc = verify.main(["--now", NOW])
        finally:
            sys.stdin = stdin
        self.assertEqual(rc, 3)

    def test_reads_publish_time_from_stdin_json(self):
        stdin = sys.stdin
        try:
            sys.stdin = io.StringIO('{"published_at":"2026-01-01T00:00:00Z"}')
            rc = verify.main(["--now", NOW, "--min-age-hours", "48"])
        finally:
            sys.stdin = stdin
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
