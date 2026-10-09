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


class SelectTest(unittest.TestCase):
    def test_latest_and_latest_slim(self):
        done = run(
            "select",
            "--request",
            "latest",
            "--request",
            "latest-slim",
            "--tag",
            "3.3.1",
            "--tag",
            "3.3.2",
            "--tag",
            "3.3.2_20261007T212412Z",
            "--tag",
            "3.3.2-slim",
            "--tag",
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "--tag",
            "sha256__bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.splitlines(), ["set latest 3.3.2", "set latest-slim 3.3.2-slim"])

    def test_latest_falls_back_when_version_is_gone(self):
        done = run(
            "select",
            "--request",
            "latest",
            "--request",
            "latest-slim",
            "--tag",
            "3.3.1",
            "--tag",
            "3.3.2_20261007T212412Z",
            "--tag",
            "3.3.2-slim",
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.splitlines(), ["set latest 3.3.1", "set latest-slim 3.3.2-slim"])

    def test_older_version_does_not_move_latest(self):
        done = run("select", "--request", "latest", "--tag", "3.3.0", "--tag", "3.3.0_20261001T000000Z", "--tag", "3.3.2")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), "set latest 3.3.2")

    def test_slim_never_wins_latest(self):
        done = run(
            "select",
            "--request",
            "latest",
            "--request",
            "latest-slim",
            "--tag",
            "3.3.2-slim",
            "--tag",
            "3.3.2-slim_20261007T212412Z",
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.splitlines(), ["delete latest", "set latest-slim 3.3.2-slim"])

    def test_no_candidate_removes_the_floating_tag(self):
        done = run(
            "select",
            "--request",
            "latest",
            "--request",
            "latest-slim",
            "--tag",
            "3.3.2_20261007T212412Z",
            "--tag",
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.splitlines(), ["delete latest", "delete latest-slim"])

    def test_numeric_comparison(self):
        done = run("select", "--request", "latest", "--tag", "8.1.0.0", "--tag", "8.2.0.0")
        self.assertEqual(done.stdout.strip(), "set latest 8.2.0.0")
        done = run("select", "--request", "latest", "--tag", "3.9.0", "--tag", "3.10.0")
        self.assertEqual(done.stdout.strip(), "set latest 3.10.0")
        done = run("select", "--request", "latest-slim", "--tag", "3.9.0-slim", "--tag", "3.10.0-slim", "--tag", "3.11.0")
        self.assertEqual(done.stdout.strip(), "set latest-slim 3.10.0-slim")


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
    def test_points_latest_and_removes_latest_slim_without_a_candidate(self):
        calls = []

        def fake(method, path, headers=None, body=None):
            calls.append((method, path, body))
            if path.endswith("/tags/list"):
                return 0, json.dumps({"tags": ["3.3.1", "3.3.2", "3.3.2_20261007T212412Z", "latest"]}).encode(), ""
            if method == "GET" and path.endswith("/manifests/3.3.2"):
                return 0, b'{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}', ""
            if method == "DELETE" and path.endswith("/manifests/latest-slim"):
                return 8, b"", "404 Not Found"
            return 0, b"", ""

        mod.jf_curl = fake
        mod.retag(
            "connect",
            "aerospike-graph-service-container",
            "3.3.2",
            "connect-docker-prod-public-local",
            "aerospike-graph-service:latest;aerospike-graph-service:latest-slim",
        )
        methods = [(method, path.rsplit("/", 1)[-1], body) for method, path, body in calls]
        self.assertEqual(methods[0][0], "GET")
        self.assertEqual(methods[0][1], "list")
        self.assertEqual(methods[1][0], "GET")
        self.assertEqual(methods[1][1], "3.3.2")
        self.assertEqual(methods[2][0], "PUT")
        self.assertEqual(methods[2][1], "latest")
        self.assertEqual(methods[2][2], b'{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}')
        self.assertEqual(methods[3][0], "DELETE")
        self.assertEqual(methods[3][1], "latest-slim")


if __name__ == "__main__":
    unittest.main()
