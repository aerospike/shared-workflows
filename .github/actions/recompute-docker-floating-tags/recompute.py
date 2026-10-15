#!/usr/bin/env python3
"""Point a caller-named tag at a Docker tag the caller supplies.

JFrog CLI must already be configured. With no tag named, nothing is attached.
``--latest`` and ``--latest-slim`` are optional and off by default. Each one
writes that exact name onto ``--tag`` for ``--image``.

    recompute.py retag --repo R --tag 3.3.2 --floating-tags image:dev
    recompute.py retag --repo R --tag 3.3.2 --image I --latest
    recompute.py from-promotion --project P --bundle-name B --version V --environment STAGE
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tempfile
import urllib.parse

IMMUTABLE_TAG = re.compile(r"^(.+)_[0-9]{8}T[0-9]{6}Z$")

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


def is_missing(status, stdout, err):
    if status == 0:
        return False
    blob = (err or "") + stdout.decode("utf-8", "replace")
    return "404" in blob or "not found" in blob.lower()


def get_json(path, missing_ok=False):
    status, stdout, err = jf_curl("GET", path)
    if status != 0:
        if missing_ok and is_missing(status, stdout, err):
            return None
        detail = (err or "").strip() or stdout.decode("utf-8", "replace").strip()
        raise SystemExit(detail or f"GET {path} failed")
    if not stdout.strip():
        return None
    parsed = load_json(stdout)
    if parsed is None:
        raise SystemExit(f"GET {path} did not return JSON")
    return parsed


def add_build(found, name, number):
    if not name or number is None or number == "":
        return
    pair = (str(name), str(number))
    if pair not in found:
        found.append(pair)


def builds_from_record(record):
    found = []
    if not isinstance(record, dict):
        return found
    for item in record.get("builds") or []:
        if isinstance(item, dict):
            add_build(
                found,
                item.get("buildName") or item.get("build_name") or item.get("name"),
                item.get("buildNumber") or item.get("build_number") or item.get("number"),
            )
    for art in record.get("artifacts") or []:
        if isinstance(art, dict):
            add_build(
                found,
                art.get("build_name") or art.get("buildName"),
                art.get("build_number") or art.get("buildNumber"),
            )
    return found


def builds_from_evidence(doc):
    found = []
    if not isinstance(doc, dict):
        return found
    predicate = doc.get("predicate") if isinstance(doc.get("predicate"), dict) else doc
    sources = predicate.get("sources") if isinstance(predicate, dict) else None
    for source in sources or []:
        if not isinstance(source, dict):
            continue
        for build in source.get("builds") or []:
            if isinstance(build, dict):
                add_build(
                    found,
                    build.get("buildName") or build.get("build_name"),
                    build.get("buildNumber") or build.get("build_number"),
                )
    return found


def property_text(value):
    if isinstance(value, str) and value.strip():
        return value.strip()
    if isinstance(value, list):
        parts = [str(item).strip() for item in value if str(item).strip()]
        return ";".join(parts)
    return ""


def floating_from_build(doc):
    if not isinstance(doc, dict):
        return ""
    info = doc.get("buildInfo") if isinstance(doc.get("buildInfo"), dict) else doc
    props = info.get("properties") if isinstance(info, dict) else None
    keys = ("buildInfo.env.DOCKER_FLOATING_TAGS", "docker.floating_tags")
    if isinstance(props, dict):
        for key in keys:
            text = property_text(props.get(key))
            if text:
                return text
    if isinstance(props, list):
        for item in props:
            if isinstance(item, dict) and item.get("key") in keys:
                text = property_text(item.get("values") or item.get("value"))
                if text:
                    return text
    return ""


def named_latest(value):
    """Map an image to the exact names latest and latest-slim recorded for it."""
    found = {}
    for part in (value or "").split(";"):
        part = part.strip()
        if ":" not in part:
            continue
        image, name = (piece.strip() for piece in part.split(":", 1))
        if name not in ("latest", "latest-slim") or not image:
            continue
        found.setdefault(image, set()).add(name)
    return found


def mutable_docker_tag(versions):
    """The version that remains after stripping the immutable timestamp."""
    present = set(versions)
    stripped = []
    for version in versions:
        match = IMMUTABLE_TAG.match(version)
        if match:
            stripped.append(match.group(1))
    for name in stripped:
        if name in present:
            return name
    return stripped[0] if stripped else ""


def image_mutable_tags(artifacts):
    by_image = {}
    for art in artifacts or []:
        if not isinstance(art, dict):
            continue
        if str(art.get("package_type") or "").lower() not in ("docker", "oci"):
            continue
        name = art.get("package_name") or ""
        version = str(art.get("package_version") or "")
        if not name or not version:
            continue
        if version.startswith("sha256:") or version.startswith("sha256__"):
            continue
        if version == "latest" or version.startswith("latest-"):
            continue
        by_image.setdefault(name, []).append(version)
    tags = {}
    for name, versions in by_image.items():
        tag = mutable_docker_tag(versions)
        if tag:
            tags[name] = tag
    return tags


def stage_or_prod_repos(catalog, environment):
    """Docker and OCI local repos for this environment that are stage or production."""
    env = (environment or "").upper()
    found = []
    for item in catalog if isinstance(catalog, list) else []:
        if not isinstance(item, dict):
            continue
        package = str(item.get("packageType") or item.get("package_type") or "").lower()
        if package not in ("docker", "oci"):
            continue
        if str(item.get("type") or "local").lower() == "virtual":
            continue
        envs = [str(entry).upper() for entry in item.get("environments") or []]
        if env not in envs:
            continue
        key = item.get("key") or item.get("repo") or ""
        if not key or key in found:
            continue
        if env != "PROD" and "-stage-" not in key:
            continue
        found.append(key)
    return found


def bundle_builds(project, bundle_name, version, record):
    found = builds_from_record(record)
    if found:
        return found
    repo = f"{project}-release-bundles-v2"
    path = f"/{quote(repo)}/{quote(bundle_name)}/{quote(version)}/release-bundle.json.evd"
    return builds_from_evidence(get_json(path, missing_ok=True))


def floating_value(project, builds):
    parts = []
    for name, number in builds:
        path = f"/api/build/{quote(name)}/{quote(number)}?project={quote(project)}"
        text = floating_from_build(get_json(path, missing_ok=True))
        if text:
            parts.append(text)
    return ";".join(parts)


def from_promotion(project, bundle_name, version, environment):
    """Point latest tags after promote when both gates pass.

    Gate 1: the included build recorded latest or latest-slim from versions-override.
    Gate 2: the destination is a stage repository, or environment is PROD.
    The image and the mutable Docker tag come from the release-bundle record.
    """
    if not project or not bundle_name or not version or not environment:
        raise SystemExit("--project, --bundle-name, --version, and --environment are required")
    record_path = (
        f"/lifecycle/api/v2/release_bundle/records/{quote(bundle_name)}/{quote(version)}"
        f"?project={quote(project)}"
    )
    record = get_json(record_path)
    if not isinstance(record, dict):
        print("No release bundle record. Not applying latest.")
        return
    wanted = named_latest(floating_value(project, bundle_builds(project, bundle_name, version, record)))
    if not wanted:
        print("versions-override did not name latest. Not applying latest.")
        return
    repos = stage_or_prod_repos(get_json(f"/api/repositories?project={quote(project)}"), environment)
    if not repos:
        print("Not a stage repository or a production promotion. Not applying latest.")
        return
    tags = image_mutable_tags(record.get("artifacts") or [])
    applied = False
    for repo in repos:
        for image, names in wanted.items():
            tag = tags.get(image) or ""
            if not tag:
                print(f"No mutable tag for {image} in the bundle. Skipping {repo}.")
                continue
            pairs = [(image, name) for name in ("latest", "latest-slim") if name in names]
            retag(repo, tag, pairs)
            applied = True
    if not applied:
        print("Not applying latest.")


def command_from_promotion(args):
    from_promotion(args.project or "", args.bundle_name or "", args.version or "", args.environment or "")


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

    promote_cmd = sub.add_parser(
        "from-promotion",
        help="point latest tags after promote when versions-override named them and the destination is stage or production",
    )
    promote_cmd.add_argument("--project", default="")
    promote_cmd.add_argument("--bundle-name", default="")
    promote_cmd.add_argument("--version", default="")
    promote_cmd.add_argument("--environment", default="")
    promote_cmd.set_defaults(func=command_from_promotion)
    return top


def main(argv=None):
    args = parser().parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
