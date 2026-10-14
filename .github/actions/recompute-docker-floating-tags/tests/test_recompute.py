"""Retag named Docker tags onto a caller-supplied tag."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "recompute.py"


def load():
    spec = importlib.util.spec_from_file_location("recompute_floating_tags", SCRIPT)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mod = load()


def run(*args, stdin=""):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        input=stdin,
        text=True,
        capture_output=True,
        check=False,
    )


class RetagTest(unittest.TestCase):
    def test_default_retag_attaches_nothing(self):
        done = run("retag", "--repo", "connect-docker-stage-local")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("Attaching nothing.", done.stdout)

    def test_image_is_required_for_latest(self):
        done = run(
            "retag",
            "--repo",
            "connect-docker-stage-local",
            "--tag",
            "3.3.2",
            "--latest",
        )
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("--image is required", done.stderr)

    def test_tag_is_required_when_a_name_is_applied(self):
        done = run(
            "retag",
            "--repo",
            "connect-docker-stage-local",
            "--image",
            "aerospike-graph-service",
            "--latest",
        )
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("--tag is required", done.stderr)

    def test_latest_suffix_flag_is_rejected(self):
        done = run("retag", "--repo", "connect-docker-stage-local", "--latest-debug")
        self.assertNotEqual(done.returncode, 0)

    def test_flags_point_at_the_supplied_tag(self):
        calls = []

        def fake(method, path, headers=None, body=None):
            calls.append((method, path, body))
            if method == "GET" and path.endswith("/manifests/3.3.2"):
                return 0, b'{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}', ""
            return 0, b"", ""

        mod.jf_curl = fake
        mod.main(
            [
                "retag",
                "--repo",
                "connect-docker-prod-public-local",
                "--tag",
                "3.3.2",
                "--image",
                "aerospike-graph-service",
                "--latest",
                "--latest-slim",
            ]
        )
        methods = [(method, path.rsplit("/", 1)[-1], body) for method, path, body in calls]
        self.assertEqual([item[0] for item in methods], ["GET", "PUT", "GET", "PUT"])
        self.assertEqual(methods[0][1], "3.3.2")
        self.assertEqual(methods[1][1], "latest")
        self.assertEqual(methods[1][2], b'{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}')
        self.assertEqual(methods[2][1], "3.3.2")
        self.assertEqual(methods[3][1], "latest-slim")
        self.assertFalse(any(path.endswith("/tags/list") for _method, path, _body in calls))


if __name__ == "__main__":
    unittest.main()
