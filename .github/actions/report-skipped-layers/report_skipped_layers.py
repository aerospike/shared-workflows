#!/usr/bin/env python3
"""Report test layers that a caller skipped because a secret is absent.

Each row names the layer, the tests that did not run, and why. The rows go to
the job summary and to a notice annotation. A skip does not fail the job; a
report that cannot be read does, so a broken caller cannot pass silently.

The caller decides what was skipped. This script never reads secrets.
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass
from typing import Any

FIELDS = ("layer", "tests", "reason")


class ReportError(Exception):
    """The layers input cannot be reported."""


@dataclass
class SkippedLayer:
    layer: str
    tests: str
    reason: str


def _require_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or value.strip() == "":
        raise ReportError(f"{label} must be a non-empty string")
    return value


def _load_row(row: Any, index: int) -> SkippedLayer:
    label = f"layers[{index}]"
    if not isinstance(row, dict):
        raise ReportError(f"{label} must be an object with layer, tests, and reason")

    extra = sorted(key for key in row if key not in FIELDS)
    if extra:
        names = ", ".join(extra)
        raise ReportError(f"{label}: unknown field {names}")

    missing = [key for key in FIELDS if key not in row]
    if missing:
        names = ", ".join(missing)
        raise ReportError(f"{label}: missing {names}")

    layer = _require_text(row["layer"], f"{label}.layer")
    tests = _require_text(row["tests"], f"{label}.tests")
    reason = _require_text(row["reason"], f"{label}.reason")
    return SkippedLayer(layer=layer, tests=tests, reason=reason)


def parse_layers(text: str) -> list[SkippedLayer]:
    if text.strip() == "":
        raise ReportError("layers is required; pass [] when no layer was skipped")

    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ReportError(f"layers is not valid JSON: {exc}") from exc

    if not isinstance(data, list):
        raise ReportError("layers must be a JSON array")

    layers = []
    for index, row in enumerate(data):
        layer = _load_row(row, index)
        layers.append(layer)
    return layers


def _cell(value: str) -> str:
    escaped = value.replace("|", "\\|")
    lines = escaped.splitlines()
    return " ".join(lines)


def render_markdown(layers: list[SkippedLayer]) -> str:
    if not layers:
        return "## Skipped layers\n\nNo secret-gated layers skipped.\n"

    lines = [
        "## Skipped layers",
        "",
        "These tests did not run, so this job did not prove them. A skip does not fail this job.",
        "",
        "| Layer | Tests not run | Reason |",
        "| --- | --- | --- |",
    ]
    for item in layers:
        layer = _cell(item.layer)
        tests = _cell(item.tests)
        reason = _cell(item.reason)
        lines.append(f"| {layer} | {tests} | {reason} |")
    body = "\n".join(lines)
    return body + "\n"


def _escape_data(value: str) -> str:
    escaped = value.replace("%", "%25")
    return escaped.replace("\r", "%0D").replace("\n", "%0A")


def _escape_property(value: str) -> str:
    escaped = _escape_data(value)
    return escaped.replace(":", "%3A").replace(",", "%2C")


def render_notices(layers: list[SkippedLayer]) -> list[str]:
    notices = []
    for item in layers:
        title = _escape_property(f"Skipped layer {item.layer}")
        message = _escape_data(f"{item.tests} did not run: {item.reason}")
        notices.append(f"::notice title={title}::{message}")
    return notices


def _write_output(name: str, value: str) -> None:
    output = os.environ.get("GITHUB_OUTPUT")
    if not output:
        return
    with open(output, "a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


def main() -> int:
    text = os.environ.get("SKIPPED_LAYERS", "")
    try:
        layers = parse_layers(text)
    except ReportError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    markdown = render_markdown(layers)
    print(markdown, end="")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(markdown)

    notices = render_notices(layers)
    for notice in notices:
        print(notice)

    count = len(layers)
    _write_output("skipped-count", str(count))
    return 0


if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code)
