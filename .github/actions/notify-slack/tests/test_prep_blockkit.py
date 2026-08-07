"""Tests for prep_blockkit.py."""
from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "prep_blockkit.py"


def load():
    spec = importlib.util.spec_from_file_location("prep_blockkit", SCRIPT)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules["prep_blockkit"] = mod
    spec.loader.exec_module(mod)
    return mod


pb = load()

SAMPLE_CHILD_BLOCKS = [
    {
        "type": "section",
        "block_id": "metadata",
        "fields": [
            {"type": "mrkdwn", "text": "*Repository*\n`my-repo`"},
            {"type": "mrkdwn", "text": "*Failed job*\n`build`"},
        ],
    },
    {
        "type": "section",
        "block_id": "workflow_link",
        "text": {"type": "mrkdwn", "text": "<https://example.com/run/1|View workflow>"},
    },
]


class PrepBlockkitTests(unittest.TestCase):
    def test_fail_template_renders_container_with_child_blocks(self) -> None:
        payload = pb.build_payload(
            message_type="fail",
            title="Build failed",
            subtitle="my-app@v1.0.0",
            channel_id="C123456789",
            fallback_text="Build failed: my-app@v1.0.0",
            child_blocks=SAMPLE_CHILD_BLOCKS,
        )
        self.assertEqual(payload["channel"], "C123456789")
        self.assertIn("Build failed", payload["text"])
        container = payload["blocks"][0]
        self.assertEqual(container["type"], "container")
        self.assertEqual(container["block_id"], "alert_fail")
        self.assertEqual(container["title"]["text"], "Build failed")
        child_text = json.dumps(container["child_blocks"])
        self.assertIn("my-repo", child_text)
        self.assertIn("https://example.com/run/1", child_text)

    def test_info_template(self) -> None:
        payload = pb.build_payload(
            message_type="info",
            title="Processed",
            subtitle="my-bundle@1.0.0",
            channel_id="C1",
        )
        container = payload["blocks"][0]
        self.assertEqual(container["block_id"], "alert_info")
        self.assertFalse(container["is_collapsible"])
        self.assertNotIn("default_collapsed", container)

    def test_success_template(self) -> None:
        payload = pb.build_payload(
            message_type="success",
            title="Publish succeeded",
            subtitle="my-bundle@1.0.0",
            channel_id="C1",
            child_blocks=[
                {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": "• *PyPI:* <https://pypi.org/project/x|PyPI>",
                    },
                }
            ],
        )
        self.assertEqual(payload["blocks"][0]["block_id"], "alert_success")
        self.assertIn("https://pypi.org/project/x", json.dumps(payload))

    def test_warning_template_is_collapsible(self) -> None:
        payload = pb.build_payload(
            message_type="warning",
            title="Still running",
            subtitle=">15 min",
            channel_id="C1",
        )
        container = payload["blocks"][0]
        self.assertEqual(container["block_id"], "alert_warning")
        self.assertTrue(container["is_collapsible"])
        self.assertFalse(container["default_collapsed"])

    def test_blocked_template(self) -> None:
        payload = pb.build_payload(
            message_type="blocked",
            title="Publish blocked",
            subtitle="my-repo",
            channel_id="C1",
        )
        container = payload["blocks"][0]
        self.assertEqual(container["block_id"], "alert_blocked")
        self.assertEqual(
            container["icon"]["image_url"],
            "https://a.slack-edge.com/production-standard-emoji-assets/10.2/google-medium/1f6d1@2x.png",
        )

    def test_default_fallback_text(self) -> None:
        payload = pb.build_payload(
            message_type="info",
            title="Title",
            subtitle="Subtitle",
            channel_id="C1",
        )
        self.assertEqual(payload["text"], "Title: Subtitle")

    def test_unsupported_message_type(self) -> None:
        with self.assertRaises(ValueError):
            pb.build_payload(
                message_type="unknown",
                title="Title",
                subtitle="Subtitle",
                channel_id="C1",
            )

    def test_invalid_child_blocks(self) -> None:
        with self.assertRaises(ValueError):
            pb.parse_child_blocks('{"type":"section"}')

    def test_empty_channel_skips_via_cli(self) -> None:
        code = pb.main(["--message-type", "fail", "--title", "x", "--subtitle", "y"])
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
