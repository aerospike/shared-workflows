#!/usr/bin/env python3
"""Render Slack Block Kit chat.postMessage payloads from a container template."""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
TEMPLATE_PATH = SCRIPT_DIR / "templates" / "container.json"
_PLACEHOLDER_RE = re.compile(r"\{([a-zA-Z0-9_]+)\}")

MESSAGE_TYPE_CONFIG: dict[str, dict[str, str]] = {
    "info": {
        "block_id": "alert_info",
        "icon_image_url": "https://a.slack-edge.com/production-standard-emoji-assets/10.2/google-medium/2139-fe0f@2x.png",
        "icon_alt_text": "Info",
        "is_collapsible": "false",
        "default_collapsed": "false",
    },
    "fail": {
        "block_id": "alert_fail",
        "icon_image_url": "https://a.slack-edge.com/production-standard-emoji-assets/10.2/google-medium/274c@2x.png",
        "icon_alt_text": "Failure",
        "is_collapsible": "false",
        "default_collapsed": "false",
    },
    "success": {
        "block_id": "alert_success",
        "icon_image_url": "https://a.slack-edge.com/production-standard-emoji-assets/14.0/apple-large/2705.png",
        "icon_alt_text": "Success",
        "is_collapsible": "false",
        "default_collapsed": "false",
    },
    "blocked": {
        "block_id": "alert_blocked",
        "icon_image_url": "https://a.slack-edge.com/production-standard-emoji-assets/10.2/google-medium/1f6d1@2x.png",
        "icon_alt_text": "Blocked",
        "is_collapsible": "false",
        "default_collapsed": "false",
    },
    "warning": {
        "block_id": "alert_warning",
        "icon_image_url": "https://a.slack-edge.com/production-standard-emoji-assets/10.2/google-medium/23f3@2x.png",
        "icon_alt_text": "Warning",
        "is_collapsible": "true",
        "default_collapsed": "false",
    },
}


def _env_str(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def github_output_path() -> str | None:
    path = os.environ.get("GITHUB_OUTPUT", "").strip()
    return path or None


def write_github_output(key: str, value: str) -> None:
    path = github_output_path()
    if not path:
        return
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(f"{key}={value}\n")


def encode_payload_b64(payload: dict[str, Any]) -> str:
    text = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def config_for_message_type(message_type: str) -> dict[str, str]:
    key = message_type.strip().lower()
    config = MESSAGE_TYPE_CONFIG.get(key)
    if not config:
        supported = ", ".join(sorted(MESSAGE_TYPE_CONFIG))
        raise ValueError(f"unsupported message-type {message_type!r}; expected one of: {supported}")
    return config


def load_template() -> dict[str, Any]:
    if not TEMPLATE_PATH.is_file():
        raise ValueError(f"template not found: {TEMPLATE_PATH}")
    with TEMPLATE_PATH.open(encoding="utf-8") as fh:
        obj = json.load(fh)
    if not isinstance(obj, dict):
        raise ValueError(f"template must be a JSON object: {TEMPLATE_PATH}")
    return obj


def substitute_value(value: str, variables: dict[str, str]) -> str:
    def repl(match: re.Match[str]) -> str:
        key = match.group(1)
        return variables.get(key, match.group(0))

    return _PLACEHOLDER_RE.sub(repl, value)


def substitute(obj: Any, variables: dict[str, str]) -> Any:
    if isinstance(obj, str):
        return substitute_value(obj, variables)
    if isinstance(obj, list):
        return [substitute(item, variables) for item in obj]
    if isinstance(obj, dict):
        return {key: substitute(val, variables) for key, val in obj.items()}
    return obj


def parse_child_blocks(raw: str) -> list[dict[str, Any]]:
    text = raw.strip()
    if not text or text == "[]":
        return []
    obj = json.loads(text)
    if not isinstance(obj, list):
        raise ValueError("child-blocks must be a JSON array")
    for index, item in enumerate(obj):
        if not isinstance(item, dict):
            raise ValueError(f"child-blocks[{index}] must be a JSON object")
    return obj


def _as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() == "true"


def normalize_container(container: dict[str, Any]) -> None:
    container["is_collapsible"] = _as_bool(container.get("is_collapsible"))
    if container["is_collapsible"]:
        container["default_collapsed"] = _as_bool(container.get("default_collapsed"))
    else:
        container.pop("default_collapsed", None)


def build_payload(
    *,
    message_type: str,
    title: str,
    subtitle: str,
    channel_id: str,
    fallback_text: str = "",
    child_blocks: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    template = load_template()
    resolved_fallback = fallback_text.strip() or f"{title}: {subtitle}"
    variables = {
        **config_for_message_type(message_type),
        "title": title,
        "subtitle": subtitle,
        "fallback_text": resolved_fallback,
    }
    payload = substitute(template, variables)
    blocks = payload.get("blocks")
    if not isinstance(blocks, list) or not blocks:
        raise ValueError("template must contain a blocks array with at least one block")
    container = blocks[0]
    if not isinstance(container, dict) or container.get("type") != "container":
        raise ValueError("template must use a container block as the first block")
    normalize_container(container)
    container["child_blocks"] = child_blocks or []
    if channel_id:
        payload["channel"] = channel_id
    return payload


def emit_payload(payload: dict[str, Any]) -> None:
    b64 = encode_payload_b64(payload)
    if github_output_path():
        write_github_output("payload_json_b64", b64)
        return
    print(b64)


def cmd_render(args: argparse.Namespace) -> int:
    channel_id = args.channel_id or _env_str("SLACK_CHANNEL_ID")
    if not channel_id:
        print("::notice::Slack notify skipped: slack-channel-id is empty.", file=sys.stderr)
        if github_output_path():
            write_github_output("payload_json_b64", "")
        return 0
    try:
        child_blocks = parse_child_blocks(args.child_blocks or _env_str("CHILD_BLOCKS", "[]"))
        payload = build_payload(
            message_type=args.message_type or _env_str("MESSAGE_TYPE"),
            title=args.title or _env_str("TITLE"),
            subtitle=args.subtitle or _env_str("SUBTITLE"),
            channel_id=channel_id,
            fallback_text=args.fallback_text or _env_str("FALLBACK_TEXT"),
            child_blocks=child_blocks,
        )
    except (ValueError, json.JSONDecodeError, UnicodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if args.dry_run:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0
    emit_payload(payload)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Render Slack Block Kit payloads from a container template.",
    )
    parser.add_argument(
        "--message-type",
        default="",
        help="Alert style: info, fail, success, blocked, or warning",
    )
    parser.add_argument("--title", default="", help="Container title")
    parser.add_argument("--subtitle", default="", help="Container subtitle")
    parser.add_argument("--channel-id", default="", help="Slack channel ID")
    parser.add_argument("--fallback-text", default="", help="chat.postMessage text fallback")
    parser.add_argument(
        "--child-blocks",
        default="",
        help="JSON array of Block Kit blocks for the container child_blocks section",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print rendered payload JSON to stdout instead of GITHUB_OUTPUT",
    )
    parser.set_defaults(func=cmd_render)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
