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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

RESULTS = ("pass", "fail", "unsupported", "blocked")
REPORT_KEYS = {"runtime", "clientVersion", "fixtureSetVersion", "counts", "rows"}
ROW_KEYS = {"file", "case", "result", "reason", "detail"}
COUNT_KEYS = {"pass", "fail", "unsupported", "blocked"}
FILE_PATTERN_PART = "abcdefghijklmnopqrstuvwxyz0123456789-"
FIXTURE_KINDS = ("translate", "merge", "tls")


class CollectError(Exception):
    """A report or declaration cannot be aggregated."""


@dataclass
class Declaration:
    result: str
    reason: str | None = None


@dataclass
class Declarations:
    """Cases declared by one runtime, keyed by fixture file then case name."""

    files: dict[str, dict[str, Declaration]] = field(default_factory=dict)

    def declared_result(self, file_name: str, case_name: str, fixture_blocked: bool) -> str:
        file_cases = self.files.get(file_name)
        if file_cases is None or case_name not in file_cases:
            if fixture_blocked:
                return "blocked"

            return "pass"

        return file_cases[case_name].result


@dataclass
class FixtureSet:
    """Cases in one fixture set release, keyed by (fixture file, case name).

    The value is True when the fixture marks the case blocked.
    """

    version: str
    cases: dict[tuple[str, str], bool]


@dataclass
class ReportRow:
    file: str
    case: str
    result: str
    reason: str = ""
    detail: str = ""


@dataclass
class Report:
    runtime: str
    client_version: str
    fixture_set_version: str
    counts: dict[str, int]
    rows: list[ReportRow]
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


def _listed(values: list[str]) -> str:
    ordered = sorted(values)
    return ", ".join(ordered)


def _construct_unique_map(loader: yaml.SafeLoader, node: yaml.nodes.MappingNode) -> dict[Any, Any]:
    mapping: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=False)
        if key in mapping:
            raise CollectError(f"duplicate key {key}")

        value = loader.construct_object(value_node, deep=False)
        mapping[key] = value
    return mapping


class UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader that rejects duplicate keys."""


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _construct_unique_map,
)


def _valid_file_name(file_name: str) -> bool:
    if not file_name.endswith(".yaml"):
        return False

    segments = file_name[: -len(".yaml")].split("/")
    if len(segments) < 2:
        return False

    for segment in segments:
        if not segment:
            return False

        for char in segment:
            if char not in FILE_PATTERN_PART:
                return False

    return True


def _valid_case_name(case_name: str) -> bool:
    if not case_name:
        return False
    for char in case_name:
        if char not in FILE_PATTERN_PART and char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ_":
            return False
    return True


def _declaration_from_body(file_name: str, case_name: str, body: dict[str, str]) -> Declaration:
    unknown = [key for key in body if key not in ("result", "reason")]
    if unknown:
        names = _listed(unknown)
        raise CollectError(f"{file_name}:{case_name}: unknown key {names}")

    if "result" not in body:
        raise CollectError(f"{file_name}:{case_name}: missing result")

    result = body["result"]
    if result not in RESULTS:
        raise CollectError(f"{file_name}:{case_name}: invalid result {result}")

    reason = body.get("reason")
    if result != "pass" and not reason:
        raise CollectError(f"{file_name}:{case_name}: a {result} declaration needs a reason")

    return Declaration(result, reason)


def parse_declarations(text: str) -> Declarations:
    """Parse a <runtime>-declared.yaml document.

    The file is the subset the Java runner writes: a fixture path, then either
    ``case: { result: ..., reason: "..." }`` or a block ``result`` / ``reason``.
    """
    try:
        loaded = yaml.load(text, Loader=UniqueKeyLoader)
    except yaml.YAMLError as exc:
        raise CollectError(f"invalid declaration YAML: {exc}") from exc

    if loaded is None:
        return Declarations()

    if not isinstance(loaded, dict):
        raise CollectError("declaration file must be a map of fixture files")

    files: dict[str, dict[str, Declaration]] = {}
    for file_name, cases in loaded.items():
        if not isinstance(file_name, str) or not _valid_file_name(file_name):
            raise CollectError(f"invalid fixture file {file_name}")

        if not isinstance(cases, dict):
            raise CollectError(f"{file_name} must be a map of cases")

        file_cases: dict[str, Declaration] = {}
        for case_name, body in cases.items():
            if not isinstance(case_name, str) or not _valid_case_name(case_name):
                raise CollectError(f"{file_name}: invalid case {case_name}")

            if not isinstance(body, dict):
                raise CollectError(f"{file_name}:{case_name} must be a map")

            normalized: dict[str, str] = {}
            for key, value in body.items():
                if not isinstance(key, str):
                    raise CollectError(f"{file_name}:{case_name}: invalid key {key}")

                if not isinstance(value, str):
                    raise CollectError(f"{file_name}:{case_name}: {key} must be a string")

                normalized[key] = value

            if case_name in file_cases:
                raise CollectError(f"{file_name}:{case_name}: duplicate case")

            file_cases[case_name] = _declaration_from_body(file_name, case_name, normalized)

        files[file_name] = file_cases

    return Declarations(files)


def _require_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or value == "":
        raise CollectError(f"{label} must be a non-empty string")
    return value


def _require_count(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise CollectError(f"{label} must be a non-negative integer")
    return value


def load_report(data: Any, source: str) -> Report:
    if not isinstance(data, dict):
        raise CollectError(f"{source}: report must be a JSON object")

    extra = [key for key in data if key not in REPORT_KEYS]
    if extra:
        names = _listed(extra)
        raise CollectError(f"{source}: unknown report field {names}")

    missing = [key for key in REPORT_KEYS if key not in data]
    if missing:
        names = _listed(missing)
        raise CollectError(f"{source}: missing report field {names}")

    runtime = _require_text(data["runtime"], f"{source}: runtime")
    client_version = _require_text(data["clientVersion"], f"{source}: clientVersion")
    fixture_version = _require_text(data["fixtureSetVersion"], f"{source}: fixtureSetVersion")
    if not _semver(fixture_version):
        raise CollectError(f"{source}: fixtureSetVersion must be MAJOR.MINOR.PATCH")

    counts_raw = data["counts"]
    if not isinstance(counts_raw, dict):
        raise CollectError(f"{source}: counts must be an object")

    count_extra = [key for key in counts_raw if key not in COUNT_KEYS]
    if count_extra:
        names = _listed(count_extra)
        raise CollectError(f"{source}: unknown count {names}")

    counts = {}
    for name in RESULTS:
        counts[name] = _require_count(counts_raw.get(name), f"{source}: counts.{name}")

    rows_raw = data["rows"]
    if not isinstance(rows_raw, list):
        raise CollectError(f"{source}: rows must be an array")

    rows = []
    for index, row in enumerate(rows_raw):
        rows.append(_load_row(row, source, index))

    seen: set[tuple[str, str]] = set()
    for row in rows:
        identity = (row.file, row.case)
        if identity in seen:
            raise CollectError(f"{source}: duplicate row {row.file}:{row.case}")

        seen.add(identity)

    actual_counts = {name: 0 for name in RESULTS}
    for row in rows:
        actual_counts[row.result] += 1

    if actual_counts != counts:
        raise CollectError(f"{source}: counts {counts} do not match rows {actual_counts}")

    return Report(
        runtime=runtime,
        client_version=client_version,
        fixture_set_version=fixture_version,
        counts=counts,
        rows=rows,
        source=source,
    )


def _semver(value: str) -> bool:
    parts = value.split(".")
    if len(parts) != 3:
        return False
    for part in parts:
        if part == "" or not part.isdigit():
            return False
    return True


def _load_row(row: Any, source: str, index: int) -> ReportRow:
    label = f"{source}: rows[{index}]"
    if not isinstance(row, dict):
        raise CollectError(f"{label} must be an object")

    extra = [key for key in row if key not in ROW_KEYS]
    if extra:
        names = _listed(extra)
        raise CollectError(f"{label}: unknown field {names}")

    for key in ("file", "case", "result"):
        if key not in row:
            raise CollectError(f"{label}: missing {key}")

    file_name = _require_text(row["file"], f"{label}.file")
    if not _valid_file_name(file_name):
        raise CollectError(f"{label}: invalid file {file_name}")

    case_name = _require_text(row["case"], f"{label}.case")
    result = _require_text(row["result"], f"{label}.result")
    if result not in RESULTS:
        raise CollectError(f"{label}: invalid result {result}")

    reason = ""
    detail = ""
    if result in ("fail", "unsupported", "blocked") and "reason" not in row:
        raise CollectError(f"{label}: a {result} row needs a reason")

    if "reason" in row:
        reason = _require_text(row["reason"], f"{label}.reason")

    if "detail" in row:
        if not isinstance(row["detail"], str):
            raise CollectError(f"{label}: detail must be a string")

        detail = row["detail"]
    return ReportRow(
        file=file_name,
        case=case_name,
        result=result,
        reason=reason,
        detail=detail,
    )


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
        file_name = relative_path.as_posix()
        if not _valid_file_name(file_name):
            continue

        text = path.read_text(encoding="utf-8")
        try:
            loaded = yaml.load(text, Loader=UniqueKeyLoader)
        except (yaml.YAMLError, CollectError) as exc:
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

    for file_name, file_cases in declarations.files.items():
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
        identity = (row.file, row.case)
        reported.add(identity)
        if identity not in fixtures.cases:
            compared.append(
                ComparedRow(
                    runtime=report.runtime,
                    file=row.file,
                    case=row.case,
                    declared="-",
                    actual=row.result,
                    reason=f"not a case in fixture set {fixtures.version}",
                    kind="unknown-case",
                )
            )
            continue

        fixture_blocked = fixtures.cases[identity]
        declared = declarations.declared_result(row.file, row.case, fixture_blocked)
        kind = gate_kind(row.result, declared)
        if kind is None:
            kind = ""

        compared.append(
            ComparedRow(
                runtime=report.runtime,
                file=row.file,
                case=row.case,
                declared=declared,
                actual=row.result,
                reason=row.reason,
                kind=kind,
            )
        )

    for identity, fixture_blocked in fixtures.cases.items():
        if identity in reported:
            continue

        file_name, case_name = identity
        declared = declarations.declared_result(file_name, case_name, fixture_blocked)
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
        source = str(path)
        try:
            report = load_report(data, source)
        except CollectError as exc:
            message = str(exc)
            raise CollectError(message) from exc
        reports.append(report)

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
        declarations = parsed_declarations.get(report.runtime)
        if declarations is None:
            declarations = Declarations()

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


def render_markdown(result: Collection) -> str:
    count_rows = []
    for report in result.reports:
        gate = "ok"
        for item in result.findings:
            if item.runtime == report.runtime:
                gate = "fail"
        counts = report.counts

        count_rows.append(
            [
                report.runtime,
                report.client_version,
                report.fixture_set_version,
                str(counts["pass"]),
                str(counts["fail"]),
                str(counts["unsupported"]),
                str(counts["blocked"]),
                gate,
            ]
        )
    rendered_lines = [
        "## Conformance",
        "",
        _table(
            ["Runtime", "Client", "Fixture set", "Pass", "Fail", "Unsupported", "Blocked", "Gate"],
            count_rows,
        ),
        "",
    ]
    if result.findings:
        finding_rows = []
        for item in result.findings:
            finding_rows.append(
                [
                    item.runtime,
                    item.kind,
                    item.file,
                    item.case,
                    item.declared,
                    item.actual,
                    item.reason,
                ]
            )
        rendered_lines.extend(
            [
                "### Gate failures",
                "",
                "A pass that is now fail, an unsupported or blocked result that was not declared, "
                "a fixture case with no row, or a row that is not a fixture case.",
                "",
                _table(
                    ["Runtime", "Kind", "File", "Case", "Declared", "Actual", "Reason"],
                    finding_rows,
                ),
                "",
            ]
        )
    else:
        rendered_lines.extend(["Every fixture case has a row, and no row trips the gate.", ""])

    if result.unsupported:
        rows = []
        for item in result.unsupported:
            rows.append(
                [
                    item.runtime,
                    item.file,
                    item.case,
                    item.declared,
                    item.reason,
                ]
            )
        rendered_lines.extend(
            [
                "### Unsupported",
                "",
                "Declared unsupported is a result, not a skipped test. It does not fail this job.",
                "",
                _table(["Runtime", "File", "Case", "Declared", "Reason"], rows),
                "",
            ]
        )
    if result.failures:
        rows = []
        for item in result.failures:
            rows.append(
                [
                    item.runtime,
                    item.file,
                    item.case,
                    item.declared,
                    item.reason,
                ]
            )
        rendered_lines.extend(
            [
                "### Fail",
                "",
                _table(["Runtime", "File", "Case", "Declared", "Reason"], rows),
                "",
            ]
        )
    if result.differences:
        rows = []
        for item in result.differences:
            rows.append(
                [
                    item.runtime,
                    item.file,
                    item.case,
                    item.declared,
                    item.actual,
                    item.reason,
                ]
            )
        rendered_lines.extend(
            [
                "### Other declaration differences",
                "",
                "These do not fail this job. The runtime test compares every row with its declaration.",
                "",
                _table(["Runtime", "File", "Case", "Declared", "Actual", "Reason"], rows),
                "",
            ]
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
