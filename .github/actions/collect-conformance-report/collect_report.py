#!/usr/bin/env python3
"""Aggregate conformance-report.json files into a job summary.

Gate, from CLIENT-5546:

- fail when a row declared pass (or omitted, which means pass) actually failed
- fail when a row is unsupported and that unsupported result is not declared
- do not fail when unsupported was declared, or when a declared fail still fails

A row with no declaration is pass, except an actual blocked result: blocked is
copied from the fixture, and the Java runner treats an omitted blocked row as
declared blocked. See aerospike-client-conformance schema/report.schema.json
and <runtime>-declared.yaml (client repos, for example java-declared.yaml).
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

RESULTS = ("pass", "fail", "unsupported", "blocked")
REPORT_KEYS = {"runtime", "clientVersion", "fixtureSetVersion", "counts", "rows"}
ROW_KEYS = {"file", "case", "result", "reason", "detail"}
COUNT_KEYS = {"pass", "fail", "unsupported", "blocked"}
FILE_PATTERN_PART = "abcdefghijklmnopqrstuvwxyz0123456789-"


class CollectError(Exception):
    """A report or declaration cannot be aggregated."""


def _listed(values: list[str]) -> str:
    ordered = sorted(values)
    return ", ".join(ordered)


def _is_comment(stripped: str) -> bool:
    return stripped.startswith("#")


def _unquote(raw: str) -> str:
    if len(raw) < 2 or not raw.startswith('"') or not raw.endswith('"'):
        raise CollectError(f"expected a quoted string, got: {raw}")
    inner = raw[1:-1]
    chars: list[str] = []
    escaped = False
    for char in inner:
        if escaped:
            mapping = {'"': '"', "\\": "\\", "n": "\n", "t": "\t"}
            if char not in mapping:
                raise CollectError(f"unknown escape \\{char} in {raw}")
            chars.append(mapping[char])
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        chars.append(char)
    if escaped:
        raise CollectError(f"truncated escape in {raw}")
    return "".join(chars)


def _scalar(raw: str) -> str:
    value = raw.strip()
    if value.startswith('"'):
        return _unquote(value)
    if value.startswith("'") and value.endswith("'") and len(value) >= 2:
        return value[1:-1]
    return value


def _split_flow(body: str) -> list[str]:
    parts: list[str] = []
    buf: list[str] = []
    in_quotes = False
    escaped = False
    for char in body:
        if escaped:
            buf.append(char)
            escaped = False
            continue
        if char == "\\" and in_quotes:
            buf.append(char)
            escaped = True
            continue
        if char == '"':
            in_quotes = not in_quotes
            buf.append(char)
            continue
        if char == "," and not in_quotes:
            parts.append("".join(buf).strip())
            buf = []
            continue
        buf.append(char)
    if in_quotes or escaped:
        raise CollectError(f"unterminated string in {{{body}}}")
    tail = "".join(buf).strip()
    if tail:
        parts.append(tail)
    return parts


def _parse_flow(body: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for part in _split_flow(body):
        if ":" not in part:
            raise CollectError(f"declaration entry needs a key: {part}")
        key, raw_value = part.split(":", 1)
        name = key.strip()
        if name in parsed:
            raise CollectError(f"duplicate declaration key {name}")
        parsed[name] = _scalar(raw_value)
    return parsed


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


def _store_declaration(
    files: dict[str, dict[str, dict[str, str | None]]],
    file_name: str,
    case_name: str,
    body: dict[str, str],
) -> None:
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
    cases = files[file_name]
    if case_name in cases:
        raise CollectError(f"{file_name}:{case_name}: duplicate case")
    cases[case_name] = {"result": result, "reason": reason}


def parse_declarations(text: str) -> dict[str, dict[str, dict[str, str | None]]]:
    """Parse a <runtime>-declared.yaml document.

    The file is the subset the Java runner writes: a fixture path, then either
    ``case: { result: ..., reason: "..." }`` or a block ``result`` / ``reason``.
    """
    files: dict[str, dict[str, dict[str, str | None]]] = {}
    current_file: str | None = None
    current_case: str | None = None
    current_body: dict[str, str] | None = None

    def commit() -> None:
        nonlocal current_case, current_body
        if current_case is None:
            return
        if current_file is None or current_body is None:
            raise CollectError("declaration case has no fixture file")
        _store_declaration(files, current_file, current_case, current_body)
        current_case = None
        current_body = None

    for line_no, raw in enumerate(text.splitlines(), 1):
        if "\t" in raw:
            raise CollectError(f"line {line_no}: tabs are not allowed")
        stripped = raw.strip()
        if stripped == "" or _is_comment(stripped):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if indent == 0:
            commit()
            if not stripped.endswith(":"):
                raise CollectError(f"line {line_no}: expected a fixture file, got: {stripped}")
            file_name = stripped[:-1].strip()
            if not _valid_file_name(file_name):
                raise CollectError(f"line {line_no}: invalid fixture file {file_name}")
            if file_name in files:
                raise CollectError(f"line {line_no}: duplicate fixture file {file_name}")
            files[file_name] = {}
            current_file = file_name
            continue
        if current_file is None:
            raise CollectError(f"line {line_no}: case is outside a fixture file")
        if indent == 2 and ": {" in stripped and stripped.endswith("}"):
            commit()
            case_name, flow = stripped.split(": {", 1)
            case_name = case_name.strip()
            if not _valid_case_name(case_name):
                raise CollectError(f"line {line_no}: invalid case {case_name}")
            flow_body = flow[:-1]
            current_case = case_name
            current_body = _parse_flow(flow_body)
            commit()
            continue
        if indent == 2 and stripped.endswith(":"):
            commit()
            case_name = stripped[:-1].strip()
            if not _valid_case_name(case_name):
                raise CollectError(f"line {line_no}: invalid case {case_name}")
            current_case = case_name
            current_body = {}
            continue
        if indent == 4 and current_case is not None and current_body is not None:
            if ":" not in stripped:
                raise CollectError(f"line {line_no}: expected result or reason")
            key, raw_value = stripped.split(":", 1)
            name = key.strip()
            if name in current_body:
                raise CollectError(f"line {line_no}: duplicate key {name}")
            current_body[name] = _scalar(raw_value)
            continue
        raise CollectError(f"line {line_no}: unexpected declaration line: {stripped}")

    commit()
    return files


def _require_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or value == "":
        raise CollectError(f"{label} must be a non-empty string")
    return value


def _require_count(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise CollectError(f"{label} must be a non-negative integer")
    return value


def load_report(data: Any, source: str) -> dict[str, Any]:
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
    counts = {name: _require_count(counts_raw.get(name), f"{source}: counts.{name}") for name in RESULTS}

    rows_raw = data["rows"]
    if not isinstance(rows_raw, list):
        raise CollectError(f"{source}: rows must be an array")
    rows = [_load_row(row, source, index) for index, row in enumerate(rows_raw)]
    seen: set[tuple[str, str]] = set()
    for row in rows:
        identity = (row["file"], row["case"])
        if identity in seen:
            raise CollectError(f"{source}: duplicate row {row['file']}:{row['case']}")
        seen.add(identity)

    actual_counts = {name: 0 for name in RESULTS}
    for row in rows:
        actual_counts[row["result"]] += 1
    if actual_counts != counts:
        raise CollectError(f"{source}: counts {counts} do not match rows {actual_counts}")

    return {
        "runtime": runtime,
        "clientVersion": client_version,
        "fixtureSetVersion": fixture_version,
        "counts": counts,
        "rows": rows,
        "source": source,
    }


def _semver(value: str) -> bool:
    parts = value.split(".")
    if len(parts) != 3:
        return False
    for part in parts:
        if part == "" or not part.isdigit():
            return False
    return True


def _load_row(row: Any, source: str, index: int) -> dict[str, str]:
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
    loaded = {"file": file_name, "case": case_name, "result": result}
    if result in ("fail", "unsupported", "blocked"):
        if "reason" not in row:
            raise CollectError(f"{label}: a {result} row needs a reason")
        loaded["reason"] = _require_text(row["reason"], f"{label}.reason")
    elif "reason" in row:
        loaded["reason"] = _require_text(row["reason"], f"{label}.reason")
    if "detail" in row:
        if not isinstance(row["detail"], str):
            raise CollectError(f"{label}: detail must be a string")
        loaded["detail"] = row["detail"]
    return loaded


def declared_result(
    declarations: dict[str, dict[str, dict[str, str | None]]],
    file_name: str,
    case_name: str,
    actual: str,
) -> str:
    file_rows = declarations.get(file_name)
    if file_rows is None or case_name not in file_rows:
        if actual == "blocked":
            return "blocked"
        return "pass"
    return str(file_rows[case_name]["result"])


def gate_kind(actual: str, declared: str) -> str | None:
    if actual == "fail" and declared == "pass":
        return "pass-to-fail"
    if actual == "unsupported" and declared != "unsupported":
        return "undeclared-unsupported"
    return None


def _cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def _table(headers: list[str], rows: list[list[str]]) -> str:
    head = "| " + " | ".join(headers) + " |"
    sep = "| " + " | ".join("---" for _ in headers) + " |"
    body = ["| " + " | ".join(_cell(cell) for cell in row) + " |" for row in rows]
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


def collect(
    reports_dir: Path,
    declarations_dir: Path | None = None,
    fixture_set_version: str = "",
) -> dict[str, Any]:
    report_paths = find_reports(reports_dir)
    if not report_paths:
        raise CollectError(f"no conformance-report.json under {reports_dir}")

    declaration_paths: dict[str, Path] = {}
    if declarations_dir is not None:
        declaration_paths = find_declarations(declarations_dir)

    parsed_declarations: dict[str, dict[str, dict[str, dict[str, str | None]]]] = {}
    for runtime, path in declaration_paths.items():
        text = path.read_text(encoding="utf-8")
        try:
            parsed_declarations[runtime] = parse_declarations(text)
        except CollectError as exc:
            raise CollectError(f"{path}: {exc}") from exc

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

    runtimes = [report["runtime"] for report in reports]
    unique_runtimes = set(runtimes)
    if len(runtimes) != len(unique_runtimes):
        joined_runtimes = ", ".join(runtimes)
        raise CollectError(f"duplicate runtime in reports: {joined_runtimes}")

    versions = {report["fixtureSetVersion"] for report in reports}
    if len(versions) != 1:
        version_list = list(versions)
        joined = _listed(version_list)
        raise CollectError(f"reports disagree on fixtureSetVersion: {joined}")
    found_version = ""
    for version in versions:
        found_version = version
    if fixture_set_version and found_version != fixture_set_version:
        raise CollectError(
            f"fixture set {found_version} does not match requested {fixture_set_version}"
        )

    findings = []
    differences = []
    unsupported_rows = []
    fail_rows = []
    for report in reports:
        runtime = report["runtime"]
        declarations = parsed_declarations.get(runtime, {})
        for row in report["rows"]:
            declared = declared_result(declarations, row["file"], row["case"], row["result"])
            reason = row.get("reason", "")
            record = {
                "runtime": runtime,
                "file": row["file"],
                "case": row["case"],
                "declared": declared,
                "actual": row["result"],
                "reason": reason,
            }
            kind = gate_kind(row["result"], declared)
            if kind is not None:
                record["kind"] = kind
                findings.append(record)
            elif declared != row["result"]:
                differences.append(record)
            if row["result"] == "unsupported":
                unsupported_rows.append(record)
            if row["result"] == "fail":
                fail_rows.append(record)

    return {
        "reports": reports,
        "findings": findings,
        "differences": differences,
        "unsupported": unsupported_rows,
        "failures": fail_rows,
        "fixtureSetVersion": found_version,
        "failed": bool(findings),
    }


def render_markdown(result: dict[str, Any]) -> str:
    count_rows = []
    for report in result["reports"]:
        counts = report["counts"]
        gate = "ok"
        for item in result["findings"]:
            if item["runtime"] == report["runtime"]:
                gate = "fail"
        count_rows.append(
            [
                report["runtime"],
                report["clientVersion"],
                report["fixtureSetVersion"],
                str(counts["pass"]),
                str(counts["fail"]),
                str(counts["unsupported"]),
                str(counts["blocked"]),
                gate,
            ]
        )
    sections = [
        "## Conformance",
        "",
        _table(
            ["Runtime", "Client", "Fixture set", "Pass", "Fail", "Unsupported", "Blocked", "Gate"],
            count_rows,
        ),
        "",
    ]
    if result["findings"]:
        finding_rows = [
            [item["runtime"], item["kind"], item["file"], item["case"], item["declared"], item["actual"], item["reason"]]
            for item in result["findings"]
        ]
        sections.extend(
            [
                "### Gate failures",
                "",
                "A pass that is now fail, or an unsupported result that was not declared.",
                "",
                _table(
                    ["Runtime", "Kind", "File", "Case", "Declared", "Actual", "Reason"],
                    finding_rows,
                ),
                "",
            ]
        )
    else:
        sections.extend(["No pass-to-fail regression and no undeclared unsupported result.", ""])

    if result["unsupported"]:
        rows = [
            [item["runtime"], item["file"], item["case"], item["declared"], item["reason"]]
            for item in result["unsupported"]
        ]
        sections.extend(
            [
                "### Unsupported",
                "",
                "Declared unsupported is a result, not a skipped test. It does not fail this job.",
                "",
                _table(["Runtime", "File", "Case", "Declared", "Reason"], rows),
                "",
            ]
        )
    if result["failures"]:
        rows = [
            [item["runtime"], item["file"], item["case"], item["declared"], item["reason"]]
            for item in result["failures"]
        ]
        sections.extend(
            [
                "### Fail",
                "",
                _table(["Runtime", "File", "Case", "Declared", "Reason"], rows),
                "",
            ]
        )
    if result["differences"]:
        rows = [
            [item["runtime"], item["file"], item["case"], item["declared"], item["actual"], item["reason"]]
            for item in result["differences"]
        ]
        sections.extend(
            [
                "### Other declaration differences",
                "",
                "These do not fail this job. The runtime test compares every row with its declaration.",
                "",
                _table(["Runtime", "File", "Case", "Declared", "Actual", "Reason"], rows),
                "",
            ]
        )
    return "\n".join(sections).rstrip() + "\n"


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
    declarations_raw = os.environ.get("DECLARATIONS_DIRECTORY", "")
    declarations_dir = None
    if declarations_raw:
        declarations_dir = Path(declarations_raw)
    fixture_set_version = os.environ.get("FIXTURE_SET_VERSION", "")
    reports_dir = Path(reports_raw)
    try:
        result = collect(reports_dir, declarations_dir, fixture_set_version)
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
    gate = "failure" if result["failed"] else "success"
    _write_output("gate", gate)
    if result["failed"]:
        return 1
    return 0


if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code)
