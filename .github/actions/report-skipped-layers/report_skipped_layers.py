#!/usr/bin/env python3
"""Report test layers that a caller skipped because a secret is absent.

Writes a job summary table, one notice per layer, and the skipped-count output.
A skip does not fail the job; a layers input that cannot be read does.
"""

import json
import os
import sys

def cell(value):
    return " ".join(value.replace("|", "\\|").splitlines())


def escape(value):
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def append(variable, text):
    if os.environ.get(variable):
        with open(os.environ[variable], "a", encoding="utf-8") as handle:
            handle.write(text)


def main():
    try:
        layers = json.loads(os.environ.get("SKIPPED_LAYERS", ""))
        if not isinstance(layers, list):
            raise TypeError(f"{type(layers).__name__} is not an array")
        rows, notices = [], []
        for r in layers:
            rows.append(f"| {cell(r['layer'])} | {cell(r['tests'])} | {cell(r['reason'])} |\n")
            title = escape(f"Skipped layer {r['layer']}").replace(":", "%3A").replace(",", "%2C")
            notices.append(f"::notice title={title}::{escape(r['tests'] + ' did not run: ' + r['reason'])}")
    except (ValueError, KeyError, TypeError, AttributeError) as exc:
        print(f"Error: layers must be a JSON array of objects with layer, tests, and reason: {exc!r}", file=sys.stderr)
        return 1

    markdown = "## Skipped layers\n\nNo secret-gated layers skipped.\n"
    if rows:
        markdown = "## Skipped layers\n\nThese tests did not run, so this job did not prove them. A skip does not fail this job.\n\n"
        markdown += "| Layer | Tests not run | Reason |\n| --- | --- | --- |\n" + "".join(rows)
    print(markdown, end="")
    append("GITHUB_STEP_SUMMARY", markdown)
    for notice in notices:
        print(notice)
    append("GITHUB_OUTPUT", f"skipped-count={len(rows)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
