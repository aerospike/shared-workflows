#!/usr/bin/env python3
"""Turn a Snyk container-test JSON report into a verdict and severity counts.

    ./summarize.py <snyk-report.json> --severity-threshold high

Kept separate from scan.sh so the part that decides PASS vs FAIL can be unit tested with
fixtures, without a network, a registry, or the Snyk CLI. scan.sh runs the scan; this reads
what it produced and emits GITHUB_OUTPUT lines.

Snyk writes either a single result object or, when a test covers more than one target, a JSON
array of them. Either way the vulnerabilities carry an `id` and a `severity`; findings are
counted by unique `id` per severity so that the same CVE reported down several dependency
paths counts once.
"""
import argparse
import json
import sys

# Low to high. A threshold blocks on its own level and everything above it.
SEVERITIES = ["low", "medium", "high", "critical"]


def results_of(report):
    """Snyk emits one object, or an array of them for a multi-target test."""
    if isinstance(report, list):
        return report
    return [report]


def counts_by_severity(report):
    """Unique vulnerability ids per severity across every result in the report."""
    seen = {}  # id -> severity, so a CVE on many paths counts once
    for result in results_of(report):
        for vuln in result.get("vulnerabilities") or []:
            vid = vuln.get("id")
            sev = vuln.get("severity")
            if sev not in SEVERITIES:
                continue
            key = vid or f"{vuln.get('packageName')}@{vuln.get('version')}:{sev}"
            seen[key] = sev
    counts = {sev: 0 for sev in SEVERITIES}
    for sev in seen.values():
        counts[sev] += 1
    return counts


def at_or_above(counts, threshold):
    """How many findings sit at the threshold severity or above it."""
    if threshold not in SEVERITIES:
        raise ValueError(f"unknown severity threshold: {threshold}")
    floor = SEVERITIES.index(threshold)
    return sum(counts[sev] for sev in SEVERITIES[floor:])


def summarize(report, threshold):
    counts = counts_by_severity(report)
    blocking = at_or_above(counts, threshold)
    return {
        "verdict": "FAIL" if blocking else "PASS",
        "critical": counts["critical"],
        "high": counts["high"],
        "medium": counts["medium"],
        "low": counts["low"],
        "total": sum(counts.values()),
        "blocking": blocking,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", help="Path to the Snyk JSON report")
    parser.add_argument("--severity-threshold", default="high", choices=SEVERITIES)
    args = parser.parse_args(argv)

    with open(args.report) as handle:
        report = json.load(handle)

    summary = summarize(report, args.severity_threshold)
    for key, value in summary.items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
