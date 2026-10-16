"""Retag named Docker tags onto a caller-supplied tag."""

from __future__ import annotations

import importlib.util
import json
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


RECORD = {
    "artifacts": [
        {
            "package_type": "docker",
            "package_name": "aerospike-graph-service",
            "package_version": "3.3.2_20261007T212412Z",
            "build_name": "graph",
            "build_number": "12",
        },
        {
            "package_type": "docker",
            "package_name": "aerospike-graph-service",
            "package_version": "3.3.2",
        },
        {
            "package_type": "docker",
            "package_name": "aerospike-graph-service",
            "package_version": "3.3.2-4711-2",
        },
    ]
}

BUILD = {
    "buildInfo": {
        "properties": {
            "buildInfo.env.DOCKER_FLOATING_TAGS": "aerospike-graph-service:latest;aerospike-graph-service:latest-slim"
        }
    }
}

MANIFEST = b'{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}'


def catalog(*rows):
    return rows


def promotion_server(rows, build=BUILD, record=RECORD):
    calls = []

    def fake(method, path, headers=None, body=None):
        calls.append((method, path, body))
        if method != "GET":
            return 0, b"", ""
        if "/release_bundle/records/" in path:
            return 0, json.dumps(record).encode(), ""
        if path.startswith("/api/build/"):
            return 0, json.dumps(build).encode(), ""
        if path.startswith("/api/repositories"):
            return 0, json.dumps(list(rows)).encode(), ""
        if path.endswith("/manifests/3.3.2"):
            return 0, MANIFEST, ""
        return 1, b"", "404 not found"

    return calls, fake


class FromPromotionTest(unittest.TestCase):
    def setUp(self):
        self.real = mod.jf_curl

    def tearDown(self):
        mod.jf_curl = self.real

    def run_promotion(self, environment, rows, build=BUILD):
        calls, fake = promotion_server(rows, build=build)
        mod.jf_curl = fake
        mod.main(
            [
                "from-promotion",
                "--project",
                "connect",
                "--bundle-name",
                "aerospike-graph-service-container",
                "--version",
                "3.3.2-4711-2",
                "--environment",
                environment,
            ]
        )
        return calls

    def pointed(self, calls):
        return [path.rsplit("/", 1)[-1] for method, path, _body in calls if method == "PUT"]

    def test_dev_does_not_apply_latest(self):
        calls = self.run_promotion(
            "DEV",
            catalog({"key": "connect-docker-dev-local", "packageType": "Docker", "environments": ["DEV"]}),
        )
        self.assertEqual(self.pointed(calls), [])

    def test_test_does_not_apply_latest(self):
        calls = self.run_promotion(
            "TEST",
            catalog({"key": "connect-docker-test-local", "packageType": "Docker", "environments": ["TEST"]}),
        )
        self.assertEqual(self.pointed(calls), [])

    def test_stage_repo_points_latest_at_the_mutable_tag(self):
        calls = self.run_promotion(
            "STAGE",
            catalog(
                {"key": "connect-docker-dev-local", "packageType": "Docker", "environments": ["STAGE"]},
                {"key": "connect-docker-stage-local", "packageType": "Docker", "type": "local", "environments": ["STAGE"]},
                {"key": "connect-docker-stage-virtual", "packageType": "Docker", "type": "virtual", "environments": ["STAGE"]},
            ),
        )
        self.assertEqual(self.pointed(calls), ["latest", "latest-slim"])
        gets = [path for method, path, _body in calls if method == "GET" and "/manifests/" in path]
        self.assertTrue(all(path.endswith("/manifests/3.3.2") for path in gets))
        self.assertTrue(all("connect-docker-stage-local" in path for path in gets))
        self.assertFalse(any("3.3.2-4711-2" in path for _method, path, _body in calls if "/manifests/" in path))

    def test_production_points_latest_without_a_stage_key(self):
        calls = self.run_promotion(
            "PROD",
            catalog({"key": "connect-docker-prod-public-local", "packageType": "oci", "environments": ["PROD"]}),
        )
        self.assertEqual(self.pointed(calls), ["latest", "latest-slim"])

    def test_missing_property_skips_stage(self):
        calls = self.run_promotion(
            "STAGE",
            catalog({"key": "connect-docker-stage-local", "packageType": "Docker", "environments": ["STAGE"]}),
            build={"buildInfo": {"properties": {}}},
        )
        self.assertEqual(self.pointed(calls), [])
        self.assertFalse(any(path.startswith("/api/repositories") for _method, path, _body in calls))

    def test_latest_token_only_points_latest(self):
        calls = self.run_promotion(
            "PROD",
            catalog({"key": "connect-docker-prod-public-local", "packageType": "Docker", "environments": ["PROD"]}),
            build={"buildInfo": {"properties": {"buildInfo.env.DOCKER_FLOATING_TAGS": "aerospike-graph-service:latest"}}},
        )
        self.assertEqual(self.pointed(calls), ["latest"])


if __name__ == "__main__":
    unittest.main()
