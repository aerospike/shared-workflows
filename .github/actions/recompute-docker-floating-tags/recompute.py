#!/usr/bin/env python3
"""Point a caller-named tag at a Docker tag the caller supplies.

JFrog CLI must already be configured. With no tag named, nothing is attached.
``--latest`` and ``--latest-slim`` are optional and off by default. Each one
writes that exact name onto ``--tag`` (for example ``3.3.2``).

    recompute.py retag --project P --repo R --bundle-name N --version V --tag 3.3.2 --floating-tags image:dev
    recompute.py retag --project P --repo R --bundle-name N --version V --tag 3.3.2 --image I --latest
    recompute.py print-property --project P --bundle-name N --version V
    recompute.py property < record.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
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


def property_pieces(value):
    if isinstance(value, str):
        raw = value.split(";")
    elif isinstance(value, list):
        raw = []
        for item in value:
            if isinstance(item, str):
                raw.extend(item.split(";"))
    else:
        return []
    return [part.strip() for part in raw if part.strip()]


def pieces_from_props(props):
    if isinstance(props, dict):
        return property_pieces(props.get("docker.floating_tags"))
    if isinstance(props, list):
        found = []
        for item in props:
            if not isinstance(item, dict) or item.get("key") != "docker.floating_tags":
                continue
            values = item.get("values")
            if values is None and "value" in item:
                values = [item.get("value")]
            found.extend(property_pieces(values))
        return found
    return []


def floating_tags_value(doc):
    if not isinstance(doc, dict):
        return ""
    build_info = doc.get("buildInfo") if isinstance(doc.get("buildInfo"), dict) else {}
    pieces = pieces_from_props(doc.get("properties")) + pieces_from_props(build_info.get("properties"))
    return ";".join(sorted(set(pieces)))


def parse_pairs(value):
    images = []
    by_image = {}
    for part in value.split(";"):
        part = part.strip()
        if ":" not in part:
            continue
        image, floating = part.split(":", 1)
        image, floating = image.strip(), floating.strip()
        if not image or not floating:
            continue
        if image not in by_image:
            images.append(image)
            by_image[image] = []
        if floating not in by_image[image]:
            by_image[image].append(floating)
    return images, by_image


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


def missing(status, stdout, err):
    if status == 0:
        return False
    blob = err + stdout.decode("utf-8", "replace")
    return "404" in blob or "not found" in blob.lower()


def load_json(raw):
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def fetch_floating_tags(project, bundle_name, version):
    repo = quote(f"{project}-release-bundles-v2")
    name = quote(bundle_name)
    ver = quote(version)
    project_q = quote(project)
    paths = [
        f"/api/storage/{repo}/{name}/{ver}/release-bundle.json.evd?properties",
        f"/lifecycle/api/v2/release_bundle/records/{name}/{ver}?project={project_q}",
    ]
    for path in paths:
        status, stdout, err = jf_curl("GET", path, {"Accept": "application/json"})
        if status != 0:
            if missing(status, stdout, err):
                continue
            raise SystemExit(err or f"jf rt curl failed ({status}) for {path}")
        doc = load_json(stdout)
        if doc is None:
            continue
        value = floating_tags_value(doc)
        if value:
            return value
    return ""


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


def retag(repo, tag, floating_tags):
    """Point each named tag at the Docker tag the caller supplied."""
    if not repo:
        raise SystemExit("--repo is required")
    if not tag:
        raise SystemExit("--tag is required")
    if not floating_tags:
        print("No tag was named. Attaching nothing.")
        return
    images, by_image = parse_pairs(floating_tags)
    for image in images:
        for name in by_image[image]:
            point_tag(repo, image, name, tag)


def read_json():
    try:
        return json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON: {exc}") from exc


def command_property(_args):
    value = floating_tags_value(read_json())
    if value:
        print(value)


def command_print_property(args):
    value = fetch_floating_tags(args.project, args.bundle_name, args.version)
    if value:
        print(value)


def named_tags(value, apply_latest, apply_latest_slim, image_names):
    """Caller-typed tags, plus latest and latest-slim only when those options are on."""
    images, by_image = parse_pairs(value)
    kept_images = []
    kept = {}
    for image in images:
        tags = [tag for tag in by_image[image] if tag not in ("latest", "latest-slim")]
        if not tags:
            continue
        kept_images.append(image)
        kept[image] = tags
    if apply_latest or apply_latest_slim:
        names = list(kept_images)
        for image in image_names:
            if image not in names:
                names.append(image)
        for image in names:
            if image not in kept:
                kept_images.append(image)
                kept[image] = []
            if apply_latest and "latest" not in kept[image]:
                kept[image].append("latest")
            if apply_latest_slim and "latest-slim" not in kept[image]:
                kept[image].append("latest-slim")
    parts = [f"{image}:{tag}" for image in kept_images for tag in kept[image]]
    return ";".join(parts)


def command_retag(args):
    typed_images, _typed = parse_pairs(args.floating_tags or "")
    image_names = list(typed_images)
    if args.image and args.image not in image_names:
        image_names.append(args.image)
    if (args.latest or args.latest_slim) and not image_names:
        recorded = fetch_floating_tags(args.project, args.bundle_name, args.version)
        image_names, _recorded = parse_pairs(recorded)
    value = named_tags(args.floating_tags or "", args.latest, args.latest_slim, image_names)
    if not value:
        print("No tag was named. Attaching nothing.")
        return
    if not args.tag:
        raise SystemExit("--tag is required")
    retag(args.repo or "", args.tag, value)


def parser():
    top = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = top.add_subparsers(dest="command", required=True)

    retag_cmd = sub.add_parser("retag", help="point named tags at the Docker tag supplied with --tag")
    for flag in ("--project", "--bundle-name", "--version"):
        retag_cmd.add_argument(flag, required=True)
    retag_cmd.add_argument("--repo", default="")
    retag_cmd.add_argument("--tag", default="")
    retag_cmd.add_argument("--image", default="")
    retag_cmd.add_argument("--floating-tags", default="")
    retag_cmd.add_argument("--latest", action="store_true")
    retag_cmd.add_argument("--latest-slim", action="store_true")
    retag_cmd.set_defaults(func=command_retag)

    show = sub.add_parser("print-property", help="print docker.floating_tags from the release bundle")
    for flag in ("--project", "--bundle-name", "--version"):
        show.add_argument(flag, required=True)
    show.set_defaults(func=command_print_property)

    prop = sub.add_parser("property", help="print docker.floating_tags from a JSON document on stdin")
    prop.set_defaults(func=command_property)
    return top


def main(argv=None):
    args = parser().parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
