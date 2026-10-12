#!/usr/bin/env python3
"""Refuse a Snyk CLI release younger than a minimum bake time.

    curl .../repos/snyk/cli/releases/tags/<tag> | ./verify_cli_age.py --min-age-hours 48

Enforces the "minimum 48h version" rule: a freshly published — possibly compromised — CLI is
never adopted on day zero. Reads the GitHub release JSON on stdin (or takes --published-at) and
compares the release's publish time against --min-age-hours. Kept out of the install step's
bash so the age arithmetic can be unit tested with a fixed --now, no network.

Exit codes let the install step react without parsing text:
  0  old enough  — prints the age in hours on stdout
  2  too new     — younger than the minimum bake (the install step hard-fails)
  3  unknown     — no publish time available (the install step warns and proceeds)
"""
import argparse
import datetime
import json
import sys


def parse_iso(text):
    """Parse an ISO-8601 timestamp (GitHub stamps e.g. 2024-01-01T12:00:00Z) as UTC-aware."""
    text = text.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed


def age_hours(published_at, now):
    """Whole hours between the publish time and now (floored, never negative-rounded up)."""
    return int((now - parse_iso(published_at)).total_seconds() // 3600)


def published_from_json(text):
    try:
        data = json.loads(text)
    except (ValueError, TypeError):
        return ""
    if isinstance(data, dict):
        return data.get("published_at") or ""
    return ""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--min-age-hours", type=int, default=48)
    parser.add_argument("--published-at", default="", help="Publish time; else read release JSON from stdin")
    parser.add_argument("--now", default="", help="ISO time to compare against (tests); defaults to real now")
    args = parser.parse_args(argv)

    published = args.published_at
    if not published:
        published = published_from_json(sys.stdin.read())
    if not published:
        print("unknown", file=sys.stderr)
        return 3

    now = parse_iso(args.now) if args.now else datetime.datetime.now(datetime.timezone.utc)
    hours = age_hours(published, now)
    print(hours)
    return 0 if hours >= args.min_age_hours else 2


if __name__ == "__main__":
    sys.exit(main())
