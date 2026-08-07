"""Tests for slack_post.py."""
from __future__ import annotations

import importlib.util
import json
import sys
import unittest
import urllib.error
from io import BytesIO, StringIO
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "slack_post.py"


def load():
    spec = importlib.util.spec_from_file_location("slack_post", SCRIPT)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules["slack_post"] = mod
    spec.loader.exec_module(mod)
    return mod


sp = load()


class PostSlackTests(unittest.TestCase):
    _PAYLOAD = {"channel": "C1", "text": "hello"}
    _TOKEN = "xoxb-test-token"

    def test_post_dry_run(self) -> None:
        buf = StringIO()
        with mock.patch.object(sys, "stdout", buf):
            sp.post_to_slack(self._TOKEN, self._PAYLOAD, dry_run=True)
        self.assertEqual(json.loads(buf.getvalue().strip()), self._PAYLOAD)

    def test_post_api_error(self) -> None:
        response_data = json.dumps({"ok": False, "error": "channel_not_found"}).encode()

        class FakeResponse:
            def __init__(self, data: bytes) -> None:
                self._data = data

            def read(self) -> bytes:
                return self._data

            def __enter__(self) -> "FakeResponse":
                return self

            def __exit__(self, *args: object) -> None:
                return None

        with mock.patch.object(
            urllib.request, "urlopen", return_value=FakeResponse(response_data)
        ):
            with self.assertRaises(sp.SlackPostError):
                sp.post_to_slack(self._TOKEN, self._PAYLOAD)

    def test_post_http_error(self) -> None:
        err = urllib.error.HTTPError(
            "https://slack.com/api/chat.postMessage", 500, "err", {}, BytesIO(b"boom")
        )
        with mock.patch.object(urllib.request, "urlopen", side_effect=err):
            with self.assertRaises(sp.SlackPostError):
                sp.post_to_slack(self._TOKEN, self._PAYLOAD)

    def test_cmd_post_dry_run(self) -> None:
        b64 = __import__("base64").b64encode(json.dumps(self._PAYLOAD).encode()).decode()
        buf = StringIO()
        with mock.patch.object(sys, "stdout", buf):
            code = sp.main(["--bot-token", "xoxb-test", "--payload-b64", b64, "--dry-run"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(buf.getvalue().strip()), self._PAYLOAD)

    def test_cmd_post_dry_run_without_token(self) -> None:
        b64 = __import__("base64").b64encode(json.dumps(self._PAYLOAD).encode()).decode()
        buf = StringIO()
        with mock.patch.object(sys, "stdout", buf):
            code = sp.main(["--payload-b64", b64, "--dry-run"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(buf.getvalue().strip()), self._PAYLOAD)

    def test_cmd_post_missing_token_fails(self) -> None:
        b64 = __import__("base64").b64encode(json.dumps(self._PAYLOAD).encode()).decode()
        self.assertEqual(sp.main(["--payload-b64", b64]), 1)

    def test_cmd_post_empty_payload_fails(self) -> None:
        self.assertEqual(sp.main(["--bot-token", "xoxb-test", "--payload-b64", ""]), 1)


if __name__ == "__main__":
    unittest.main()
