"""Tests for build_slack_failure_child_blocks.py."""
from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from io import StringIO
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "build_slack_failure_child_blocks.py"


def load():
    spec = importlib.util.spec_from_file_location("build_slack_failure_child_blocks", SCRIPT)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules["build_slack_failure_child_blocks"] = mod
    spec.loader.exec_module(mod)
    return mod


mod = load()


class BuildSlackFailureChildBlocksTests(unittest.TestCase):
    def test_format_failed_summary_with_steps(self) -> None:
        summary = mod.format_failed_summary(
            "create-release-bundle / create-release-bundle",
            ["Create Release Bundle"],
            max_chars=1500,
        )
        self.assertEqual(summary, "*create-release-bundle / create-release-bundle* — `Create Release Bundle`")

    def test_format_failed_summary_without_steps(self) -> None:
        summary = mod.format_failed_summary("create-release-bundle", [], max_chars=1500)
        self.assertEqual(summary, "*create-release-bundle* failed")

    def test_build_child_blocks_structure(self) -> None:
        blocks = mod.build_child_blocks(
            run_url="https://github.com/my-org/my-app/actions/runs/123",
            failed_summary="*job* — `step`",
            caller="*Repository*\n`my-org/my-app`",
            called="*Workflow*\n`reusable_create-release-bundle.yaml`",
        )
        self.assertEqual(len(blocks), 3)
        self.assertIn("Failed jobs/steps", blocks[0]["text"]["text"])
        self.assertIn("View workflow run", blocks[2]["text"]["text"])

    def test_main_writes_json(self) -> None:
        buf = StringIO()
        with mock.patch.dict(
            "os.environ",
            {
                "GITHUB_REPOSITORY": "my-org/my-app",
                "GITHUB_RUN_ID": "123",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_WORKFLOW": "Release CI",
                "GITHUB_JOB": "create-release-bundle",
                "GITHUB_REF_NAME": "main",
                "GITHUB_SHA": "abc1234567890",
            },
            clear=False,
        ):
            with mock.patch.object(sys, "stdout", buf):
                code = mod.main(
                    [
                        "--repository",
                        "my-org/my-app",
                        "--run-id",
                        "123",
                        "--job-name",
                        "create-release-bundle / create-release-bundle",
                        "--failed-step",
                        "Create Release Bundle",
                        "--called-workflow-ref",
                        "deadbeef",
                        "--bundle-name",
                        "database-release",
                        "--bundle-version",
                        "7.2.0.1",
                        "--print-json",
                    ]
                )
        self.assertEqual(code, 0)
        payload = json.loads(buf.getvalue().strip())
        self.assertIn("Create Release Bundle", payload[0]["text"]["text"])
        self.assertIn("database-release", payload[1]["fields"][1]["text"])


if __name__ == "__main__":
    unittest.main()
