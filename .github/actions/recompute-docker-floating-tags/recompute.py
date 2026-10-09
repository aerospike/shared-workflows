#!/usr/bin/env python3
"""Point latest and latest-* at the highest version tag in one stage repository.

JFrog CLI must already be configured. The composite action calls ``retag``.
The other commands are for a promotion step or a one-off run:

    recompute.py retag --project P --repo R --bundle-name N --version V
    recompute.py print-property --project P --bundle-name N --version V
    recompute.py select --request latest --tag 3.3.2 --tag 3.3.1
    recompute.py repos --environment PROD --version 3.3.2 < promotion.json
    recompute.py property < record.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse

IMMUTABLE = re.compile(r"_[0-9]{8}T[0-9]{6}Z$")
PLAIN_VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+)+$")
SLIM_VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+)+-slim$")
MANIFEST_ACCEPT = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
    ]
)
SOURCE_FIELDS = (
    "source_repository_key",
    "sourceRepositoryKey",
    "source_repository",
    "source_repo",
    "source",
)
TARGET_FIELDS = (
    "target_repository_key",
    "targetRepositoryKey",
    "target_repository",
    "target_repo",
    "target",
)


def quote(value):
    return urllib.parse.quote(value, safe="")


def version_parts(text):
    return [int(part) for part in text.split(".")]


def newer(left, right):
    """Dotted numeric compare. Missing components count as 0, so 3.3 == 3.3.0."""
    a = version_parts(left)
    b = version_parts(right)
    width = max(len(a), len(b))
    a.extend([0] * (width - len(a)))
    b.extend([0] * (width - len(b)))
    return a > b


def ignored_tag(tag):
    if tag.startswith(("sha256:", "sha256__")) or tag == "latest" or tag.startswith("latest-"):
        return True
    return IMMUTABLE.search(tag) is not None


def choose(requests, tags):
    """Pick a version tag for each floating tag, or mark it for removal.

    ``latest`` uses tags that do not end in ``-slim``. ``latest-slim`` uses tags
    that do, compared after the suffix is removed. Equal versions keep the first.
    """
    best_plain = ""
    best_slim = ""
    best_slim_ver = ""
    for tag in tags:
        if ignored_tag(tag):
            continue
        if PLAIN_VERSION.match(tag):
            if not best_plain or newer(tag, best_plain):
                best_plain = tag
        elif SLIM_VERSION.match(tag):
            ver = tag[: -len("-slim")]
            if not best_slim or newer(ver, best_slim_ver):
                best_slim = tag
                best_slim_ver = ver

    decisions = []
    seen = set()
    for req in requests:
        if req in seen:
            continue
        seen.add(req)
        if req == "latest":
            decisions.append(("set", req, best_plain) if best_plain else ("delete", req, ""))
        elif req == "latest-slim":
            decisions.append(("set", req, best_slim) if best_slim else ("delete", req, ""))
        else:
            raise SystemExit(f"unsupported floating tag: {req}")
    return decisions


def first_text(obj, names):
    for name in names:
        value = obj.get(name)
        if isinstance(value, str) and value:
            return value
    return ""


def docker_target(obj):
    source = first_text(obj, SOURCE_FIELDS)
    target = first_text(obj, TARGET_FIELDS)
    package = obj.get("package_type") or obj.get("packageType") or ""
    blob = f"{source} {target}"
    named = package in ("docker", "oci") or "-docker-" in blob or "-oci-" in blob
    return target if named else ""


def walk(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item)


def catalog_repos(items, environment):
    wanted = environment.upper()
    found = []
    for item in items:
        if not isinstance(item, dict):
            continue
        package = str(item.get("packageType") or item.get("package_type") or "").lower()
        if package not in ("docker", "oci"):
            continue
        envs = [str(env).upper() for env in item.get("environments") or []]
        if wanted not in envs:
            continue
        if str(item.get("type") or "local").lower() == "virtual":
            continue
        key = item.get("key") or item.get("repo") or ""
        if key and key not in found:
            found.append(key)
    return sorted(found)


def promotion_matches(promo, environment, version):
    got = promo.get("release_bundle_version") or promo.get("releaseBundleVersion") or promo.get("version") or ""
    if got and got != version:
        return False
    if (promo.get("status") or "COMPLETED") != "COMPLETED":
        return False
    env = promo.get("environment") or promo.get("target_environment") or promo.get("targetEnvironment") or ""
    return env == environment


def mapping_nodes(promo):
    mappings = promo.get("repository_mapping") or promo.get("repositoryMapping") or promo.get("mappings") or []
    artifacts = promo.get("artifacts") or []
    return list(mappings) + list(artifacts)


def target_repos(doc, environment, version):
    """Repository keys to retag. Names are taken as written, never rewritten."""
    if isinstance(doc, list):
        return catalog_repos(doc, environment)
    nodes = []
    promotions = doc.get("promotions") if isinstance(doc, dict) else None
    if isinstance(promotions, list):
        for promo in promotions:
            if isinstance(promo, dict) and promotion_matches(promo, environment, version):
                nodes.extend(mapping_nodes(promo))
    else:
        nodes = list(walk(doc))
    found = []
    for node in nodes:
        if not isinstance(node, dict):
            continue
        target = docker_target(node)
        if target and target not in found:
            found.append(target)
    return sorted(found)


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


def remove_tag(repo, image, floating):
    path = f"/api/docker/{quote(repo)}/v2/{quote(image)}/manifests/{quote(floating)}"
    status, stdout, err = jf_curl("DELETE", path)
    if status != 0:
        if missing(status, stdout, err):
            print(f"Floating tag {image}:{floating} is already absent in {repo}")
            return
        raise SystemExit(err or f"failed to delete {image}:{floating}")
    print(f"Removed {repo}/{image}:{floating}")


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


def list_tags(repo, image):
    path = f"/api/docker/{quote(repo)}/v2/{quote(image)}/tags/list"
    status, stdout, _err = jf_curl("GET", path, {"Accept": "application/json"})
    doc = load_json(stdout) if status == 0 else None
    tags = doc.get("tags") if isinstance(doc, dict) else None
    if not isinstance(tags, list):
        return []
    return [tag for tag in tags if isinstance(tag, str) and tag]


def retag(project, bundle_name, version, repo, floating_tags):
    if not floating_tags:
        floating_tags = fetch_floating_tags(project, bundle_name, version)
    if not repo:
        raise SystemExit("--repo is required")
    if not floating_tags:
        print(f"Bundle {bundle_name}/{version} has no docker.floating_tags property; not retagging {repo}.")
        return
    images, by_image = parse_pairs(floating_tags)
    for image in images:
        for action, floating, target in choose(by_image[image], list_tags(repo, image)):
            if action == "delete":
                remove_tag(repo, image, floating)
            else:
                point_tag(repo, image, floating, target)


def read_json():
    try:
        return json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON: {exc}") from exc


def command_select(args):
    if not args.request:
        raise SystemExit("at least one --request is required")
    for action, floating, target in choose(args.request, args.tag or []):
        if action == "set":
            print(f"set {floating} {target}")
        else:
            print(f"delete {floating}")


def command_repos(args):
    for repo in target_repos(read_json(), args.environment, args.version):
        print(repo)


def command_property(_args):
    value = floating_tags_value(read_json())
    if value:
        print(value)


def command_print_property(args):
    value = fetch_floating_tags(args.project, args.bundle_name, args.version)
    if value:
        print(value)


def command_retag(args):
    retag(args.project, args.bundle_name, args.version, args.repo or "", args.floating_tags or "")


def parser():
    top = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = top.add_subparsers(dest="command", required=True)

    retag_cmd = sub.add_parser("retag", help="point floating tags at the highest version still in a repository")
    for flag in ("--project", "--bundle-name", "--version"):
        retag_cmd.add_argument(flag, required=True)
    retag_cmd.add_argument("--repo", default="")
    retag_cmd.add_argument("--floating-tags", default="")
    retag_cmd.set_defaults(func=command_retag)

    show = sub.add_parser("print-property", help="print docker.floating_tags from the release bundle")
    for flag in ("--project", "--bundle-name", "--version"):
        show.add_argument(flag, required=True)
    show.set_defaults(func=command_print_property)

    select = sub.add_parser("select", help="choose a version tag for each floating tag")
    select.add_argument("--request", action="append", required=True)
    select.add_argument("--tag", action="append", default=[])
    select.set_defaults(func=command_select)

    repos = sub.add_parser("repos", help="print target Docker repositories from JSON on stdin")
    repos.add_argument("--environment", required=True)
    repos.add_argument("--version", default="")
    repos.set_defaults(func=command_repos)

    prop = sub.add_parser("property", help="print docker.floating_tags from a JSON document on stdin")
    prop.set_defaults(func=command_property)
    return top


def main(argv=None):
    args = parser().parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
