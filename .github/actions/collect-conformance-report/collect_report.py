#!/usr/bin/env python3
"""Aggregate conformance-report.json files into a job summary and a gate.

The gate fails on a pass-to-fail regression, an unsupported or blocked result that
was not declared, a fixture case with no row, and a row for a case the fixture set
does not have. A case with no declaration is pass, or blocked when the fixture marks
it blocked, which is the Java runner's rule. The README gate table lists the same rules.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import yaml

RESULTS = ("pass", "fail", "unsupported", "blocked")
FIXTURE_KINDS = ("translate", "merge", "tls")


class CollectError(Exception):
    """A report, declaration or fixture set cannot be read."""


def read_yaml(path: Path):
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        raise CollectError(f"{path}: invalid YAML: {exc}") from exc


def load_fixtures(directory: Path) -> tuple[str, dict[tuple[str, str], bool]]:
    """Return the fixture set VERSION and every case, mapped to whether the fixture blocks it."""
    version_path = directory / "VERSION"
    if not version_path.is_file():
        raise CollectError(f"fixtures directory has no VERSION: {directory}")

    cases: dict[tuple[str, str], bool] = {}
    for path in sorted(directory.rglob("*.yaml")):
        relative = path.relative_to(directory)
        if len(relative.parts) < 2 or any(part.startswith(".") for part in relative.parts):
            continue
        data = read_yaml(path)
        if not isinstance(data, dict) or data.get("kind") not in FIXTURE_KINDS:
            continue
        for row in data.get("rows") or []:
            if not isinstance(row, dict) or not isinstance(row.get("case"), str):
                raise CollectError(f"{relative}: a row has no case")
            key = (relative.as_posix(), row["case"])
            if key in cases:
                raise CollectError(f"{relative}: duplicate case {row['case']}")
            cases[key] = row.get("state") == "blocked"

    if not cases:
        raise CollectError(f"no fixture cases under {directory}")
    return version_path.read_text(encoding="utf-8").strip(), cases


def load_declarations(directory: Path, cases: dict) -> dict[str, dict[tuple[str, str], str]]:
    """Read every <runtime>-declared.yaml into runtime -> (file, case) -> declared result."""
    if not directory.is_dir():
        raise CollectError(f"declarations directory not found: {directory}")
    declared: dict[str, dict[tuple[str, str], str]] = {}
    for path in sorted(directory.rglob("*-declared.yaml")):
        runtime = path.name.removesuffix("-declared.yaml")
        if not runtime or runtime in declared:
            raise CollectError(f"{path}: empty or duplicate runtime name")
        data = read_yaml(path) or {}
        entries = {}
        try:
            for file_name, file_cases in data.items():
                for case_name, body in file_cases.items():
                    if (file_name, case_name) not in cases:
                        raise CollectError(f"{path}: {file_name}:{case_name} is not a fixture case")
                    if body.get("result") not in RESULTS:
                        raise CollectError(f"{path}: {file_name}:{case_name}: result must be one of {', '.join(RESULTS)}")
                    entries[(file_name, case_name)] = body["result"]
        except AttributeError as exc:
            raise CollectError(f"{path}: must map fixture files to cases to {{result, reason}}") from exc
        declared[runtime] = entries
    return declared


def load_reports(directory: Path, version: str) -> list[dict]:
    paths = sorted(directory.rglob("conformance-report.json"))
    if not paths:
        raise CollectError(f"no conformance-report.json under {directory}")

    reports = []
    for path in paths:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            report = {
                "runtime": str(data["runtime"]),
                "client": str(data["clientVersion"]),
                "version": str(data["fixtureSetVersion"]),
                "rows": [(row["file"], row["case"], row["result"], str(row.get("reason", ""))) for row in data["rows"]],
            }
        except (json.JSONDecodeError, KeyError, TypeError) as exc:
            raise CollectError(f"{path}: not a conformance report: {exc!r}") from exc
        for file_name, case_name, result, _ in report["rows"]:
            if result not in RESULTS:
                raise CollectError(f"{path}: invalid result {result} for {file_name}:{case_name}")
        if report["version"] != version:
            raise CollectError(f"{path}: fixtureSetVersion {report['version']} does not match fixtures VERSION {version}")
        reports.append(report)

    runtimes = [report["runtime"] for report in reports]
    if len(runtimes) != len(set(runtimes)):
        raise CollectError(f"duplicate runtime in reports: {', '.join(runtimes)}")
    return reports


def gate_kind(actual: str, declared: str) -> str:
    if actual == "fail" and declared == "pass":
        return "pass-to-fail"
    if actual in ("unsupported", "blocked") and declared != actual:
        return f"undeclared-{actual}"
    return ""


def findings_for(report: dict, declared: dict, cases: dict, version: str) -> list[list[str]]:
    """Rows that trip the gate: runtime, kind, file, case, declared, actual, reason."""
    found = []
    seen = set()
    for file_name, case_name, actual, reason in report["rows"]:
        seen.add((file_name, case_name))
        if (file_name, case_name) not in cases:
            found.append(["unknown-case", file_name, case_name, "-", actual, f"not a case in fixture set {version}"])
            continue
        expected = declared.get((file_name, case_name), "blocked" if cases[(file_name, case_name)] else "pass")
        kind = gate_kind(actual, expected)
        if kind:
            found.append([kind, file_name, case_name, expected, actual, reason])
    for (file_name, case_name), blocked in cases.items():
        if (file_name, case_name) not in seen:
            expected = declared.get((file_name, case_name), "blocked" if blocked else "pass")
            found.append(["missing-row", file_name, case_name, expected, "missing", "the report has no row for this fixture case"])
    return [[report["runtime"], *finding] for finding in found]


def table(headers: list[str], rows: list[list[str]]) -> list[str]:
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
    for row in rows:
        lines.append("| " + " | ".join(cell.replace("|", "\\|").replace("\n", " ") for cell in row) + " |")
    return [*lines, ""]


def collect(reports_dir: Path, fixtures_dir: Path, declarations_dir: Path | None) -> tuple[str, bool]:
    """Return the markdown summary and whether the gate failed."""
    version, cases = load_fixtures(fixtures_dir)
    declarations = load_declarations(declarations_dir, cases) if declarations_dir else {}
    reports = load_reports(reports_dir, version)

    findings, counts, unsupported = [], [], []
    for report in reports:
        found = findings_for(report, declarations.get(report["runtime"], {}), cases, version)
        findings.extend(found)
        totals = [str(sum(1 for row in report["rows"] if row[2] == result)) for result in RESULTS]
        counts.append([report["runtime"], report["client"], report["version"], *totals, "fail" if found else "ok"])
        unsupported.extend(
            [report["runtime"], file_name, case_name, reason]
            for file_name, case_name, result, reason in report["rows"]
            if result == "unsupported"
        )

    lines = ["## Conformance", ""]
    lines += table(["Runtime", "Client", "Fixture set", "Pass", "Fail", "Unsupported", "Blocked", "Gate"], counts)
    if findings:
        lines += ["### Gate failures", ""]
        lines += table(["Runtime", "Kind", "File", "Case", "Declared", "Actual", "Reason"], findings)
    else:
        lines += ["Every fixture case has a row, and no row trips the gate.", ""]
    if unsupported:
        lines += ["### Unsupported", "", "Declared unsupported is a result, not a skipped test.", ""]
        lines += table(["Runtime", "File", "Case", "Reason"], unsupported)
    return "\n".join(lines).rstrip() + "\n", bool(findings)


def write_output(gate: str) -> None:
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"gate={gate}\n")


def main() -> int:
    reports_dir = os.environ.get("REPORTS_DIRECTORY", "")
    fixtures_dir = os.environ.get("FIXTURES_DIRECTORY", "")
    declarations_dir = os.environ.get("DECLARATIONS_DIRECTORY", "")
    try:
        if not reports_dir or not fixtures_dir:
            raise CollectError("reports-directory and fixtures-directory are required")
        markdown, failed = collect(Path(reports_dir), Path(fixtures_dir), Path(declarations_dir) if declarations_dir else None)
    except CollectError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        write_output("failure")
        return 1

    print(markdown, end="")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(markdown)
    write_output("failure" if failed else "success")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
