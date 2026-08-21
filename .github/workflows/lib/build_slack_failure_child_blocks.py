#!/usr/bin/env python3
"""Build notify-slack child-blocks JSON for a failed reusable workflow job."""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

_DEFAULT_CALLED_WORKFLOW = "reusable_create-release-bundle.yaml"
_DEFAULT_FAILED_SUMMARY_MAX_CHARS = 1500


def _env_str(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _run_url(server_url: str, repository: str, run_id: str) -> str:
    base = server_url.rstrip("/")
    return f"{base}/{repository}/actions/runs/{run_id}"


def format_failed_summary(
    job_name: str,
    failed_steps: list[str],
    *,
    max_chars: int,
) -> str:
    if failed_steps:
        step_list = ", ".join(f"`{step}`" for step in failed_steps)
        summary = f"*{job_name}* — {step_list}"
    else:
        summary = f"*{job_name}* failed"
    return summary[:max_chars]


def parse_failed_steps_json(raw: str) -> list[str]:
    text = raw.strip()
    if not text or text == "[]":
        return []
    obj = json.loads(text)
    if not isinstance(obj, list):
        raise ValueError("failed-steps JSON must be an array")
    names: list[str] = []
    for index, item in enumerate(obj):
        if not isinstance(item, str) or not item:
            raise ValueError(f"failed-steps[{index}] must be a non-empty string")
        names.append(item)
    return names


def parse_failed_step_checks_json(raw: str) -> list[str]:
    text = raw.strip()
    if not text or text == "[]":
        return []
    obj = json.loads(text)
    if not isinstance(obj, list):
        raise ValueError("failed-step-checks JSON must be an array")
    names: list[str] = []
    for index, item in enumerate(obj):
        if not isinstance(item, dict):
            raise ValueError(f"failed-step-checks[{index}] must be an object")
        if item.get("outcome") != "failure":
            continue
        name = item.get("name")
        if not isinstance(name, str) or not name:
            raise ValueError(f"failed-step-checks[{index}].name must be a non-empty string")
        names.append(name)
    return names


def resolve_failed_steps(
    *,
    failed_step_args: list[str],
    failed_steps_json: str,
    failed_step_checks_json: str,
) -> list[str]:
    names: list[str] = []
    names.extend(failed_step_args)
    if failed_steps_json:
        names.extend(parse_failed_steps_json(failed_steps_json))
    if failed_step_checks_json:
        names.extend(parse_failed_step_checks_json(failed_step_checks_json))
    # Preserve order while dropping duplicates.
    seen: set[str] = set()
    unique: list[str] = []
    for name in names:
        if name not in seen:
            seen.add(name)
            unique.append(name)
    return unique


def _caller_info(
    *,
    repository: str,
    workflow: str,
    job: str,
    ref_name: str,
    sha: str,
) -> str:
    short_sha = sha[:7] if sha else "unknown"
    return (
        f"*Repository*\n`{repository}`\n"
        f"*Workflow*\n`{workflow}`\n"
        f"*Job*\n`{job}`\n"
        f"*Ref*\n`{ref_name}` @ `{short_sha}`"
    )


def _called_info(
    *,
    called_workflow: str,
    called_workflow_ref: str,
    detail_label: str,
    detail_name: str,
    detail_version: str,
) -> str:
    lines = [f"*Workflow*\n`{called_workflow}`"]
    if called_workflow_ref:
        lines.append(f"*shared-workflows ref*\n`{called_workflow_ref}`")
    if detail_name:
        if detail_version:
            lines.append(f"*{detail_label}*\n`{detail_name}` @ `{detail_version}`")
        else:
            lines.append(f"*{detail_label}*\n`{detail_name}`")
    return "\n".join(lines)


def build_child_blocks(
    *,
    run_url: str,
    failed_summary: str,
    caller: str,
    called: str,
) -> list[dict[str, Any]]:
    return [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*Failed jobs/steps*\n{failed_summary}",
            },
        },
        {
            "type": "section",
            "fields": [
                {"type": "mrkdwn", "text": f"*Caller*\n{caller}"},
                {"type": "mrkdwn", "text": f"*Called workflow*\n{called}"},
            ],
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"<{run_url}|View workflow run>",
            },
        },
    ]


def write_github_output(output_path: str, key: str, value: str) -> None:
    delimiter = f"{key}_{os.urandom(8).hex()}"
    with open(output_path, "a", encoding="utf-8") as handle:
        handle.write(f"{key}<<{delimiter}\n")
        handle.write(value)
        handle.write(f"\n{delimiter}\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build notify-slack child-blocks JSON from current-job failure context."
    )
    parser.add_argument(
        "--repository",
        default=_env_str("GITHUB_REPOSITORY"),
        help="GitHub repository (owner/name). Defaults to GITHUB_REPOSITORY.",
    )
    parser.add_argument(
        "--run-id",
        default=_env_str("GITHUB_RUN_ID"),
        help="GitHub Actions run ID. Defaults to GITHUB_RUN_ID.",
    )
    parser.add_argument(
        "--job-name",
        default=_env_str("GITHUB_JOB"),
        help="Failed job name. Defaults to GITHUB_JOB.",
    )
    parser.add_argument(
        "--failed-step",
        action="append",
        default=[],
        help="Failed step name (repeat for multiple steps).",
    )
    parser.add_argument(
        "--failed-steps-json",
        default=_env_str("FAILED_STEPS_JSON", "[]"),
        help="JSON array of failed step names.",
    )
    parser.add_argument(
        "--failed-step-checks-json",
        default=_env_str("FAILED_STEP_CHECKS_JSON", "[]"),
        help='JSON array of {"name":"...","outcome":"..."} objects.',
    )
    parser.add_argument(
        "--called-workflow",
        default=_DEFAULT_CALLED_WORKFLOW,
        help="Called reusable workflow file name.",
    )
    parser.add_argument(
        "--called-workflow-ref",
        default=_env_str("CALLED_WORKFLOW_REF"),
        help="shared-workflows ref used by the caller (gh-workflows-ref).",
    )
    parser.add_argument("--detail-label", default="Bundle", help="Called-workflow detail label.")
    parser.add_argument(
        "--called-detail-label",
        dest="detail_label",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--detail-name",
        default=_env_str("DETAIL_NAME") or _env_str("JF_BUNDLE_NAME"),
        help="Primary detail value for the called workflow context.",
    )
    parser.add_argument(
        "--bundle-name",
        dest="detail_name",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--detail-version",
        default=_env_str("DETAIL_VERSION") or _env_str("JF_VERSION"),
        help="Secondary detail value for the called workflow context.",
    )
    parser.add_argument(
        "--bundle-version",
        dest="detail_version",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--failed-summary-max-chars",
        type=int,
        default=_DEFAULT_FAILED_SUMMARY_MAX_CHARS,
        help="Maximum characters for the failed jobs/steps summary.",
    )
    parser.add_argument(
        "--github-output",
        default=_env_str("GITHUB_OUTPUT"),
        help="Path to GITHUB_OUTPUT (writes child_blocks_json when set).",
    )
    parser.add_argument(
        "--output-key",
        default="child_blocks_json",
        help="Output key written to GITHUB_OUTPUT.",
    )
    parser.add_argument(
        "--print-json",
        action="store_true",
        help="Print child-blocks JSON to stdout.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    missing = [
        name
        for name, value in (
            ("--repository / GITHUB_REPOSITORY", args.repository),
            ("--run-id / GITHUB_RUN_ID", args.run_id),
            ("--job-name / GITHUB_JOB", args.job_name),
        )
        if not value
    ]
    if missing:
        print("Missing required values: " + ", ".join(missing), file=sys.stderr)
        return 1

    try:
        failed_steps = resolve_failed_steps(
            failed_step_args=args.failed_step,
            failed_steps_json=args.failed_steps_json,
            failed_step_checks_json=args.failed_step_checks_json,
        )
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"Invalid failed step input: {exc}", file=sys.stderr)
        return 1

    server_url = _env_str("GITHUB_SERVER_URL", "https://github.com")
    workflow = _env_str("GITHUB_WORKFLOW", "unknown")
    ref_name = _env_str("GITHUB_REF_NAME", "unknown")
    sha = _env_str("GITHUB_SHA")

    failed_summary = format_failed_summary(
        args.job_name,
        failed_steps,
        max_chars=args.failed_summary_max_chars,
    )
    caller = _caller_info(
        repository=args.repository,
        workflow=workflow,
        job=args.job_name,
        ref_name=ref_name,
        sha=sha,
    )
    called = _called_info(
        called_workflow=args.called_workflow,
        called_workflow_ref=args.called_workflow_ref,
        detail_label=args.detail_label,
        detail_name=args.detail_name,
        detail_version=args.detail_version,
    )
    blocks = build_child_blocks(
        run_url=_run_url(server_url, args.repository, args.run_id),
        failed_summary=failed_summary,
        caller=caller,
        called=called,
    )

    blocks_json = json.dumps(blocks, separators=(",", ":"), ensure_ascii=False)

    if args.github_output:
        write_github_output(args.github_output, args.output_key, blocks_json)
    if args.print_json or not args.github_output:
        print(blocks_json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
