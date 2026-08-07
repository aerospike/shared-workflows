#!/usr/bin/env python3
"""Post a prepared payload to Slack via chat.postMessage."""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any

_SLACK_API = "https://slack.com/api/chat.postMessage"


class SlackPostError(RuntimeError):
    pass


def _env_str(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _is_dry_run(args: argparse.Namespace) -> bool:
    if args.dry_run:
        return True
    return _env_str("DRY_RUN").lower() == "true"


def _slack_api_error_message(body: dict[str, Any]) -> str:
    error = body.get("error", "unknown")
    return f"Slack API error: {error}"


def post_to_slack(bot_token: str, payload: dict[str, Any], *, dry_run: bool = False) -> None:
    text = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    if dry_run:
        print(text)
        return
    req = urllib.request.Request(
        _SLACK_API,
        data=text.encode("utf-8"),
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": f"Bearer {bot_token}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            if not isinstance(body, dict) or not body.get("ok"):
                message = _slack_api_error_message(body if isinstance(body, dict) else {})
                print(message, file=sys.stderr)
                raise SlackPostError(message)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        print(f"Slack API returned HTTP {exc.code}:", file=sys.stderr)
        if raw:
            print(raw, file=sys.stderr)
        raise SlackPostError(f"Slack API returned HTTP {exc.code}") from exc
    print("Slack notification sent.")


def load_payload(*, payload_json: str = "", payload_b64: str = "") -> dict[str, Any] | None:
    raw = payload_json or _env_str("PAYLOAD_JSON")
    if raw:
        obj = json.loads(raw)
        return obj if isinstance(obj, dict) else None
    b64 = payload_b64 or _env_str("PAYLOAD_JSON_B64")
    if not b64:
        return None
    obj = json.loads(base64.b64decode(b64.encode("ascii"), validate=True).decode("utf-8"))
    return obj if isinstance(obj, dict) else None


def cmd_post(args: argparse.Namespace) -> int:
    dry_run = _is_dry_run(args)
    bot_token = args.bot_token or _env_str("SLACK_BOT_TOKEN")
    try:
        payload = load_payload(payload_json=args.payload_json, payload_b64=args.payload_b64)
    except (ValueError, json.JSONDecodeError, UnicodeError) as exc:
        print(f"Invalid Slack payload: {exc}", file=sys.stderr)
        return 1
    if not payload:
        print("Slack payload is empty.", file=sys.stderr)
        return 1
    if not bot_token and not dry_run:
        print("SLACK_BOT_TOKEN is not set.", file=sys.stderr)
        return 1
    try:
        post_to_slack(bot_token, payload, dry_run=dry_run)
    except SlackPostError:
        return 1
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="POST a Slack payload via chat.postMessage.")
    parser.add_argument("--bot-token", default="", help="Slack bot token (xoxb-…)")
    parser.add_argument("--payload-b64", default="", help="Base64-encoded JSON payload")
    parser.add_argument("--payload-json", default="", help="Raw JSON payload")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print payload without HTTP POST",
    )
    parser.set_defaults(func=cmd_post)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
