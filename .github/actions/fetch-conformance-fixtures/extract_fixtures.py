#!/usr/bin/env python3
"""Extract an aerospike-client-conformance release zip into a checkout-shaped directory."""

from __future__ import annotations

import argparse
import stat
import sys
import zipfile
from pathlib import Path


class ExtractError(Exception):
    """The zip is not a usable fixture release."""


def _relative_parts(name: str, prefix: str) -> list[str]:
    if name.startswith("/") or name.startswith("\\") or "\\" in name:
        raise ExtractError(f"unsafe zip entry: {name}")
    if not name.startswith(prefix):
        raise ExtractError(f"zip entry is outside {prefix}: {name}")
    relative = name[len(prefix) :]
    parts = [part for part in relative.split("/") if part != ""]
    for part in parts:
        if part in (".", ".."):
            raise ExtractError(f"unsafe zip entry: {name}")
    return parts


def _is_symlink(info: zipfile.ZipInfo) -> bool:
    mode = info.external_attr >> 16
    return stat.S_ISLNK(mode)


def extract_release_zip(zip_path: Path, dest: Path, package: str, version: str) -> None:
    prefix = f"{package}-{version}/"
    if dest.exists():
        entries = list(dest.iterdir())
        if entries:
            raise ExtractError(f"destination is not empty: {dest}")
    dest.mkdir(parents=True, exist_ok=True)
    dest_root = dest.resolve()

    with zipfile.ZipFile(zip_path) as archive:
        for info in archive.infolist():
            if _is_symlink(info):
                raise ExtractError(f"zip entry is a symlink: {info.filename}")
            parts = _relative_parts(info.filename, prefix)
            if not parts:
                continue
            target = dest.joinpath(*parts)
            target_root = target.resolve()
            if target_root != dest_root and dest_root not in target_root.parents:
                raise ExtractError(f"zip entry escapes destination: {info.filename}")
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            data = archive.read(info)
            target.write_bytes(data)

    version_path = dest / "VERSION"
    if not version_path.is_file():
        raise ExtractError("release zip has no VERSION file")
    found = version_path.read_text(encoding="utf-8").strip()
    if found != version:
        raise ExtractError(f"VERSION is {found}, expected {version}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zip", required=True, dest="zip_path")
    parser.add_argument("--dest", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args(argv)
    try:
        extract_release_zip(Path(args.zip_path), Path(args.dest), args.package, args.version)
    except (ExtractError, zipfile.BadZipFile, OSError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code)
