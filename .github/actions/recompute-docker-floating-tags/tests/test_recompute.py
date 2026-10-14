"""Selection, repository discovery, and the docker.floating_tags property."""

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


class MutableVersionTest(unittest.TestCase):
    def test_timestamp_is_stripped(self):
        self.assertEqual(mod.mutable_version("3.3.2_20261007T212412Z"), "3.3.2")
        self.assertEqual(mod.mutable_version("3.3.2-slim_20261007T212412Z"), "3.3.2-slim")

    def test_plain_version_is_unchanged(self):
        self.assertEqual(mod.mutable_version("3.3.2"), "3.3.2")
        self.assertEqual(mod.mutable_version("3.3.2-slim"), "3.3.2-slim")


class RepoTest(unittest.TestCase):
    def test_mapping_target_is_used_unchanged(self):
        done = run(
            "repos",
            "--environment",
            "PROD",
            "--version",
            "3.3.2",
            stdin=json.dumps(
                {
                    "repository_mapping": [
                        {
                            "source_repository_key": "connect-deb-dev-local",
                            "target_repository_key": "connect-deb-prod-local",
                        },
                        {
                            "source_repository_key": "connect-docker-dev-local",
                            "target_repository_key": "connect-docker-prod-public-local",
                        },
                    ]
                }
            ),
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), "connect-docker-prod-public-local")

    def test_promotions_are_filtered(self):
        done = run(
            "repos",
            "--environment",
            "STAGE",
            "--version",
            "3.3.2",
            stdin=json.dumps(
                {
                    "promotions": [
                        {
                            "environment": "DEV",
                            "status": "COMPLETED",
                            "release_bundle_version": "3.3.2",
                            "repository_mapping": [
                                {
                                    "source_repository_key": "connect-docker-dev-local",
                                    "target_repository_key": "connect-docker-dev-local",
                                }
                            ],
                        },
                        {
                            "environment": "STAGE",
                            "status": "COMPLETED",
                            "release_bundle_version": "3.3.2",
                            "repository_mapping": [
                                {
                                    "source_repository_key": "connect-docker-dev-local",
                                    "target_repository_key": "connect-docker-stage-local",
                                },
                                {
                                    "source_repository_key": "connect-oci-dev-local",
                                    "target_repository_key": "connect-oci-stage-local",
                                },
                            ],
                        },
                    ]
                }
            ),
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.splitlines(), ["connect-docker-stage-local", "connect-oci-stage-local"])

    def test_catalog_uses_the_environment_assignment(self):
        done = run(
            "repos",
            "--environment",
            "PROD",
            "--version",
            "3.3.2",
            stdin=json.dumps(
                [
                    {"key": "connect-docker-dev-local", "packageType": "Docker", "type": "LOCAL", "environments": ["DEV"]},
                    {"key": "connect-deb-prod-public-local", "packageType": "Debian", "type": "LOCAL", "environments": ["PROD"]},
                    {"key": "connect-docker-prod-public", "packageType": "Docker", "type": "VIRTUAL", "environments": ["PROD"]},
                    {"key": "connect-docker-prod-public-local", "packageType": "Docker", "type": "LOCAL", "environments": ["PROD"]},
                ]
            ),
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), "connect-docker-prod-public-local")


class PropertyTest(unittest.TestCase):
    def test_array_object_and_storage_forms(self):
        samples = [
            {"properties": [{"key": "docker.floating_tags", "values": ["aerospike-graph-service:latest;aerospike-graph-service:latest-slim"]}]},
            {"properties": {"docker.floating_tags": "aerospike-graph-service:latest"}},
            {"properties": {"docker.floating_tags": ["aerospike-graph-service:latest;aerospike-graph-service:latest-slim"]}},
        ]
        expected = [
            "aerospike-graph-service:latest;aerospike-graph-service:latest-slim",
            "aerospike-graph-service:latest",
            "aerospike-graph-service:latest;aerospike-graph-service:latest-slim",
        ]
        for doc, want in zip(samples, expected):
            done = run("property", stdin=json.dumps(doc))
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(done.stdout.strip(), want)

    def test_missing_property_prints_nothing(self):
        done = run("property", stdin=json.dumps({"properties": [{"key": "is_multi_package", "values": ["true"]}]}))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout, "")


class RetagTest(unittest.TestCase):
    def test_default_retag_attaches_nothing(self):
        done = run(
            "retag",
            "--project",
            "connect",
            "--repo",
            "connect-docker-stage-local",
            "--bundle-name",
            "aerospike-graph-service-container",
            "--version",
            "3.3.2",
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("Attaching nothing.", done.stdout)

    def test_latest_suffix_flag_is_rejected(self):
        done = run(
            "retag",
            "--project",
            "connect",
            "--repo",
            "connect-docker-stage-local",
            "--bundle-name",
            "aerospike-graph-service-container",
            "--version",
            "3.3.2",
            "--latest-debug",
        )
        self.assertNotEqual(done.returncode, 0)

    def test_flags_point_at_this_mutable_version(self):
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
                "--project",
                "connect",
                "--repo",
                "connect-docker-prod-public-local",
                "--bundle-name",
                "aerospike-graph-service-container",
                "--version",
                "3.3.2_20261007T212412Z",
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
