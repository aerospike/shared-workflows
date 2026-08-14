#!/usr/bin/env python3
"""Produce a release evidence document from any one published artifact.

    JFROG_TOKEN=<token> ./release-evidence.py <target> [--about TEXT] [--format FORMAT]

    <target>    repo/path, a full URL, sha256:HEX, or bundle:NAME/VERSION@PROJECT
    --about     one clause describing what the thing is, used in the opening sentence
    --format    markdown (default) | json

JFrog auth comes from JFROG_TOKEN. GitHub auth comes from the gh CLI, or GITHUB_TOKEN.

The document is assembled as a list of blocks, then rendered, so the shape of the
document stays separate from how it is laid out.
"""
import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

JF = os.environ.get("JF_BASE", "https://aerospike.jfrog.io")

# A companion file describes a primary artifact rather than being one.
COMPANION = (".asc", ".prov", ".sig", ".sha256", ".md5")
# The public virtual repository for each JFrog package type.
VIRTUAL = {"docker": "docker", "maven": "maven", "helm": "helm", "debian": "deb", "yum": "rpm",
           "pypi": "pypi", "npm": "npm", "go": "go", "nuget": "nuget", "gems": "gems"}
NOUN = {"docker": "container", "maven": "jar", "helm": "Helm chart", "debian": "deb package",
        "yum": "rpm package", "pypi": "Python package", "npm": "npm package", "go": "Go module"}
# An immutable promoted tag carries a build timestamp; the clean tag is what a consumer pulls.
TIMESTAMPED_TAG = re.compile(r"_\d{8}T\d{6}Z")
# Promotion stages in maturity order. INTERNAL and PROD are alternative terminal stages, so
# neither implies the other is missing.
STAGE_ORDER = ["DEV", "TEST", "STAGE", "PREVIEW", "PROD"]
# The environment segment of a repository key names the stage its contents have reached, which
# is how an artifact that was never sealed into a bundle can still be placed in the pipeline.
REPO_ENV_STAGE = {"dev": "DEV", "test": "TEST", "stage": "STAGE",
                  "preview-public": "PREVIEW", "preview-restricted": "PREVIEW",
                  "prod-internal": "INTERNAL", "prod-public": "PROD"}
# The type segment of a repository key, mapped to the package_type a bundle record would use.
REPO_TYPE_PACKAGE = {"deb": "debian", "rpm": "yum", "container": "docker", "cargo": "cargo"}


# ----------------------------------------------------------------- transport
def jfrog_token():
    tok = os.environ.get("JFROG_TOKEN") or os.environ.get("TOKEN")
    if not tok:
        sys.exit("set JFROG_TOKEN to a JFrog access token")
    return tok


def jf(path):
    req = urllib.request.Request(f"{JF}/{path}",
                                headers={"Authorization": f"Bearer {jfrog_token()}"})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except (urllib.error.HTTPError, json.JSONDecodeError):
        return None


def aql(query):
    req = urllib.request.Request(
        f"{JF}/artifactory/api/search/aql", data=query.encode(), method="POST",
        headers={"Authorization": f"Bearer {jfrog_token()}", "Content-Type": "text/plain"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def gh(path):
    """GitHub REST through gh when it is installed, so its auth is reused."""
    if shutil.which("gh"):
        done = subprocess.run(["gh", "api", path], capture_output=True, text=True)
        if done.returncode != 0 or not done.stdout.strip():
            return None
        return json.loads(done.stdout)
    tok = os.environ.get("GITHUB_TOKEN")
    if not tok:
        return None
    req = urllib.request.Request(f"https://api.github.com/{path.lstrip('/')}",
                                headers={"Authorization": f"Bearer {tok}"})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError:
        return None


def statement(envelope):
    """The in-toto statement inside a DSSE envelope."""
    if not envelope or "payload" not in envelope:
        return None
    return json.loads(base64.b64decode(envelope["payload"]))


# ------------------------------------------------------------------- collect
def normalize(target):
    path = re.sub(r"^.*?/artifactory/", "", target)
    return re.sub(r"^api/[^/]+/", "", path)


def stage_of_repo(repo):
    """The promotion stage a repository key represents, or None if it names no stage."""
    base = repo[: -len("-local")] if repo.endswith("-local") else repo
    # Longest first, so prod-public is not mistaken for a repo merely ending in a shorter token.
    for env in sorted(REPO_ENV_STAGE, key=len, reverse=True):
        if base.endswith(f"-{env}"):
            return REPO_ENV_STAGE[env]
    return None


def resolve_sha(path):
    """The digest for a target, whether it was given as a path or already as a digest."""
    if path.startswith("sha256:"):
        return path[len("sha256:"):]
    info = jf(f"artifactory/api/storage/{path}")
    if not info or "checksums" not in info:
        sys.exit(f"no artifact at {path}")
    return info["checksums"]["sha256"]


def find_release(target):
    """The release bundle holding a target, or None when it has not been sealed into one.

    An artifact in DEV has usually not been bundled yet, which is a stage in its life rather
    than an error, so the caller reports on the artifact alone instead of giving up.
    """
    path = normalize(target)

    if path.startswith("bundle:"):
        spec = path[len("bundle:"):]
        name_version, _, project = spec.partition("@")
        return f"{project}-release-bundles-v2", name_version, project

    sha = resolve_sha(path)
    hits = aql(f'items.find({{"sha256":"{sha}"}}).include("repo","path")')
    found = next((h for h in hits["results"]
                  if h["repo"].endswith("-release-bundles-v2")), None)
    if not found:
        return None
    project = found["repo"][: -len("-release-bundles-v2")]
    return found["repo"], "/".join(found["path"].split("/")[:2]), project


def package_type_of_repo(repo):
    """The package_type a bundle record would use, read from the repository key's type segment."""
    base = repo[: -len("-local")] if repo.endswith("-local") else repo
    for env in sorted(REPO_ENV_STAGE, key=len, reverse=True):
        if base.endswith(f"-{env}"):
            base = base[: -len(f"-{env}")]
            break
    segment = base.rsplit("-", 1)[-1]
    return REPO_TYPE_PACKAGE.get(segment, segment)


def unbundled_artifact(target):
    """One artifact, shaped like an entry in a bundle record.

    Returns the entry and the repository it was read from, so an artifact that no bundle
    holds walks the same path below as one that a bundle does.
    """
    path = normalize(target)
    sha = resolve_sha(path)

    if path.startswith("sha256:"):
        hits = aql(f'items.find({{"sha256":"{sha}"}}).include("repo","path","name")')
        found = next((h for h in (hits.get("results") or [])
                      if not h["repo"].endswith("-release-bundles-v2")), None)
        if not found:
            sys.exit(f"no artifact with digest {sha}")
        repo = found["repo"]
        inner = f'{found["path"]}/{found["name"]}'.lstrip("./")
    else:
        repo, _, inner = path.partition("/")

    props = (jf(f"artifactory/api/storage/{repo}/{inner}?properties") or {}).get("properties", {})
    return {
        "package_type": package_type_of_repo(repo),
        # Repository-qualified, so the verify command printed at the end of the document is
        # one a reader can paste. A bundled artifact's path is relative to the bundle instead.
        "path": f"{repo}/{inner}",
        "checksum": sha,
        "properties": [{"key": k, "values": v} for k, v in props.items()],
    }, repo


def where_published(sha, pkg_type):
    """The path a consumer pulls, plus every repository holding these bytes."""
    hits = aql(f'items.find({{"sha256":"{sha}"}}).include("repo","path","name")')
    repos = sorted({h["repo"] for h in hits["results"]})
    public = [h for h in hits["results"] if "prod-public" in h["repo"]]
    virtual = VIRTUAL.get(pkg_type)
    if not public or not virtual:
        return None, repos
    # Prefer a clean tag over an immutable timestamped one.
    public.sort(key=lambda h: (bool(TIMESTAMPED_TAG.search(h["path"])), len(h["path"])))
    inner = f'{public[0]["path"]}/{public[0]["name"]}'.lstrip("/")
    return f"{virtual}/{inner}", repos


def build_origin(name, number, project):
    """Commit, CI run and captured environment size, following the build-info tree."""
    def fetch(num):
        return jf(f"artifactory/api/build/{urllib.parse.quote(name)}/"
                  f"{urllib.parse.quote(num)}?project={project}") or {}

    info = fetch(number).get("buildInfo", {})
    vcs = (info.get("vcs") or [None])[0]
    run = info.get("url", "")
    env = len(info.get("properties") or {})
    if not vcs:
        parent = fetch(re.sub(r"-artifacts$", "", number)).get("buildInfo", {})
        run = run or parent.get("url", "")
        child = next((m["id"].split("/")[-1] for m in parent.get("modules", [])
                      if "-buildinfo-" in m.get("id", "")), None)
        if child:
            meta = fetch(child).get("buildInfo", {})
            vcs = (meta.get("vcs") or [None])[0]
            env = max(env, len(meta.get("properties") or {}))
    return vcs, run, env


def image_labels(root, path):
    """OCI labels, which carry a container's origin when the manifest has no build.* properties."""
    image, directory = path.rsplit("/", 2)[0], path.rsplit("/", 1)[0]
    manifest = jf(f"{root}/{path}")
    if manifest and "manifests" in manifest:
        child = next((m["digest"] for m in manifest["manifests"]
                      if m.get("platform", {}).get("os") != "unknown"), None)
        if not child:
            return {}
        directory = f"{image}/{child}"
        manifest = jf(f"{root}/{directory}/manifest.json")
    config = (manifest or {}).get("config", {}).get("digest")
    if not config:
        return {}
    blob = jf(f"{root}/{directory}/{config.replace(':', '__')}")
    return (blob or {}).get("config", {}).get("Labels") or {}


def primary_artifacts(record):
    """One entry per shipped thing: no signatures, container blobs or per-arch manifests."""
    out = []
    for art in record.get("artifacts", []):
        if art["path"].endswith(COMPANION):
            continue
        if art["package_type"] == "docker" and not art["path"].endswith("/list.manifest.json"):
            continue
        out.append(art)
    return out


def collect(target, about):
    release_ref = find_release(target)
    labels_root = None

    if release_ref:
        bundle_repo, bundle, project = release_ref
        record = jf(f"lifecycle/api/v2/release_bundle/records/{bundle}?project={project}") or {}
        seal = statement(jf(f"artifactory/{bundle_repo}/{bundle}/release-bundle.json.evd")) or {}
        sealed_digests = {s["digest"]["sha256"] for s in seal.get("subject", [])}
        entries = primary_artifacts(record)
    else:
        # No bundle holds this artifact, which is where everything sits before the first
        # promotion. Report the artifact on its own rather than refusing, and let the absent
        # records show up as absent.
        entry, origin_repo = unbundled_artifact(target)
        bundle_repo, bundle = None, None
        project = origin_repo.split("-")[0]
        record, seal, sealed_digests = {}, {}, set()
        entries = [entry]
        # The entry's path already carries its repository, unlike a bundled one.
        labels_root = "artifactory"

    signatures = {}
    for art in record.get("artifacts", []):
        for ext in COMPANION:
            if art["path"].endswith(ext):
                signatures[ext] = signatures.get(ext, 0) + 1

    promotions = []
    if release_ref:
        listing = jf(f"artifactory/api/storage/{bundle_repo}/{bundle}") or {}
        for child in listing.get("children", []):
            if not child["uri"].startswith("/promotion-"):
                continue
            pred = (statement(jf(f"artifactory/{bundle_repo}/{bundle}{child['uri']}"))
                    or {}).get("predicate", {})
            promotions.append({
                # An attestation we cannot read or attribute is still a promotion that
                # happened. Naming it UNKNOWN keeps it visible without letting it count as
                # a stage reached, which dropping it silently would not.
                "stage": pred.get("target", {}).get("environment") or "UNKNOWN",
                "when": pred.get("timestamp"),
                "by": pred.get("createdBy"),
                "repos": pred.get("target", {}).get("includedRepositoryKeys", []),
                "mutable": pred.get("mutable"),
                "seals": (pred.get("provenance") or [{}])[0].get("digest", {}).get("sha256"),
            })
        promotions.sort(key=lambda p: p["when"] or "")

    artifacts, source = [], None
    for art in entries:
        props = {p["key"]: p["values"][0] for p in (art.get("properties") or [])}
        sha = art["checksum"]
        public, repos = where_published(sha, art["package_type"])

        vcs, run, env = None, "", 0
        if props.get("build.name") and props.get("build.number"):
            vcs, run, env = build_origin(props["build.name"], props["build.number"], project)

        repo = None
        if vcs:
            repo = re.sub(r"\.git$", "", re.sub(r"^https://github\.com/", "", vcs.get("url", "")))
        elif run:
            match = re.match(r"https://github\.com/([^/]+/[^/]+)/", run)
            repo = match.group(1) if match else None

        labels = {}
        if not repo and art["package_type"] == "docker":
            root = labels_root or (f"artifactory/{bundle_repo}/{bundle}/artifacts/"
                                   f'{art["package_type"]}')
            labels = image_labels(root, art["path"])
            repo = re.sub(r"^https://github\.com/", "",
                          labels.get("org.opencontainers.image.source", "")) or None

        attestation = None
        if repo:
            found = gh(f"repos/{repo}/attestations/sha256:{sha}")
            stmt = None
            if found and found.get("attestations"):
                stmt = statement(found["attestations"][0]["bundle"]["dsseEnvelope"])
            if stmt:
                build_def = stmt["predicate"]["buildDefinition"]
                attestation = {
                    "predicate": stmt.get("predicateType"),
                    "builder": re.sub(r"@([0-9a-f]{8})[0-9a-f]+$", r"@\1",
                                      stmt["predicate"]["runDetails"]["builder"]["id"]
                                      .rsplit("/", 1)[-1]),
                    "buildType": build_def.get("buildType"),
                    "runner": build_def.get("internalParameters", {})
                                       .get("github", {}).get("runner_environment"),
                }

        commit, commit_from = None, None
        if vcs and vcs.get("revision"):
            commit, commit_from = vcs["revision"], "JFrog build-info"
        elif labels.get("org.opencontainers.image.revision"):
            commit, commit_from = labels["org.opencontainers.image.revision"], "OCI image labels"
        elif attestation:
            deps = stmt["predicate"]["buildDefinition"].get("resolvedDependencies") or [{}]
            commit = deps[0].get("digest", {}).get("gitCommit")
            commit_from = "GitHub attestation" if commit else None

        # The bundle record keeps build.* even where the promoted copy does not.
        published_linked = None
        if public:
            props_public = (jf(f"artifactory/api/storage/{public}?properties") or {})
            published_linked = "build.name" in (props_public.get("properties") or {})

        if commit and not source:
            source = {"repo": repo, "commit": commit, "run": run, "env": env,
                      "subject": (vcs or {}).get("message", "").split("\n")[0]}

        artifacts.append({
            "type": art["package_type"], "path": art["path"], "sha256": sha,
            "public": public, "published_build_linked": published_linked, "repos": repos,
            "build": props.get("build.name"), "number": props.get("build.number"),
            "commit": commit, "commit_from": commit_from,
            "sealed": sha in sealed_digests, "source_repo": repo, "attestation": attestation,
        })

    pull_request = None
    if source and source["repo"] and source["commit"]:
        found = gh(f'repos/{source["repo"]}/commits/{source["commit"]}/pulls') or []
        if found:
            head = found[0]
            reviews = gh(f'repos/{source["repo"]}/pulls/{head["number"]}/reviews') or []
            pull_request = {
                "number": head["number"], "title": head["title"],
                "author": head["user"]["login"], "merged_at": head.get("merged_at"),
                "repo": head["base"]["repo"]["full_name"],
                "approvers": sorted({r["user"]["login"] for r in reviews
                                     if r.get("state") == "APPROVED"}),
            }

    types = sorted({a["type"] for a in artifacts})
    attested = sorted({a["type"] for a in artifacts if a["attestation"]})
    stages = [p["stage"] for p in promotions]

    # Where the bytes sit is a second, independent reading of maturity, and the only one
    # available before a bundle exists. A promotion record is the stronger claim; repository
    # residence still places the artifact in the pipeline.
    resident = sorted({stage_of_repo(r) for a in artifacts for r in a["repos"]} - {None},
                      key=lambda s: STAGE_ORDER.index(s) if s in STAGE_ORDER else len(STAGE_ORDER))
    reached = [s for s in STAGE_ORDER if s in set(stages) | set(resident)]
    if "INTERNAL" in stages or "INTERNAL" in resident:
        reached.append("INTERNAL")

    # INTERNAL and PROD are alternative terminal stages, so neither implies the other is due.
    expected = STAGE_ORDER[:-1] if "INTERNAL" in reached else STAGE_ORDER
    furthest = max((expected.index(s) for s in reached if s in expected), default=-1)

    return {
        "about": about,
        "project": project,
        "release": {
            "name": bundle.split("/")[0], "version": bundle.split("/")[1], "bundle": bundle,
            "repo": bundle_repo, "project": project, "created": record.get("created"),
            "created_by": record.get("created_by"), "files": record.get("total_artifacts_count"),
            "seal": {"statement": seal.get("_type"), "predicate": seal.get("predicateType"),
                     "subjects": len(seal.get("subject", []))},
        } if release_ref else None,
        "signatures": signatures, "pr": pull_request, "promotions": promotions,
        "artifacts": artifacts, "source": source,
        "derived": {
            "types": types, "attested_types": attested,
            "unattested_types": [t for t in types if t not in attested],
            "stages": stages, "terminal_stage": stages[-1] if stages else None,
            "sealed": bool(release_ref),
            # Where the artifact has got to, however it got there.
            "stages_reached": reached,
            "resident_stages": resident,
            # Absent below the furthest point reached, so a gate was passed over. An anomaly.
            "skipped_stages": [s for s in expected[:furthest + 1] if s not in reached],
            # Absent above it, so simply not promoted there yet. Expected, not an anomaly.
            "pending_stages": [s for s in expected[furthest + 1:]],
            "self_approved": bool(pull_request
                                  and pull_request["author"] in pull_request["approvers"]),
            "unlinked_published": sorted({a["type"] for a in artifacts
                                          if a["public"] and a["published_build_linked"] is False}),
            "any_commit": any(a["commit"] for a in artifacts),
        },
    }


# -------------------------------------------------------------------- phrasing
def cap(text):
    return text[:1].upper() + text[1:] if text else text


def phrase(items):
    items = list(items)
    if not items:
        return "none"
    if len(items) == 1:
        return items[0]
    return ", ".join(items[:-1]) + " and " + items[-1]


def noun(pkg_type):
    return NOUN.get(pkg_type, pkg_type)


def nouns(evidence):
    counts = {}
    for art in evidence["artifacts"]:
        counts[art["type"]] = counts.get(art["type"], 0) + 1
    return phrase(f"{n} {noun(t)}s" if n > 1 else f"a {noun(t)}" for t, n in counts.items())


def type_scope(evidence):
    return cap(phrase(noun(t) for t in evidence["derived"]["types"]))


def when(timestamp):
    return (timestamp or "").replace("T", " ")[:19]


def terminal(evidence):
    return evidence["promotions"][-1] if evidence["promotions"] else None


# ------------------------------------------------------------------- document
def custody_rows(evidence):
    release, pr, rows = evidence["release"], evidence["pr"], []
    gated = evidence["promotions"][:-1]
    last = terminal(evidence)

    if pr:
        commit = evidence["source"]["commit"][:8]
        approval = (f'approved by {phrase(f"`{a}`" for a in pr["approvers"])}'
                    if pr["approvers"] else "not approved")
        state = (f'merged {when(pr["merged_at"])} UTC as commit `{commit}`'
                 if pr["merged_at"] else f'still open, head at commit `{commit}`')
        rows.append(["Peer review",
                     f'[PR #{pr["number"]}](https://github.com/{pr["repo"]}/pull/{pr["number"]}), '
                     f'written by `{pr["author"]}`, {approval}, {state}', "GitHub"])
    if evidence["source"]:
        src = evidence["source"]
        rows.append(["Build from that commit",
                     f'Build-info records `vcs.revision {src["commit"]}` and '
                     f'[the CI run]({src["run"]}), alongside {src["env"]} captured environment '
                     f"values", "JFrog build-info"])
    if release:
        detail = (f'including {phrase(f"{n} `{ext}` file" + ("s" if n > 1 else "") for ext, n in sorted(evidence["signatures"].items()))}'
                  if evidence["signatures"] else "each addressed by digest")
        rows.append(["Artifacts sealed", f'{release["files"]} files, {detail}',
                     "Stage repositories"])
        rows.append(["Bundle sealed",
                     f'{when(release["created"])} UTC by `{release["created_by"]}`. A DSSE envelope '
                     f'carrying an in-toto Statement v1, naming all {release["seal"]["subjects"]} '
                     f"files by SHA-256", "`release-bundle.json.evd`"])
    else:
        rows.append(["Artifacts sealed", "No release bundle holds these bytes yet, so nothing "
                     "binds them together or fixes their contents", "Not yet recorded"])
    if gated:
        rows.append([phrase(p["stage"] for p in gated),
                     "Promoted " + phrase(f'{when(p["when"])} UTC by `{p["by"]}`' for p in gated),
                     f"{len(gated)} signed promotion attestations"])
    if last:
        rows.append([last["stage"],
                     f'{when(last["when"])} UTC by `{last["by"]}`, targeting '
                     f'{phrase(f"`{r}`" for r in last["repos"])}, marked '
                     f'`mutable: {str(last["mutable"]).lower()}`', "Signed promotion attestation"])
    return rows


def duty_rows(evidence):
    pr, rows = evidence["pr"], []
    if pr:
        rows.append(["Wrote the change", f'`{pr["author"]}`', "GitHub commit authorship"])
        for approver in pr["approvers"]:
            rows.append(["Approved the change", f"`{approver}`",
                         "GitHub review, required by branch protection"])
    if evidence["release"]:
        rows.append(["Built and sealed", f'`{evidence["release"]["created_by"]}`',
                     "A short-lived CI OIDC token, with no stored secret"])
    for p in evidence["promotions"][:-1]:
        rows.append([f'Promoted to {p["stage"]}', f'`{p["by"]}`', "Signed promotion attestation"])
    last = terminal(evidence)
    if last:
        rows.append([f'Authorized the {last["stage"]} publish', f'`{last["by"]}`',
                     f'Signed {last["stage"]} promotion attestation'])
    return rows


def claim_rows(evidence):
    derived, scope, rows = evidence["derived"], type_scope(evidence), []
    last = terminal(evidence)
    # Only claims with a record behind them belong here. An artifact that has not been sealed
    # or promoted supports none of the custody claims, and saying otherwise would be the one
    # failure this document cannot afford.
    if last:
        rows.append(["These bytes are the ones a named identity authorized for release",
                     f'The {last["stage"]} promotion attestation names the seal by digest, and '
                     "the seal names this file by SHA-256", scope])
    if evidence["release"]:
        rows.append(["The contents could not change after sealing",
                     f'A DSSE in-toto statement over all {evidence["release"]["seal"]["subjects"]} '
                     "digests, and promotion records carrying `mutable: false`", scope])
    if evidence["promotions"]:
        rows.append(["The same bytes moved through every stage reached so far",
                     "The identical SHA-256 is present in each stage repository and is a subject "
                     "of the seal", scope])
        rows.append(["Every stage transition so far has an identity and a timestamp",
                     "One signed promotion attestation per stage", scope])
    if evidence["pr"]:
        pr = evidence["pr"]
        independent = [a for a in pr["approvers"] if a != pr["author"]]
        if independent and pr["merged_at"]:
            rows.append(["The change was approved by someone other than its author before merge",
                         f'PR #{pr["number"]}, approved by '
                         f'{phrase(f"`{a}`" for a in independent)} against author '
                         f'`{pr["author"]}`', scope])
    for pkg_type in derived["attested_types"]:
        art = next(a for a in evidence["artifacts"]
                   if a["type"] == pkg_type and a["attestation"])
        att = art["attestation"]
        rows.append([f'These bytes were produced by our shared CI from commit '
                     f'`{art["commit"][:8]}`',
                     "Sigstore-signed SLSA provenance held by GitHub, keyed to the artifact "
                     f'digest, with `builder.id` of `{att["builder"]}` and runner '
                     f'`{att["runner"]}`', cap(noun(pkg_type))])
    if derived["unattested_types"] and derived["any_commit"]:
        art = next(a for a in evidence["artifacts"] if a["commit"])
        rows.append([f'The {phrase(noun(t) for t in derived["unattested_types"])} carry commit '
                     f'`{art["commit"][:8]}`',
                     "A JFrog build-info record published by the build job about itself, with no "
                     "signature over it",
                     cap(phrase(noun(t) for t in derived["unattested_types"]))])
    return rows


def gap_rows(evidence):
    derived, rows = evidence["derived"], []
    if not derived["any_commit"]:
        rows.append(["A recorded source commit",
                     "That these bytes came from a known revision. No build-info VCS block, image "
                     "label or attestation records one, so the only pointer to source is the CI "
                     "run URL."])
    if derived["unattested_types"]:
        rows.append(["An attestation step in the shared artifacts pipeline",
                     "That our shared CI produced the "
                     f'{phrase(noun(t) for t in derived["unattested_types"])} from a given commit, '
                     "signed by the build platform rather than recorded by the build."])
    if derived["attested_types"]:
        rows.append(["An evidence precondition at the customer-facing gates",
                     "That nothing reaches customers without valid provenance. Today the gate "
                     "requires a named approver and nothing about the artifact, so no check "
                     f'consumes the attestation the '
                     f'{phrase(noun(t) for t in derived["attested_types"])} already has.'])
    if derived["unlinked_published"]:
        rows.append(["Build properties preserved on promotion",
                     f'That a {phrase(noun(t) for t in derived["unlinked_published"])} found in a '
                     "public repository can be joined to its build by one query. The bundle record "
                     "keeps `build.name` and `build.number`, but the promoted copy carries only "
                     "registry metadata, so a consumer starting from the registry has to fall back "
                     "to OCI labels."])
    if not derived["sealed"]:
        rows.append(["A release bundle holding these bytes",
                     "That these bytes are fixed and travel as a unit. Nothing has been sealed "
                     "yet, so there is no seal to name them and no promotion record can refer "
                     "to them. Every custody claim below depends on this one."])
    if derived["skipped_stages"]:
        rows.append([f'A recorded {phrase(derived["skipped_stages"])} transition',
                     f'That this passed through {phrase(derived["skipped_stages"])}. It has '
                     f'reached {phrase(derived["stages_reached"])}, so those gates were passed '
                     "over rather than not yet reached."])
    return rows


def subject(evidence):
    """What this document is about: a release when there is one, otherwise the artifact."""
    release = evidence["release"]
    if release:
        return f'{release["name"]} {release["version"]}'
    art = evidence["artifacts"][0]
    return art["path"].rsplit("/", 1)[-1]


def position_blocks(evidence):
    """Where this has got to, stated before any claim that depends on having got there."""
    derived = evidence["derived"]
    reached = phrase(derived["stages_reached"]) if derived["stages_reached"] else "no stage"
    text = f"This has reached {reached}."
    if derived["pending_stages"]:
        text += (f' It has not been promoted to {phrase(derived["pending_stages"])} yet, so the '
                 "records those stages would produce do not exist and are not counted against it.")
    if derived["skipped_stages"]:
        text += (f' No promotion record exists for {phrase(derived["skipped_stages"])}, which sits '
                 "below where it has got to. That is a gap rather than work still to come.")
    if not derived["sealed"]:
        text += (" Nothing has been sealed into a release bundle, so the custody claims below are "
                 "limited to what the build itself recorded.")
    return [("h2", "Where this is"), ("p", text)]


def document(evidence):
    """The document as blocks, so markdown and Confluence cannot drift apart."""
    release, last = evidence["release"], terminal(evidence)
    if release:
        ui = (f'{JF}/ui/artifactory/release-lifecycle/{release["name"]}/{release["version"]}'
              f'?repoKey={release["repo"]}')
        blocks = [
            ("panel", "info",
             f'{release["name"]} {release["version"]} shipped as {nouns(evidence)} from a single '
             "commit. Because they share one commit, one release bundle and one set of approvals, "
             "the evidence differs only where the pipeline differs."),
            ("h2", "The release"),
            ("p", f'[{release["name"]} {release["version"]}]({ui})'
                  + (f', {evidence["about"]}' if evidence["about"] else "")
                  + f". One commit produced {nouns(evidence)}, and every step of that path left a "
                    "signed record."),
        ]
    else:
        blocks = [
            ("panel", "info",
             f"{subject(evidence)} has not been sealed into a release bundle. What follows is "
             "what the build recorded about it, and what is absent because it has not travelled "
             "far enough to produce it."),
            ("h2", "The artifact"),
            ("p", f"`{evidence['artifacts'][0]['path']}` in the "
                  f"`{evidence['project']}` project"
                  + (f', {evidence["about"]}' if evidence["about"] else "") + "."),
        ]
    blocks += position_blocks(evidence)
    blocks += [
        ("h2", "Chain of custody"),
        ("table", ["Step", "What the record says", "Where it lives"], custody_rows(evidence)),
    ]
    if release:
        blocks += [
            ("h2", "Why the chain holds"),
            ("p", "Each link is bound to the previous one by a value that cannot be edited after "
                  f'the fact. The seal names all {release["seal"]["subjects"]} files by SHA-256, '
                  "so any change to any file breaks the signature. The "
                  f'{last["stage"] if last else "terminal"} attestation names the seal by its own '
                  "digest, and covers every artifact in one action:"),
        ]
    if last:
        indent = "\n" + " " * 18
        blocks.append(("code",
                       f'provenance: /{release["repo"]}/{release["bundle"]}/release-bundle.json.evd\n'
                       f'            sha256 {last["seals"]}\n'
                       f'createdBy:  {last["by"]}\n'
                       f'target:     {last["stage"]}, {indent.join(last["repos"])}\n'
                       f'mutable:    {str(last["mutable"]).lower()}'))
    if last and last["stage"] != "UNKNOWN":
        where = ("a public repository" if any("prod-public" in r for r in last["repos"])
                 else f'the {last["stage"].lower()} registry')
        blocks.append(("p", f"An auditor can therefore start at any of these artifacts in {where} "
                            "and walk back to the pull request that authorized it, checking a hash "
                            "at every hop."))
    duties = duty_rows(evidence)
    if duties:
        blocks += [
            ("h2", "Segregation of duties, as recorded"),
            ("p", f'{len({r[1] for r in duties})} identities appear so far, and the system '
                  "recorded each one at the moment it acted."),
            ("table", ["Role", "Identity", "Recorded by"], duties),
        ]
    if evidence["pr"] and not evidence["derived"]["self_approved"]:
        blocks.append(("p", "The author could not approve their own change, and neither the author "
                            "nor the reviewer authorized the publish."))
    claims = claim_rows(evidence)
    if claims:
        blocks += [
            ("h2", "What the evidence proves"),
            ("p", "Each row is a claim an auditor might make, the record that backs it, and which "
                  "of the artifacts it holds for."),
            ("table", ["Claim", "Backed by", "Holds for"], claims),
        ]
    else:
        blocks += [
            ("h2", "What the evidence proves"),
            ("p", "Nothing yet beyond what the build recorded about itself. Every custody claim "
                  "needs a seal or a promotion record, and neither exists for this artifact."),
        ]
    blocks += [
        ("h2", "Verify it yourself"),
        ("p", "One command per artifact, against the most public location each one has reached. "
              "Reading the build, seal and promotion records needs an account with read access to "
              f'the `{evidence["project"]}` project, and the review and provenance steps need the '
              "GitHub CLI."),
        ("code", 'export JFROG_TOKEN="<a JFrog access token>"\n\n'
                 + "\n".join(f'./verify-artifact.sh {a["public"] or a["path"]}'
                             for a in evidence["artifacts"]), "bash"),
    ]
    gaps = gap_rows(evidence)
    if gaps:
        blocks += [
            ("h2", "What we could prove with more evidence"),
            ("table", ["Addition", "Claim it would let us make"], gaps),
        ]
    return blocks


# -------------------------------------------------------------------- render
def render_markdown(evidence, blocks):
    kind = "release evidence" if evidence["release"] else "artifact evidence"
    out = [f"# {subject(evidence)}: {kind}", ""]
    for block in blocks:
        kind = block[0]
        if kind == "h2":
            out += [f"## {block[1]}", ""]
        elif kind in ("p", "panel"):
            out += [block[-1], ""]
        elif kind == "code":
            lang = block[2] if len(block) > 2 else ""
            out += [f"```{lang}", block[1], "```", ""]
        elif kind == "table":
            _, headers, rows = block
            out.append("| " + " | ".join(headers) + " |")
            out.append("|" + "|".join(" --- " for _ in headers) + "|")
            out += ["| " + " | ".join(r) + " |" for r in rows]
            out.append("")
    return "\n".join(out).rstrip() + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("target")
    parser.add_argument("--about", default="")
    parser.add_argument("--format", choices=("markdown", "json"), default="markdown")
    args = parser.parse_args()

    evidence = collect(args.target, args.about)
    if args.format == "json":
        print(json.dumps(evidence, indent=2))
    else:
        print(render_markdown(evidence, document(evidence)), end="")


if __name__ == "__main__":
    main()
