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
    bundle_name: str,
    bundle_version: str,
) -> str:
    return (
        f"*Workflow*\n`{called_workflow}`\n"
        f"*shared-workflows ref*\n`{called_workflow_ref}`\n"
        f"*Bundle*\n`{bundle_name}` @ `{bundle_version}`"
    )


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
        "--called-workflow",
        default=_DEFAULT_CALLED_WORKFLOW,
        help="Called reusable workflow file name.",
    )
    parser.add_argument(
        "--called-workflow-ref",
        default=_env_str("CALLED_WORKFLOW_REF"),
        help="shared-workflows ref used by the caller (gh-workflows-ref).",
    )
    parser.add_argument(
        "--bundle-name",
        default=_env_str("JF_BUNDLE_NAME"),
        help="Release bundle name for the called workflow context.",
    )
    parser.add_argument(
        "--bundle-version",
        default=_env_str("JF_VERSION"),
        help="Release bundle version for the called workflow context.",
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

    server_url = _env_str("GITHUB_SERVER_URL", "https://github.com")
    workflow = _env_str("GITHUB_WORKFLOW", "unknown")
    ref_name = _env_str("GITHUB_REF_NAME", "unknown")
    sha = _env_str("GITHUB_SHA")

    failed_summary = format_failed_summary(
        args.job_name,
        args.failed_step,
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
        bundle_name=args.bundle_name,
        bundle_version=args.bundle_version,
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
