"""Tests for extracting a conformance release zip."""

from __future__ import annotations

import importlib.util
import shutil
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "extract_fixtures.py"


def load():
    spec = importlib.util.spec_from_file_location("extract_fixtures", SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {SCRIPT}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["extract_fixtures"] = mod
    spec.loader.exec_module(mod)
    return mod


extract = load()

PACKAGE = "aerospike-client-conformance"
version_text = (ROOT / "fixture-set-version").read_text(encoding="utf-8")
VERSION = version_text.strip()
PREFIX = f"{PACKAGE}-{VERSION}/"
OTHER_VERSION = "9.9.9"


def write_release(path: Path, entries: dict[str, bytes], links: list[str] | None = None) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        for name, payload in entries.items():
            archive.writestr(name, payload)
        for name in links or []:
            info = zipfile.ZipInfo(name)
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, b"elsewhere")


class ExtractFixturesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.work)

    def test_strips_the_release_prefix_and_checks_version(self) -> None:
        work = self.work
        zip_path = work / "release.zip"
        write_release(
            zip_path,
            {
                PREFIX: b"",
                PREFIX + "VERSION": f"{VERSION}\n".encode(),
                PREFIX + "schema/report.schema.json": b"{}",
                PREFIX + "discovery/translate/port-map.yaml": b"kind: translate\n",
            },
        )
        dest = work / "fixtures"
        extract.extract_release_zip(zip_path, dest, PACKAGE, VERSION)
        version = (dest / "VERSION").read_text(encoding="utf-8")
        self.assertEqual(version, f"{VERSION}\n")
        self.assertTrue((dest / "discovery/translate/port-map.yaml").is_file())
        self.assertFalse((dest / PREFIX.rstrip("/")).exists())

    def test_rejects_a_version_mismatch(self) -> None:
        work = self.work
        zip_path = work / "release.zip"
        write_release(zip_path, {PREFIX + "VERSION": f"{OTHER_VERSION}\n".encode()})
        with self.assertRaises(extract.ExtractError) as caught:
            extract.extract_release_zip(zip_path, work / "fixtures", PACKAGE, VERSION)
        self.assertIn(OTHER_VERSION, str(caught.exception))

    def test_rejects_path_traversal_and_symlinks(self) -> None:
        work = self.work
        traversal = work / "traversal.zip"
        write_release(traversal, {PREFIX + "../../outside": b"nope"})
        with self.assertRaises(extract.ExtractError):
            extract.extract_release_zip(traversal, work / "fixtures", PACKAGE, VERSION)

        linked = work / "linked.zip"
        write_release(linked, {PREFIX + "VERSION": f"{VERSION}\n".encode()}, links=[PREFIX + "link"])
        with self.assertRaises(extract.ExtractError):
            extract.extract_release_zip(linked, work / "linked-dest", PACKAGE, VERSION)


if __name__ == "__main__":
    unittest.main()
