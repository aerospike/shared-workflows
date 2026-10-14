#!/usr/bin/env python3
"""Point a caller-named tag at a Docker tag the caller supplies.

JFrog CLI must already be configured. With no tag named, nothing is attached.
``--latest`` and ``--latest-slim`` are optional and off by default. Each one
writes that exact name onto ``--tag`` for ``--image``.

    recompute.py retag --repo R --tag 3.3.2 --floating-tags image:dev
    recompute.py retag --repo R --tag 3.3.2 --image I --latest
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
import urllib.parse

MANIFEST_ACCEPT = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
    ]
)


def quote(value):
    return urllib.parse.quote(value, safe="")


def jf_curl(method, path, headers=None, body=None):
    cmd = ["jf", "rt", "curl", "-X", method, path, "--silent"]
    for key, value in (headers or {}).items():
        cmd.extend(["-H", f"{key}: {value}"])
    tmp_name = ""
    if body is not None:
        handle = tempfile.NamedTemporaryFile(delete=False)
        handle.write(body)
        handle.close()
        tmp_name = handle.name
        cmd.extend(["--data-binary", f"@{tmp_name}"])
    try:
        proc = subprocess.run(cmd, check=False, capture_output=True)
    finally:
        if tmp_name:
            os.unlink(tmp_name)
    err = proc.stderr.decode("utf-8", "replace")
    return proc.returncode, proc.stdout, err


def load_json(raw):
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def manifest_type(raw):
    doc = load_json(raw)
    if not isinstance(doc, dict) or not raw.strip():
        return ""
    media = doc.get("mediaType") or ""
    if isinstance(media, str) and media:
        return media
    if "manifests" in doc:
        return "application/vnd.docker.distribution.manifest.list.v2+json"
    return "application/vnd.docker.distribution.manifest.v2+json"


def point_tag(repo, image, floating, version_tag):
    get_path = f"/api/docker/{quote(repo)}/v2/{quote(image)}/manifests/{quote(version_tag)}"
    status, stdout, err = jf_curl("GET", get_path, {"Accept": MANIFEST_ACCEPT})
    ctype = manifest_type(stdout) if status == 0 else ""
    if not ctype:
        detail = err.strip() or f"No manifest for {image}:{version_tag} in {repo}"
        raise SystemExit(detail)
    put_path = f"/api/docker/{quote(repo)}/v2/{quote(image)}/manifests/{quote(floating)}"
    status, _stdout, err = jf_curl("PUT", put_path, {"Content-Type": ctype}, stdout)
    if status != 0:
        raise SystemExit(err or f"failed to point {image}:{floating} at {version_tag}")
    print(f"Pointed {repo}/{image}:{floating} at {version_tag}")


def tag_pairs(floating_tags, image, apply_latest, apply_latest_slim):
    """One list of (image, name) pairs. latest and latest-slim come only from the flags."""
    pairs = []
    seen = set()

    def add(img, name):
        key = (img, name)
        if not img or not name or key in seen:
            return
        seen.add(key)
        pairs.append(key)

    for part in (floating_tags or "").split(";"):
        part = part.strip()
        if ":" not in part:
            continue
        img, name = (piece.strip() for piece in part.split(":", 1))
        if name in ("latest", "latest-slim"):
            continue
        add(img, name)
    if apply_latest or apply_latest_slim:
        if not image:
            raise SystemExit("--image is required")
        if apply_latest:
            add(image, "latest")
        if apply_latest_slim:
            add(image, "latest-slim")
    return pairs


def retag(repo, tag, pairs):
    """Point each pair at the Docker tag the caller supplied."""
    if not repo:
        raise SystemExit("--repo is required")
    if not tag:
        raise SystemExit("--tag is required")
    for image, name in pairs:
        point_tag(repo, image, name, tag)


def command_retag(args):
    pairs = tag_pairs(args.floating_tags or "", args.image or "", args.latest, args.latest_slim)
    if not pairs:
        print("No tag was named. Attaching nothing.")
        return
    retag(args.repo or "", args.tag or "", pairs)


def parser():
    top = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = top.add_subparsers(dest="command", required=True)

    retag_cmd = sub.add_parser("retag", help="point named tags at the Docker tag supplied with --tag")
    retag_cmd.add_argument("--repo", default="")
    retag_cmd.add_argument("--tag", default="")
    retag_cmd.add_argument("--image", default="")
    retag_cmd.add_argument("--floating-tags", default="")
    retag_cmd.add_argument("--latest", action="store_true")
    retag_cmd.add_argument("--latest-slim", action="store_true")
    retag_cmd.set_defaults(func=command_retag)
    return top


def main(argv=None):
    args = parser().parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
