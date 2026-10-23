#!/usr/bin/env python3
"""Aggregate conformance-report.json files into a job summary.

Gate, from CLIENT-5546:

- fail when a row declared pass (or omitted, which means pass) actually failed
- fail when a row is unsupported or blocked and that result is not declared
- fail when a fixture case has no row, or a row names a case the fixture set does not have
- do not fail when unsupported was declared, or when a declared fail still fails

A case with no declaration is pass, except a case the fixture marks blocked, which
is declared blocked. That is the Java runner's rule. See aerospike-client-conformance
schema/report.schema.json and schema/fixture.schema.json, and <runtime>-declared.yaml
(client repos, for example java-declared.yaml). The README gate table lists the same rules.
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

RESULTS = ("pass", "fail", "unsupported", "blocked")
FIXTURE_KINDS = ("translate", "merge", "tls")


class CollectError(Exception):
    """A report or declaration cannot be aggregated."""


@dataclass
class FixtureSet:
    """Cases in one fixture set release, keyed by (fixture file, case name).

    The value is True when the fixture marks the case blocked.
    """

    version: str
    cases: dict[tuple[str, str], bool]


@dataclass
class Report:
    runtime: str
    client_version: str
    fixture_set_version: str
    counts: dict[str, int]
    rows: list[dict[str, str]]
    source: str


@dataclass
class ComparedRow:
    runtime: str
    file: str
    case: str
    declared: str
    actual: str
    reason: str
    kind: str = ""


@dataclass
class Collection:
    reports: list[Report]
    findings: list[ComparedRow]
    differences: list[ComparedRow]
    unsupported: list[ComparedRow]
    failures: list[ComparedRow]
    failed: bool


Declarations = dict[str, dict[str, dict[str, str]]]


def parse_declarations(text: str) -> Declarations:
    """Parse a <runtime>-declared.yaml document into fixture file -> case -> body."""
    try:
        loaded = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise CollectError(f"invalid declaration YAML: {exc}") from exc

    if loaded is None:
        return {}

    if not isinstance(loaded, dict) or not all(isinstance(cases, dict) for cases in loaded.values()):
        raise CollectError("declaration file must be a map of fixture files to cases")

    for file_name, cases in loaded.items():
        for case_name, body in cases.items():
            if not isinstance(body, dict) or body.get("result") not in RESULTS:
                raise CollectError(f"{file_name}:{case_name}: result must be one of {', '.join(RESULTS)}")

    return loaded


def declared_result(declarations: Declarations, file_name: str, case_name: str, fixture_blocked: bool) -> str:
    body = declarations.get(file_name, {}).get(case_name)
    if body is not None:
        return body["result"]

    if fixture_blocked:
        return "blocked"

    return "pass"


def load_report(data: Any, source: str) -> Report:
    """Read the fields the gate uses. The report schema is owned by aerospike-client-conformance."""
    try:
        rows = list(data["rows"])
        report = Report(
            runtime=str(data["runtime"]),
            client_version=str(data["clientVersion"]),
            fixture_set_version=str(data["fixtureSetVersion"]),
            counts={name: 0 for name in RESULTS},
            rows=rows,
            source=source,
        )
        for row in rows:
            if not all(isinstance(row[key], str) for key in ("file", "case", "result")):
                raise CollectError(f"{source}: a row needs string file, case and result: {row}")

            if row["result"] not in RESULTS:
                raise CollectError(f"{source}: invalid result {row['result']} for {row['file']}:{row['case']}")

            report.counts[row["result"]] += 1
    except (KeyError, TypeError) as exc:
        raise CollectError(f"{source}: not a conformance report: {exc!r}") from exc

    return report


def load_fixtures(directory: Path) -> FixtureSet:
    """Read VERSION and every fixture case from a fetched fixture set."""
    if not directory.is_dir():
        raise CollectError(f"fixtures directory not found: {directory}")

    version_path = directory / "VERSION"
    if not version_path.is_file():
        raise CollectError(f"fixtures directory has no VERSION: {directory}")

    version_text = version_path.read_text(encoding="utf-8")
    version = version_text.strip()

    cases: dict[tuple[str, str], bool] = {}
    for path in sorted(directory.rglob("*.yaml")):
        relative_path = path.relative_to(directory)
        if len(relative_path.parts) < 2 or any(part.startswith(".") for part in relative_path.parts):
            continue

        file_name = relative_path.as_posix()

        text = path.read_text(encoding="utf-8")
        try:
            loaded = yaml.safe_load(text)
        except yaml.YAMLError as exc:
            raise CollectError(f"{path}: invalid fixture YAML: {exc}") from exc

        if not isinstance(loaded, dict) or loaded.get("kind") not in FIXTURE_KINDS:
            continue

        rows = loaded.get("rows")
        if not isinstance(rows, list):
            raise CollectError(f"{file_name}: rows must be a list")

        for index, row in enumerate(rows):
            if not isinstance(row, dict) or not isinstance(row.get("case"), str):
                raise CollectError(f"{file_name}: rows[{index}] has no case")

            identity = (file_name, row["case"])
            if identity in cases:
                raise CollectError(f"{file_name}: duplicate case {row['case']}")

            cases[identity] = row.get("state") == "blocked"

    if not cases:
        raise CollectError(f"no fixture cases under {directory}")

    return FixtureSet(version=version, cases=cases)


def gate_kind(actual: str, declared: str) -> str | None:
    if actual == "fail" and declared == "pass":
        return "pass-to-fail"

    if actual == "unsupported" and declared != "unsupported":
        return "undeclared-unsupported"

    if actual == "blocked" and declared != "blocked":
        return "undeclared-blocked"

    return None


def _cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def _table(headers: list[str], rows: list[list[str]]) -> str:
    head = "| " + " | ".join(headers) + " |"
    sep = "| " + " | ".join("---" for _ in headers) + " |"
    body = []
    for row in rows:
        cells = []
        for cell in row:
            cells.append(_cell(cell))

        body.append("| " + " | ".join(cells) + " |")

    return "\n".join([head, sep, *body])


def find_reports(directory: Path) -> list[Path]:
    if not directory.is_dir():
        raise CollectError(f"reports directory not found: {directory}")
    return sorted(path for path in directory.rglob("conformance-report.json") if path.is_file())


def find_declarations(directory: Path) -> dict[str, Path]:
    if not directory.is_dir():
        raise CollectError(f"declarations directory not found: {directory}")
    found: dict[str, Path] = {}
    for path in sorted(directory.rglob("*-declared.yaml")):
        if not path.is_file():
            continue

        suffix = "-declared.yaml"
        runtime = path.name[: -len(suffix)]
        if runtime == "" or "/" in runtime or "\\" in runtime:
            raise CollectError(f"declaration file name is not <runtime>-declared.yaml: {path}")

        if runtime in found:
            raise CollectError(f"duplicate declarations for runtime {runtime}: {found[runtime]} and {path}")

        found[runtime] = path
    return found


def _check_declarations(declarations: Declarations, fixtures: FixtureSet) -> None:
    """Reject a declaration for a fixture file or case the fixture set does not have."""
    fixture_files = set()
    for file_name, _ in fixtures.cases:
        fixture_files.add(file_name)

    for file_name, file_cases in declarations.items():
        if file_name not in fixture_files:
            raise CollectError(f"unknown fixture file {file_name}")

        for case_name in file_cases:
            if (file_name, case_name) not in fixtures.cases:
                raise CollectError(f"{file_name}:{case_name}: unknown case")


def _compare_report(report: Report, declarations: Declarations, fixtures: FixtureSet) -> list[ComparedRow]:
    """Compare every row and every fixture case. A gate failure has a non-empty kind."""
    compared = []
    reported: set[tuple[str, str]] = set()
    for row in report.rows:
        identity = (row["file"], row["case"])
        reported.add(identity)
        if identity not in fixtures.cases:
            compared.append(
                ComparedRow(
                    runtime=report.runtime,
                    file=row["file"],
                    case=row["case"],
                    declared="-",
                    actual=row["result"],
                    reason=f"not a case in fixture set {fixtures.version}",
                    kind="unknown-case",
                )
            )
            continue

        fixture_blocked = fixtures.cases[identity]
        declared = declared_result(declarations, row["file"], row["case"], fixture_blocked)
        kind = gate_kind(row["result"], declared)
        if kind is None:
            kind = ""

        compared.append(
            ComparedRow(
                runtime=report.runtime,
                file=row["file"],
                case=row["case"],
                declared=declared,
                actual=row["result"],
                reason=str(row.get("reason", "")),
                kind=kind,
            )
        )

    for identity, fixture_blocked in fixtures.cases.items():
        if identity in reported:
            continue

        file_name, case_name = identity
        declared = declared_result(declarations, file_name, case_name, fixture_blocked)
        compared.append(
            ComparedRow(
                runtime=report.runtime,
                file=file_name,
                case=case_name,
                declared=declared,
                actual="missing",
                reason="the report has no row for this fixture case",
                kind="missing-row",
            )
        )

    return compared


def collect(
    reports_dir: Path,
    fixtures_dir: Path,
    declarations_dir: Path | None = None,
) -> Collection:
    fixtures = load_fixtures(fixtures_dir)

    report_paths = find_reports(reports_dir)
    if not report_paths:
        raise CollectError(f"no conformance-report.json under {reports_dir}")

    declaration_paths: dict[str, Path] = {}
    if declarations_dir is not None:
        declaration_paths = find_declarations(declarations_dir)

    parsed_declarations: dict[str, Declarations] = {}
    for runtime, path in declaration_paths.items():
        text = path.read_text(encoding="utf-8")
        try:
            declarations = parse_declarations(text)
            _check_declarations(declarations, fixtures)
        except CollectError as exc:
            raise CollectError(f"{path}: {exc}") from exc

        parsed_declarations[runtime] = declarations

    reports = []
    for path in report_paths:
        text = path.read_text(encoding="utf-8")
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            raise CollectError(f"{path}: invalid JSON: {exc}") from exc
        reports.append(load_report(data, str(path)))

    runtimes = [report.runtime for report in reports]
    unique_runtimes = set(runtimes)
    if len(runtimes) != len(unique_runtimes):
        joined_runtimes = ", ".join(runtimes)
        raise CollectError(f"duplicate runtime in reports: {joined_runtimes}")

    for report in reports:
        if report.fixture_set_version != fixtures.version:
            raise CollectError(
                f"{report.source}: fixtureSetVersion {report.fixture_set_version} "
                f"does not match fixtures VERSION {fixtures.version}"
            )

    findings = []
    differences = []
    unsupported_rows = []
    fail_rows = []
    for report in reports:
        declarations = parsed_declarations.get(report.runtime, {})
        compared = _compare_report(report, declarations, fixtures)
        for record in compared:
            if record.kind:
                findings.append(record)
            elif record.declared != record.actual:
                differences.append(record)

            if record.actual == "unsupported":
                unsupported_rows.append(record)

            if record.actual == "fail":
                fail_rows.append(record)

    return Collection(
        reports=reports,
        findings=findings,
        differences=differences,
        unsupported=unsupported_rows,
        failures=fail_rows,
        failed=bool(findings),
    )


def _section(title: str, note: str, items: list[ComparedRow], fields: list[str]) -> list[str]:
    if not items:
        return []

    lines = [f"### {title}", ""]
    if note:
        lines.extend([note, ""])

    headers = [name.capitalize() for name in fields]
    rows = [[getattr(item, name) for name in fields] for item in items]
    return [*lines, _table(headers, rows), ""]


def render_markdown(result: Collection) -> str:
    count_rows = []
    for report in result.reports:
        gate = "ok"
        if any(item.runtime == report.runtime for item in result.findings):
            gate = "fail"

        counts = [str(report.counts[name]) for name in RESULTS]
        count_rows.append([report.runtime, report.client_version, report.fixture_set_version, *counts, gate])

    rendered_lines = [
        "## Conformance",
        "",
        _table(
            ["Runtime", "Client", "Fixture set", "Pass", "Fail", "Unsupported", "Blocked", "Gate"],
            count_rows,
        ),
        "",
    ]
    if not result.findings:
        rendered_lines.extend(["Every fixture case has a row, and no row trips the gate.", ""])

    rendered_lines.extend(
        _section(
            "Gate failures",
            "A pass that is now fail, an unsupported or blocked result that was not declared, "
            "a fixture case with no row, or a row that is not a fixture case.",
            result.findings,
            ["runtime", "kind", "file", "case", "declared", "actual", "reason"],
        )
    )
    rendered_lines.extend(
        _section(
            "Unsupported",
            "Declared unsupported is a result, not a skipped test. It does not fail this job.",
            result.unsupported,
            ["runtime", "file", "case", "declared", "reason"],
        )
    )
    rendered_lines.extend(_section("Fail", "", result.failures, ["runtime", "file", "case", "declared", "reason"]))
    rendered_lines.extend(
        _section(
            "Other declaration differences",
            "These do not fail this job. The runtime test compares every row with its declaration.",
            result.differences,
            ["runtime", "file", "case", "declared", "actual", "reason"],
        )
    )
    return "\n".join(rendered_lines).rstrip() + "\n"


def _write_output(name: str, value: str) -> None:
    output = os.environ.get("GITHUB_OUTPUT")
    if not output:
        return
    with open(output, "a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


def main() -> int:
    reports_raw = os.environ.get("REPORTS_DIRECTORY", "")
    if reports_raw == "":
        print("Error: reports-directory is required", file=sys.stderr)
        return 1

    fixtures_raw = os.environ.get("FIXTURES_DIRECTORY", "")
    if fixtures_raw == "":
        print("Error: fixtures-directory is required", file=sys.stderr)
        return 1

    declarations_raw = os.environ.get("DECLARATIONS_DIRECTORY", "")
    declarations_dir = None
    if declarations_raw:
        declarations_dir = Path(declarations_raw)

    reports_dir = Path(reports_raw)
    fixtures_dir = Path(fixtures_raw)
    try:
        result = collect(reports_dir, fixtures_dir, declarations_dir)
    except CollectError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        _write_output("gate", "failure")
        return 1

    markdown = render_markdown(result)
    print(markdown, end="")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(markdown)

    if result.failed:
        gate = "failure"
    else:
        gate = "success"
    _write_output("gate", gate)
    if result.failed:
        return 1
    return 0


if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code)
