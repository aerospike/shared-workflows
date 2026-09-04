#!/usr/bin/env python3
"""Produce a release evidence document from any one published artifact.

    JFROG_TOKEN=<token> ./release-evidence.py <target> [--about TEXT] [--format FORMAT]

    <target>    repo/path, a full URL, sha256:HEX, or bundle:NAME/VERSION@PROJECT
    --about     one clause describing what the thing is, used in the opening sentence
    --format    markdown (default) | json
    --as-of     the date to report as, default today, since records accrue as a release moves
    --verdict-path  write the verdict object here as well, whatever --format is

JFrog auth comes from JFROG_TOKEN. GitHub auth comes from the gh CLI, or GITHUB_TOKEN.
"""
import argparse
import base64
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

JF_BASE = os.environ.get("JF_BASE", "https://aerospike.jfrog.io")

COMPANION = (".asc", ".prov", ".sig", ".sha256", ".md5")
VIRTUAL = {"docker": "docker", "maven": "maven", "helm": "helm", "debian": "deb", "yum": "rpm",
           "pypi": "pypi", "npm": "npm", "go": "go", "nuget": "nuget", "gems": "gems"}
# An absent key falls through to the raw package type, so every type JFrog reports needs one.
NOUN = {"docker": "container", "oci": "container", "maven": "jar", "helm": "Helm chart",
        "debian": "deb package", "yum": "rpm package", "pypi": "Python package",
        "npm": "npm package", "go": "Go module", "generic": "file",
        "nuget": "NuGet package", "gems": "Ruby gem", "cargo": "Rust crate"}
# Both separators are in use: `8.1.3.0_20260721T101500Z` and `8.1.3.0-20260721101500`.
TIMESTAMPED_TAG = re.compile(r"_\d{8}T\d{6}Z|-\d{14}(?!\d)")
# INTERNAL is absent because it is an alternative terminal stage to PROD, not a step after it.
STAGE_ORDER = ["DEV", "TEST", "STAGE", "PREVIEW", "PROD"]
# Optional by policy. Their absence is never a finding.
OPTIONAL_STAGES = {"DEV", "PREVIEW"}
# TEST is absent: CI building bytes and promoting them there is one identity on every release.
SEPARATION_STAGES = {"STAGE", "PREVIEW", "PROD", "INTERNAL"}
# A CI identity in a JFrog record: `token:[<project>-]gh-<org>/<github-actor>`.
TOKEN_ACTOR = re.compile(r"^token:(?:[a-z0-9]+-)?gh-(?P<org>[a-z0-9-]+)/(?P<actor>.+)$")
# Keys naming no stage here resolve to None; JFrog's own `environments` field is authoritative
# and disagrees for the `ecosystem-*-prod-local` family.
REPO_ENV_STAGE = {"dev": "DEV", "test": "TEST", "stage": "STAGE",
                  "preview-public": "PREVIEW", "preview-restricted": "PREVIEW",
                  "prod-internal": "INTERNAL", "prod-public": "PROD"}
REPO_TYPE_PACKAGE = {"deb": "debian", "rpm": "yum", "container": "docker", "cargo": "cargo"}
# Reachability, not maturity: STAGE_ORDER would rank INTERNAL above STAGE.
PUBLICITY = ["PROD", "PREVIEW", "INTERNAL", "STAGE", "TEST", "DEV"]


# ----------------------------------------------------------------- transport
def jfrog_token():
    tok = os.environ.get("JFROG_TOKEN") or os.environ.get("TOKEN")
    if not tok:
        sys.exit("set JFROG_TOKEN to a JFrog access token")
    return tok


def jfrog(path):
    req = urllib.request.Request(f"{JF_BASE}/{path}",
                                headers={"Authorization": f"Bearer {jfrog_token()}"})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except (urllib.error.HTTPError, json.JSONDecodeError):
        return None


def aql(query):
    req = urllib.request.Request(
        f"{JF_BASE}/artifactory/api/search/aql", data=query.encode(), method="POST",
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


def gh_graphql(query, **variables):
    """GitHub GraphQL, for the SAML identity map the REST API does not expose."""
    payload = json.dumps({"query": query, "variables": variables})
    if shutil.which("gh"):
        done = subprocess.run(["gh", "api", "graphql", "--input", "-"],
                              input=payload, capture_output=True, text=True)
        if done.returncode != 0 or not done.stdout.strip():
            return None
        return json.loads(done.stdout).get("data")
    tok = os.environ.get("GITHUB_TOKEN")
    if not tok:
        return None
    req = urllib.request.Request("https://api.github.com/graphql", data=payload.encode(),
                                 headers={"Authorization": f"Bearer {tok}"})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp).get("data")
    except urllib.error.HTTPError:
        return None


IDENTITIES_QUERY = """
query($org: String!, $after: String) {
  organization(login: $org) {
    samlIdentityProvider {
      externalIdentities(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { samlIdentity { nameId } user { login name } }
      }
    }
  }
}
"""
# A person can hold more than one address on the company's verified domains, and a JFrog record
# may carry any of them, so every address a person holds has to collapse to one identity.
MEMBER_EMAILS_QUERY = """
query($org: String!, $after: String) {
  organization(login: $org) {
    membersWithRole(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { login name organizationVerifiedDomainEmails(login: $org) }
    }
  }
}
"""
_SAML = {}


def saml_identities(org):
    """A GitHub login to {email, emails, name} map from the org's directory.

    Both sources are needed: SAML gives the sign-in address, verified-domain gives every company
    address, and a promotion record may carry any of them.

    `users/<login>` is not a substitute; its profile email is null for nearly everyone, and no
    string rule links a login to a person (`Klaven` is mcounts@aerospike.com). Both queries need
    read:org, which a CI GITHUB_TOKEN lacks, so an empty map means unproven, not unrelated.
    """
    if org in _SAML:
        return _SAML[org]
    found = {}

    for node in paged(IDENTITIES_QUERY, org, "samlIdentityProvider", "externalIdentities"):
        user, saml = node.get("user"), node.get("samlIdentity") or {}
        if user and saml.get("nameId"):
            login = user["login"].lower()
            found[login] = {"email": saml["nameId"].lower(),
                            "emails": {saml["nameId"].lower()},
                            "name": (user.get("name") or "").strip() or None}

    for node in paged(MEMBER_EMAILS_QUERY, org, None, "membersWithRole"):
        addresses = {e.lower() for e in (node.get("organizationVerifiedDomainEmails") or [])}
        if not addresses:
            continue
        login = node["login"].lower()
        entry = found.setdefault(login, {"email": sorted(addresses)[0], "emails": set(),
                                         "name": (node.get("name") or "").strip() or None})
        entry["emails"] |= addresses
        entry["name"] = entry.get("name") or (node.get("name") or "").strip() or None

    _SAML[org] = found
    return found


def paged(query, org, container, connection):
    """Every node of one paginated organization connection."""
    nodes, after = [], None
    while True:
        data = gh_graphql(query, org=org, after=after)
        scope = (data or {}).get("organization") or {}
        if container:
            scope = scope.get(container) or {}
        page = scope.get(connection)
        if not page:
            break
        nodes += page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]
    return nodes


def statement(envelope):
    """The in-toto statement inside a DSSE envelope."""
    if not envelope or "payload" not in envelope:
        return None
    return json.loads(base64.b64decode(envelope["payload"]))


# ------------------------------------------------------------------- collect
def normalize(target):
    path = re.sub(r"^.*?/artifactory/", "", target)
    return re.sub(r"^api/[^/]+/", "", path)


def classify_stages(promoted, resident):
    """Where a release has got to, which required gates it passed over, and which lie ahead.

    A promotion record is the stronger reading of maturity; repository residence still places an
    artifact in the pipeline, and is the only reading available before a bundle exists. DEV and
    PREVIEW are optional, so their absence is reported neither as a gap nor as pending work.
    """
    reached = [s for s in STAGE_ORDER if s in set(promoted) | set(resident)]
    if "INTERNAL" in promoted or "INTERNAL" in resident:
        reached.append("INTERNAL")
    expected = STAGE_ORDER[:-1] if "INTERNAL" in reached else STAGE_ORDER
    furthest = max((expected.index(s) for s in reached if s in expected), default=-1)
    return {
        "stages_reached": reached,
        "skipped_stages": [s for s in expected[:furthest + 1]
                           if s not in reached and s not in OPTIONAL_STAGES],
        "pending_stages": [s for s in expected[furthest + 1:] if s not in OPTIONAL_STAGES],
    }


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
    info = jfrog(f"artifactory/api/storage/{path}")
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
    digest_hits = aql(f'items.find({{"sha256":"{sha}"}}).include("repo","path")')
    found = next((h for h in digest_hits["results"]
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
        digest_hits = aql(f'items.find({{"sha256":"{sha}"}}).include("repo","path","name")')
        found = next((h for h in (digest_hits.get("results") or [])
                      if not h["repo"].endswith("-release-bundles-v2")), None)
        if not found:
            sys.exit(f"no artifact with digest {sha}")
        repo = found["repo"]
        inner = f'{found["path"]}/{found["name"]}'.lstrip("./")
    else:
        repo, _, inner = path.partition("/")

    props = (jfrog(f"artifactory/api/storage/{repo}/{inner}?properties") or {}).get("properties", {})
    return {
        "package_type": package_type_of_repo(repo),
        # Repository-qualified here; a bundled artifact's path is bundle-relative instead.
        "path": f"{repo}/{inner}",
        "checksum": sha,
        "properties": [{"key": k, "values": v} for k, v in props.items()],
    }, repo


def version_hint(bundle, entry):
    """The version the caller named, used to prefer their tag over a floating one.

    A hint that names no version scores every candidate alike, so the ordering is unaffected.
    """
    if bundle and "/" in bundle:
        return bundle.split("/", 1)[1]
    parts = entry["path"].split("/")
    return parts[-2] if len(parts) > 2 else None


def project_of(repo, sha):
    """The JFrog project holding these bytes.

    A public top-level virtual (`docker/...`, `maven/...`) names no project, so its first path
    segment is not one.
    """
    if repo.endswith("-local"):
        return repo.split("-")[0]
    holders = sorted({h["repo"] for h in aql(
        f'items.find({{"sha256":"{sha}"}}).include("repo")')["results"]})
    for holder in holders:
        if holder.endswith("-release-bundles-v2"):
            return holder[: -len("-release-bundles-v2")]
    for holder in holders:
        if holder.endswith("-local"):
            return holder.split("-")[0]
    return repo.split("-")[0]


def where_published(sha, pkg_type, version=None):
    """The path a consumer pulls, every repository holding these bytes, and the build link.

    The link is looked up by digest, not per path: retagging on promotion strips build properties
    from the clean tag while the timestamped tag beside it keeps them, so a per-path answer would
    report a break the consumer does not experience.
    """
    digest_hits = aql(f'items.find({{"sha256":"{sha}"}}).include('
               f'"repo","path","name","property.key","property.value")')
    repos = sorted({h["repo"] for h in digest_hits["results"]})
    linked = any(p.get("key") == "build.name"
                 for h in digest_hits["results"] for p in (h.get("properties") or []))
    public = [h for h in digest_hits["results"] if "prod-public" in h["repo"]]
    virtual = VIRTUAL.get(pkg_type)
    if not public or not virtual:
        return None, repos, linked
    # Version first, then a clean tag over a timestamped one. Dropping the version key lets a
    # floating `8.1` win on length over the `8.1.3.0` asked for.
    public.sort(key=lambda h: (bool(version) and version not in h["path"],
                               bool(TIMESTAMPED_TAG.search(h["path"])),
                               len(h["path"])))
    inner = f'{public[0]["path"]}/{public[0]["name"]}'.lstrip("/")
    return f"{virtual}/{inner}", repos, linked


def most_public(repos):
    """The furthest-promoted repository holding these bytes.

    A release-bundles repository holds the record, not the artifact, so it is never the answer.
    A key naming no stage ranks last rather than being discarded.
    """
    candidates = [r for r in repos if not r.endswith("-release-bundles-v2")]
    if not candidates:
        return None
    def rank(repo):
        stage = stage_of_repo(repo)
        return (PUBLICITY.index(stage) if stage in PUBLICITY else len(PUBLICITY), repo)
    return min(candidates, key=rank)


def pasteable(art):
    """A repository-qualified path for the verify command, for every artifact.

    `public` exists only for a type in VIRTUAL whose bytes reached a `prod-public` repository.
    A bundled artifact's own path carries no repository.
    """
    if art["public"]:
        return art["public"]
    # An unbundled entry is already repository-qualified by unbundled_artifact.
    head = art["path"].split("/", 1)[0]
    if head in art["repos"]:
        return art["path"]
    holding = most_public(art["repos"])
    return f'{holding}/{art["path"]}' if holding else art["path"]


def qualified(art):
    """The artifact in a real repository, which is where its `build.*` properties live.

    A virtual repository does not answer property requests, and for a container neither does
    the floating tag folder: the properties sit on the timestamped path the build pushed.
    """
    head = art["path"].split("/", 1)[0]
    if head in art["repos"]:
        return art["path"]
    holding = most_public(art["repos"])
    return f'{holding}/{art["path"]}' if holding else art["path"]


def build_origin(name, number, project):
    """Commit, CI run, captured environment size, and the build number the commit came from."""
    def fetch(num):
        return jfrog(f"artifactory/api/build/{urllib.parse.quote(name)}/"
                  f"{urllib.parse.quote(num)}?project={project}") or {}

    info = fetch(number).get("buildInfo", {})
    vcs = (info.get("vcs") or [None])[0]
    run = info.get("url", "")
    env = len(info.get("properties") or {})
    holder = number if vcs else None
    if not vcs:
        parent = fetch(re.sub(r"-artifacts$", "", number)).get("buildInfo", {})
        run = run or parent.get("url", "")
        child = next((m["id"].split("/")[-1] for m in parent.get("modules", [])
                      if "-buildinfo-" in m.get("id", "")), None)
        if child:
            meta = fetch(child).get("buildInfo", {})
            vcs = (meta.get("vcs") or [None])[0]
            env = max(env, len(meta.get("properties") or {}))
            holder = child if vcs else None
    return vcs, run, env, holder


def image_labels(root, path):
    """OCI labels, which carry a container's origin when the manifest has no build.* properties."""
    image, directory = path.rsplit("/", 2)[0], path.rsplit("/", 1)[0]
    manifest = jfrog(f"{root}/{path}")
    if manifest and "manifests" in manifest:
        child = next((m["digest"] for m in manifest["manifests"]
                      if m.get("platform", {}).get("os") != "unknown"), None)
        if not child:
            return {}
        directory = f"{image}/{child}"
        manifest = jfrog(f"{root}/{directory}/manifest.json")
    config = (manifest or {}).get("config", {}).get("digest")
    if not config:
        return {}
    blob = jfrog(f"{root}/{directory}/{config.replace(':', '__')}")
    return (blob or {}).get("config", {}).get("Labels") or {}


def container_tag_manifest(path):
    """True for the manifest under a tag folder, which is the image as a consumer names it.

    A digest folder holds one architecture, `_uploads` holds staging copies, and everything
    else under an image is a blob. Listing any of them presents storage as if it shipped.
    """
    parts = path.split("/")
    if len(parts) < 2 or parts[-1] not in ("manifest.json", "list.manifest.json"):
        return False
    tag = parts[-2]
    return not tag.startswith("sha256:") and tag != "_uploads"


def primary_artifacts(record):
    """One entry per shipped thing: no signatures, container blobs or per-arch manifests."""
    out = []
    for art in record.get("artifacts", []):
        if art["path"].endswith(COMPANION):
            continue
        # JFrog types OCI-native repositories `oci` and Docker ones `docker`. Both store an
        # image as a manifest plus blobs, so both need collapsing to the image itself.
        if art["package_type"] in ("docker", "oci") and not container_tag_manifest(art["path"]):
            continue
        out.append(art)
    return out


def collect(target, about, as_of=None):
    release_ref = find_release(target)
    labels_root = None

    if release_ref:
        bundle_repo, bundle, project = release_ref
        record = jfrog(f"lifecycle/api/v2/release_bundle/records/{bundle}?project={project}") or {}
        # An empty record would render as a bundle of zero files signed by nobody, which reads
        # as evidence rather than its absence.
        if not record.get("artifacts"):
            sys.exit(f"no release bundle {bundle} in project {project}")
        seal = statement(jfrog(f"artifactory/{bundle_repo}/{bundle}/release-bundle.json.evd")) or {}
        sealed_digests = {s["digest"]["sha256"] for s in seal.get("subject", [])}
        entries = primary_artifacts(record)
    else:
        # Nothing is bundled before its first promotion, so this is a stage, not an error.
        entry, origin_repo = unbundled_artifact(target)
        bundle_repo, bundle = None, None
        project = project_of(origin_repo, entry["checksum"])
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
        listing = jfrog(f"artifactory/api/storage/{bundle_repo}/{bundle}") or {}
        for child in listing.get("children", []):
            if not child["uri"].startswith("/promotion-"):
                continue
            pred = (statement(jfrog(f"artifactory/{bundle_repo}/{bundle}{child['uri']}"))
                    or {}).get("predicate", {})
            promotions.append({
                # UNKNOWN keeps an unreadable attestation visible without counting it as a
                # stage reached. Dropping it silently would hide a promotion that happened.
                "stage": pred.get("target", {}).get("environment") or "UNKNOWN",
                "when": pred.get("timestamp"),
                "by": pred.get("createdBy"),
                "repos": pred.get("target", {}).get("includedRepositoryKeys", []),
                "mutable": pred.get("mutable"),
                "seals": (pred.get("provenance") or [{}])[0].get("digest", {}).get("sha256"),
                "file": child["uri"].lstrip("/"),
            })
        promotions.sort(key=lambda p: p["when"] or "")

    artifacts, source = [], None
    for art in entries:
        props = {p["key"]: p["values"][0] for p in (art.get("properties") or [])}
        sha = art["checksum"]
        public, repos, digest_linked = where_published(
            sha, art["package_type"], version_hint(bundle, art))

        vcs, run, env, vcs_build = None, "", 0, None
        if props.get("build.name") and props.get("build.number"):
            vcs, run, env, vcs_build = build_origin(
                props["build.name"], props["build.number"], project)

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

        published_linked = digest_linked if public else None

        entry = {
            "type": art["package_type"], "path": art["path"], "sha256": sha,
            "public": public, "published_build_linked": published_linked, "repos": repos,
            "build": props.get("build.name"), "number": props.get("build.number"),
            "commit": commit, "commit_from": commit_from,
            "sealed": sha in sealed_digests, "source_repo": repo, "attestation": attestation,
        }
        artifacts.append(entry)

        if commit and not source:
            source = {"repo": repo, "commit": commit, "run": run, "env": env,
                      "build": props.get("build.name"), "vcs_build": vcs_build,
                      "artifact": qualified(entry), "artifact_build": entry["number"],
                      "subject": (vcs or {}).get("message", "").split("\n")[0]}

    pull_request = None
    if source and source["repo"] and source["commit"]:
        found = gh(f'repos/{source["repo"]}/commits/{source["commit"]}/pulls') or []
        if found:
            head = found[0]
            reviews = gh(f'repos/{source["repo"]}/pulls/{head["number"]}/reviews') or []
            approved = [r for r in reviews if r.get("state") == "APPROVED"]
            pull_request = {
                "number": head["number"], "title": head["title"],
                "author": head["user"]["login"], "merged_at": head.get("merged_at"),
                "opened_at": head.get("created_at"),
                "repo": head["base"]["repo"]["full_name"],
                "approvers": sorted({r["user"]["login"] for r in approved}),
                # The first approval each person gave, so the recorded time is the one that
                # cleared the gate rather than a later re-review.
                "approved_at": {r["user"]["login"]: r.get("submitted_at") for r in
                                sorted(approved, key=lambda r: r.get("submitted_at") or "",
                                       reverse=True)},
            }

    types = sorted({a["type"] for a in artifacts})
    attested = sorted({a["type"] for a in artifacts if a["attestation"]})
    stages = [p["stage"] for p in promotions]

    # Residence is the only reading available before a bundle exists. A promotion record is the
    # stronger claim.
    resident = sorted({stage_of_repo(r) for a in artifacts for r in a["repos"]} - {None},
                      key=lambda s: STAGE_ORDER.index(s) if s in STAGE_ORDER else len(STAGE_ORDER))
    evidence = {
        "about": about,
        "as_of": as_of or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
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
            "resident_stages": resident,
            **classify_stages(stages, resident),
            "self_approved": bool(pull_request
                                  and pull_request["author"] in pull_request["approvers"]),
            # An approval from anyone but the author. Absent approvals are not evidence that
            # the author declined to self-approve, so nothing may be inferred from an empty list.
            "independently_approved": bool(pull_request and any(
                a != pull_request["author"] for a in pull_request["approvers"])),
            "unlinked_published": sorted({a["type"] for a in artifacts
                                          if a["public"] and a["published_build_linked"] is False}),
            "any_commit": any(a["commit"] for a in artifacts),
        },
    }
    evidence["duties"] = duties(evidence)
    evidence["verdict"] = verdict(evidence)
    return evidence


# -------------------------------------------------------------------- phrasing
AQL_BY_DIGEST = (
    'curl -sf -H "Authorization: Bearer $JFROG_TOKEN" '
    "-H 'Content-Type: text/plain' \\\n"
    '  -d "items.find({\\"sha256\\":\\"$SHA\\"}).include(\\"repo\\")" \\\n'
    """  "$JF/artifactory/api/search/aql" | jq -r '[.results[].repo] | unique | .[]'""")


def shipped(evidence):
    """The report's artifacts, minus signatures and the container blobs behind a manifest."""
    out = [a for a in evidence["artifacts"]
           if not a["path"].endswith(COMPANION)
           and (a["type"] not in ("docker", "oci") or container_tag_manifest(a["path"]))]
    return out or evidence["artifacts"]


# Companions of the artifact people actually depend on. Walking one as the worked example
# names the wrong subject.
SECONDARY = ("-sources.jar", "-javadoc.jar", "-tests.jar", ".pom", ".module", ".json")


def verify_subject(evidence):
    """The artifact the verify block walks. One shipped thing, never a signature."""
    entries = shipped(evidence)
    if not entries:
        return None
    return min(entries, key=lambda a: (a["path"].endswith(SECONDARY), a["path"]))


def substitution_hint(evidence):
    """How to point the verify block at the release's other artifacts, if it has any.

    A basename is not a usable substitution when several artifacts share one, which every
    multi-image container release does with `list.manifest.json`.
    """
    subject = verify_subject(evidence)
    others = [a for a in shipped(evidence) if a is not subject]
    if not others:
        return None
    paths = list(dict.fromkeys(verify_path(evidence, a) for a in others))
    differ = "artifact differs" if len(others) == 1 else "artifacts differ"
    return (f"The other {len(others)} {differ} only in the path. Substitute "
            + phrase(f"`{path}`" for path in paths[:3])
            + (", and so on" if len(paths) > 3 else "")
            + " in the first command and the rest of the block follows.")


def verify_path(evidence, art):
    """Where to point a reader at these bytes: the furthest they were actually promoted to.

    A repository key outside the `-prod-public` convention, such as `<project>-rpm-prod-local`,
    names no stage, and `most_public` ranks those last. Ranking alone therefore sends a reader
    to the DEV copy of a release that reached PROD. The promotion record names the repository.
    """
    if art["public"]:
        return art["public"]
    targeted = [r for p in reversed(evidence["promotions"]) for r in p.get("repos", [])
                if r in art["repos"]]
    if targeted:
        return f'{targeted[0]}/{art["path"]}'
    return pasteable(art)


def verify_commands(evidence):
    """A pasteable shell session that reaches every record this report cites."""
    art = verify_subject(evidence)
    if not art:
        return 'export JFROG_TOKEN="<a JFrog access token>"'

    release, source = evidence["release"], evidence["source"]
    out = ['export JFROG_TOKEN="<a JFrog access token>"', f"JF={JF_BASE}"]
    if release:
        out.append(f'BUNDLE=artifactory/{release["repo"]}/{release["bundle"]}')
    out += ['get() { curl -sf -H "Authorization: Bearer $JFROG_TOKEN" "$JF/$1"; }', ""]

    out += [f'# The SHA-256 of the {noun(art["type"])} a customer resolves.',
            f'SHA=$(get artifactory/api/storage/{verify_path(evidence, art)} |',
            "      jq -r .checksums.sha256)", 'echo "$SHA"', ""]
    out += ["# Every repository holding those exact bytes.", AQL_BY_DIGEST, ""]

    if release:
        seal = (f'artifactory/api/storage/{release["repo"]}/{release["bundle"]}'
                "/release-bundle.json.evd")
        out += ["# The seal: how many files it names, and whether this one is among them.",
                'get "$BUNDLE/release-bundle.json.evd" | jq -r .payload | base64 -d |',
                "  jq --arg s \"$SHA\" '{files: (.subject | length),",
                "                      names_this_file: ([.subject[].digest.sha256] "
                "| index($s) != null)}'", "",
                "# The digest of the seal itself.",
                f'get "{seal}" | jq -r .checksums.sha256', ""]

    if evidence["promotions"]:
        out += ["# Every promotion: the stage, when, and who authorized it.",
                f'get "lifecycle/api/v2/promotion/records/{release["bundle"]}'
                f'?project={evidence["project"]}" |',
                "  jq '[.promotions[] | {stage: .environment, when: .created, "
                "by: .created_by}]'", ""]
        last = evidence["promotions"][-1]
        if last.get("file"):
            out += [f'# The {last["stage"]} attestation names the seal by that digest, and '
                    "records the move.",
                    f'get "$BUNDLE/{last["file"]}" | jq -r .payload | base64 -d |',
                    "  jq '{by: .predicate.createdBy, target: .predicate.target.environment,",
                    "       repos: .predicate.target.includedRepositoryKeys, "
                    "mutable: .predicate.mutable,",
                    "       seal: .predicate.provenance[0].digest.sha256}'", ""]

    if source and source.get("vcs_build"):
        note = ""
        if source["vcs_build"] != source.get("artifact_build"):
            note = ("\n# The commit sits on the metadata child, not the artifact child the "
                    "property names.")
        out += [f"# The build behind it, and the commit it was built from.{note}",
                f'get "artifactory/api/storage/{source["artifact"]}?properties" |',
                "  jq -c '.properties | {build: .\"build.name\"[0], "
                "number: .\"build.number\"[0]}'",
                f'get "artifactory/api/build/{urllib.parse.quote(source["build"] or "")}/'
                f'{urllib.parse.quote(source["vcs_build"])}?project={evidence["project"]}" |',
                "  jq '{run: .buildInfo.url, revision: .buildInfo.vcs[0].revision}'", ""]

    pr = evidence["pr"]
    if source and source.get("repo") and source.get("commit"):
        out += ["# The pull request that authorized the change, and its reviews.",
                f'gh api repos/{source["repo"]}/commits/{source["commit"]}/pulls \\',
                "  --jq '.[] | \"PR #\\(.number) \\(.title) by \\(.user.login), "
                "merged \\(.merged_at)\"'"]
        if pr:
            out += [f'gh api repos/{pr["repo"]}/pulls/{pr["number"]}/reviews \\',
                    "  --jq 'if length == 0 then \"no reviews\" else "
                    "(.[] | \"\\(.state) by \\(.user.login)\") end'"]
        out.append("")

    if art.get("attestation"):
        out += ["# The GitHub build provenance for these bytes.",
                f'gh api repos/{source["repo"]}/attestations/sha256:$SHA \\',
                "  --jq '.attestations[0].bundle.dsseEnvelope.payload' | base64 -d |",
                "  jq '{predicateType, builder: .predicate.runDetails.builder.id,",
                "       buildType: .predicate.buildDefinition.buildType}'", ""]

    return "\n".join(out).rstrip()


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
    """A record's own timestamp, to the second, or an em space where the record carries none."""
    return (timestamp or "").replace("T", " ")[:19] or "not recorded"


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


def acting_roles(evidence):
    """Every role someone held over this release, in the order the records were made."""
    roles, release, pr = [], evidence["release"], evidence["pr"]
    if pr:
        roles.append(("wrote the change", pr["author"]))
        roles += [("approved the change", a) for a in pr["approvers"]]
    if release and release["created_by"]:
        roles.append(("built and sealed it", release["created_by"]))
    for promotion in evidence["promotions"]:
        # A promotion JFrog could not attribute names nobody, so there is no person to compare.
        if promotion["by"]:
            roles.append((f'promoted it to {promotion["stage"]}', promotion["by"]))
    return roles


def resolve_identities(evidence):
    """Each acting identity mapped to the person behind it, None where that cannot be shown.

    Every address a person holds folds onto one of them, so a promotion recorded against a second
    company address still reads as the same person as the token that built the bytes.

    Also reports whether the directory was readable: an empty one and one missing a single login
    mean different things.
    """
    orgs = {t.group("org") for t in
            (TOKEN_ACTOR.match(who) for _, who in acting_roles(evidence)) if t}
    if evidence["pr"]:
        orgs.add(evidence["pr"]["repo"].split("/")[0])
    directory = {}
    for org in sorted(orgs):
        for login, entry in saml_identities(org).items():
            known = directory.setdefault(login, {"email": entry["email"], "emails": set(),
                                                 "name": entry.get("name")})
            known["emails"] |= entry["emails"]
            known["name"] = known.get("name") or entry.get("name")

    # Alias to canonical, so a comparison stays a string equality rather than a set intersection.
    canonical, named = {}, {}
    for entry in directory.values():
        for address in entry["emails"]:
            canonical[address] = entry["email"]
        named[entry["email"]] = entry.get("name")

    people, names = {}, {}
    for _, who in acting_roles(evidence):
        token = TOKEN_ACTOR.match(who)
        login = token.group("actor") if token else (None if "@" in who else who)
        entry = directory.get(login.lower()) if login else None
        if entry:
            email = entry["email"]
        elif login:
            email = None
        else:
            email = canonical.get(who.lower(), who.lower())
        people[who] = email
        if email:
            names[email] = (entry or {}).get("name") or named.get(email)
    return people, names, bool(directory)


def person_label(email, names):
    """`Phuc Vinh <pvinh@aerospike.com>` where the directory knows a name, the address alone
    where it does not, which is the usual case for bots and ops accounts."""
    name = (names or {}).get(email)
    return f"{name} <{email}>" if name else email


def duties(evidence):
    """Who held which role, and where one person held two that must not be held by one.

    A token and a user account naming the same human read as two identities in the records, so
    every separation claim is made against resolved people, never against identity strings.
    """
    roles = acting_roles(evidence)
    people, names, directory_read = resolve_identities(evidence)
    last = terminal(evidence)
    unresolved = sorted({who for _, who in roles if not people.get(who)})
    resolved = {people[who] for _, who in roles if people.get(who)}
    gated = bool(last and last["stage"] in SEPARATION_STAGES)
    # An identity nobody can name only matters once separation is expected of this release.
    unproven = unresolved if gated else []
    publisher = people.get(last["by"]) if gated else None
    # The terminal promotion is the last record, so everything before it is a prior role.
    earlier = roles[:-1] if last and last["by"] else roles

    pr = evidence["pr"]
    selfies = [a for a in (pr["approvers"] if pr else [])
               if people.get(a) and people[a] == people.get(pr["author"])]
    if pr and pr["approvers"] and len(selfies) == len(pr["approvers"]):
        # A second login is not a second person, so the identity map overrides a login comparison.
        evidence["derived"]["independently_approved"] = False

    # A failure means nobody but the author looked at this. A warning means a second person was
    # in the chain and only depth was lost, so the two must not read alike.
    failures, warnings = [], []
    if last and publisher and len(roles) > 1 and len(resolved) == 1 and not unproven:
        idents = phrase(f"`{w}`" for w in dict.fromkeys(w for _, w in roles))
        failures.append([
            "One person took this from commit to publish",
            f'{person_label(publisher, names)} wrote or built these bytes and authorized their '
            f'{last["stage"]} publish. {len(roles)} records name {idents}, every one the same '
            "person, so nothing here was seen by anybody else."])
    else:
        if selfies:
            failures.append([
                "The author approved their own change",
                f'PR #{pr["number"]} was written by `{pr["author"]}` and approved by '
                f'{phrase(f"`{a}`" for a in selfies)}, who is the same person '
                f'({person_label(people[pr["author"]], names)}).'])
        for role, who in earlier:
            if publisher and people.get(who) == publisher:
                warnings.append([
                    f'The person who {role} also authorized the publish',
                    f'`{who}` and `{last["by"]}` are both '
                    f'{person_label(publisher, names)}. The author is somebody else, so no one '
                    f'shipped their own change, but the {last["stage"]} gate rests on one person.'])
    return {
        "people": people,
        "names": names,
        "directory_read": directory_read,
        "distinct": len(resolved) + len(unresolved),
        "unproven": unproven,
        "violations": failures,
        "warnings": warnings,
        # Only true where every identity resolved and none of them is the publisher twice over.
        "separated": bool(last and publisher and not unproven
                          and all(people.get(w) != publisher for _, w in earlier)),
    }


def duty_rows(evidence):
    duty = evidence.get("duties") or {}
    people, names = duty.get("people", {}), duty.get("names", {})

    def named(identity):
        """The identity as recorded, plus who it turns out to be."""
        person = people.get(identity)
        if not person:
            return f"`{identity}`"
        if identity == person:
            name = names.get(person)
            return f"`{identity}` ({name})" if name else f"`{identity}`"
        return f"`{identity}` ({person_label(person, names)})"

    pr, rows = evidence["pr"], []
    if pr:
        rows.append(["Wrote the change", named(pr["author"]), when(pr.get("opened_at")),
                     "GitHub commit authorship"])
        for approver in pr["approvers"]:
            rows.append(["Approved the change", named(approver),
                         when((pr.get("approved_at") or {}).get(approver)),
                         "GitHub review, required by branch protection"])
    if evidence["release"]:
        rows.append(["Built and sealed", named(evidence["release"]["created_by"]),
                     when(evidence["release"].get("created")),
                     "A short-lived CI OIDC token, with no stored secret"])
    for p in evidence["promotions"][:-1]:
        rows.append([f'Promoted to {p["stage"]}', named(p["by"]), when(p["when"]),
                     "Signed promotion attestation"])
    last = terminal(evidence)
    if last:
        rows.append([f'Authorized the {last["stage"]} publish', named(last["by"]),
                     when(last["when"]), f'Signed {last["stage"]} promotion attestation'])
    return rows


def claim_rows(evidence):
    derived, scope, rows = evidence["derived"], type_scope(evidence), []
    last = terminal(evidence)
    # An unsealed, unpromoted artifact supports none of these claims. Rendering one anyway is
    # the one failure this document cannot afford.
    if last:
        rows.append(["These bytes are the ones a named identity authorized for release",
                     f'The {last["stage"]} promotion attestation names the seal by digest, and '
                     "the seal names this file by SHA-256", scope])
    if evidence["release"]:
        backing = ("A DSSE in-toto statement over all "
                   f'{evidence["release"]["seal"]["subjects"]} digests')
        if evidence["promotions"]:
            backing += ", and promotion records carrying `mutable: false`"
        rows.append(["The contents could not change after sealing", backing, scope])
    if evidence["promotions"]:
        rows.append(["The same bytes moved through every stage reached so far",
                     "The identical SHA-256 is present in each stage repository and is a subject "
                     "of the seal", scope])
        rows.append(["Every stage transition so far has an identity and a timestamp",
                     "One signed promotion attestation per stage", scope])
    if evidence["pr"] and evidence["derived"]["independently_approved"] \
            and evidence["pr"]["merged_at"]:
        pr = evidence["pr"]
        independent = [a for a in pr["approvers"] if a != pr["author"]]
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
    """What should exist at this point and does not.

    Every row has to be false for a release doing everything right at its current position. A
    record a later stage would produce is not missing, it is simply not due, and reporting it
    would fire on every healthy release in the pipeline.
    """
    derived, rows = evidence["derived"], []
    reached = set(derived["stages_reached"])
    # A bundle is cut at the DEV to TEST gate, so nothing in DEV has one yet.
    if not derived["sealed"] and reached - {"DEV"}:
        rows.append(["A release bundle holding these bytes",
                     "That these bytes are fixed and travel as a unit. Nothing has been sealed, "
                     "so there is no seal to name them and no promotion record can refer to "
                     "them. Every custody claim depends on this one."])
    if not derived["any_commit"]:
        rows.append(["A recorded source commit",
                     "That these bytes came from a known revision. No build-info VCS block, image "
                     "label or attestation records one, so nothing ties this release to source."])
    # A candidate can be built from a branch pre-merge, so a PR is only due from STAGE up.
    elif not evidence["pr"] and reached & SEPARATION_STAGES:
        rows.append(["The pull request that authorized the change",
                     "That a review preceded the build. The commit is recorded, but no merged "
                     "pull request was found for it, so no approval can be shown."])
    # Once it has reached a customer the same absence is a failure, reported there instead.
    if derived["skipped_stages"] and not shipped_untested(evidence):
        rows.append([f'A recorded {phrase(derived["skipped_stages"])} transition',
                     f'That this was tested at {phrase(derived["skipped_stages"])}. It reached '
                     f'{phrase(derived["stages_reached"])}, so those gates were passed over.'])
    if evidence["pr"] and not derived["independently_approved"] and reached & SEPARATION_STAGES:
        pr = evidence["pr"]
        rows.append(["An approving review on the authorizing pull request",
                     f'That someone other than `{pr["author"]}` examined this change. PR '
                     f'#{pr["number"]} carries no approval from a second person.'])
    unattributed = [p["stage"] for p in evidence["promotions"] if not p["by"]]
    if unattributed:
        rows.append([f'An identity on the {phrase(unattributed)} promotion',
                     "Who authorized it. The promotion is recorded but names nobody, so that "
                     "transition has no accountable person."])
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
                 "records those stages would produce do not exist.")
    if derived["skipped_stages"]:
        gates = phrase(derived["skipped_stages"])
        text += (f' No promotion record exists for {gates}, below where it has got to, so '
                 f'{"that gate was" if len(derived["skipped_stages"]) == 1 else "those gates were"} '
                 "passed over.")
    if not derived["sealed"]:
        text += (" Nothing has been sealed into a release bundle, so the custody claims below are "
                 "limited to what the build itself recorded.")
    return [("h2", "Where this is"), ("p", text)]


def shipped_untested(evidence):
    """A required gate with no record, on bytes a customer can already pull.

    Below a customer-facing stage this is missing paperwork. At or past one it is the control
    itself: nothing shows these bytes were tested before they were published.
    """
    derived = evidence["derived"]
    if not derived["skipped_stages"] or not set(derived["stages_reached"]) & {"PROD", "INTERNAL"}:
        return []
    gates = phrase(derived["skipped_stages"])
    return [[f'Published to customers with no {gates} record',
             "These bytes sit in a customer-facing repository, and no promotion record exists "
             f'for {gates}. Nothing shows they were tested before they shipped.']]


def failures(evidence):
    """Everything that makes this release a FAIL, worst first."""
    return (evidence.get("duties") or {}).get("violations", []) + shipped_untested(evidence)


def warning_rows(evidence):
    """Thinner than it should be, and not a control failure.

    Only what is genuinely absent or genuinely wrong may reach the verdict as a failure.
    """
    duty = evidence.get("duties") or {}
    rows = list(duty.get("warnings", []))
    unproven = duty.get("unproven") or []
    if unproven:
        who = phrase(f"`{w}`" for w in unproven)
        if duty.get("directory_read"):
            rows.append([
                "Separation of duties could not be judged",
                f'{who} resolves to nobody in the org directory, which is what a bot or an ops '
                "account looks like. The promotion records exist and name it, so nothing here is "
                "missing; what cannot be shown is whether that identity is a different person "
                "from the one who authorized the publish."])
        else:
            rows.append([
                "Separation of duties could not be judged",
                f'The org SAML identity map could not be read, so {who} resolves to nobody. '
                "Reading it needs read:org, which a CI GITHUB_TOKEN does not have. Every "
                "promotion record exists and names an identity; only the step from an identity "
                "to a person is missing, so this report cannot tell one human from two."])
    unlinked = evidence["derived"]["unlinked_published"]
    if unlinked:
        rows.append([
            "The public copy carries no build link",
            f'The {phrase(noun(t) for t in unlinked)} a customer pulls holds only registry '
            "metadata, because promotion retags the manifest. The join to the build still works "
            "from the bundle record and from the immutable timestamped tag, so this costs a step "
            "rather than the evidence."])
    return rows


def verdict(evidence):
    """The call on this release, and the one finding that decided it.

    Missing evidence fails, but a release that has not reached the stages which would produce
    that evidence is ON TRACK rather than passed.
    """
    problems, gaps = failures(evidence), gap_rows(evidence)
    warnings = warning_rows(evidence)
    done = bool(set(evidence["derived"]["stages_reached"]) & {"PROD", "INTERNAL"})
    if problems:
        status, reason, finding = "FAIL", "a control did not happen", problems[0][0]
    elif gaps:
        status, reason, finding = "FAIL", "evidence incomplete", gaps[0][0]
    elif warnings:
        status = "PASS WITH WARNING" if done else "ON TRACK WITH WARNING"
        reason, finding = "the chain is thin", warnings[0][0]
    else:
        status = "PASS" if done else "ON TRACK"
        reason = ("every step left a record" if done else
                  "correct so far, with stages still ahead of it")
        finding = None
    return {"status": status, "reason": reason, "finding": finding,
            "problems": len(problems), "gaps": len(gaps), "warnings": len(warnings),
            "complete": done}


def verdict_block(evidence, problems, gaps):
    """The worst news first, before anything reassuring, and a word for how bad it is."""
    call = evidence.get("verdict") or verdict(evidence)
    warnings = warning_rows(evidence)
    ahead = phrase(evidence["derived"]["pending_stages"])
    if call["status"] == "PASS":
        return ("panel", "info",
                "**PASS.** Every step left a record, every claim below has one behind it, and "
                "no record that should exist is absent.")
    if call["status"] == "ON TRACK":
        return ("panel", "info",
                "**ON TRACK.** Correct so far. Everything the pipeline should have recorded by "
                f'{phrase(evidence["derived"]["stages_reached"]) or "this point"} exists'
                + (f', and {ahead} lie ahead.' if ahead else "."))
    if call["status"].startswith(("PASS", "ON TRACK")):
        lead = ("Nothing here blocks the release." if call["complete"] else
                f'Nothing here is wrong for something with {ahead} still ahead of it.')
        return ("panel", "warning",
                f'**{call["status"]}. {warnings[0][0]}.** {warnings[0][1]} {lead}')
    rows = problems or gaps
    extra = len(rows) - 1
    more = "" if extra < 1 else (
        f' {extra} further {"problem" if problems else "record"} below.' if extra == 1 else
        f' {extra} further {"problems" if problems else "records"} below.')
    trailer = ""
    if problems and gaps:
        trailer = (f' {len(gaps)} record that should exist also does not.' if len(gaps) == 1
                   else f' {len(gaps)} records that should exist also do not.')
    lead = "FAIL" if problems else "FAIL, evidence incomplete"
    return ("panel", "warning", f'**{lead}. {rows[0][0]}.** {rows[0][1]}{more}{trailer}')


def as_of_line(evidence):
    """When this was reported, and the newest record it rests on.

    A release keeps accruing records after it ships, so an evidence document is only true as of
    a moment. Saying which moment, and what the newest record was then, lets a reader tell a
    stale report from a release that never moved again.
    """
    last, release = terminal(evidence), evidence["release"]
    if last and last["when"]:
        newest = f'the {last["stage"]} promotion of {when(last["when"])} UTC'
    elif release and release.get("created"):
        newest = f'the bundle seal of {when(release["created"])} UTC'
    else:
        newest = "the build itself"
    return (f'Reported as of {evidence.get("as_of", "an unrecorded date")}, when the newest '
            f'record behind it was {newest}.')


def document(evidence):
    """The document as blocks, so markdown and Confluence cannot drift apart."""
    release, last = evidence["release"], terminal(evidence)
    problems, gaps = failures(evidence), gap_rows(evidence)
    commit = next((a["commit"] for a in evidence["artifacts"] if a["commit"]), None)
    if release:
        ui = (f'{JF_BASE}/ui/artifactory/release-lifecycle/{release["name"]}/{release["version"]}'
              f'?repoKey={release["repo"]}')
        blocks = [
            verdict_block(evidence, problems, gaps),
            ("p", f'{release["name"]} {release["version"]} shipped as {nouns(evidence)}'
                  + (f' from commit `{commit[:8]}`.' if commit else ", no commit recorded.")
                  + f" {as_of_line(evidence)}"),
            ("h2", "The release"),
            ("p", f'[{release["name"]} {release["version"]}]({ui})'
                  + (f', {evidence["about"]}' if evidence["about"] else "") + "."),
        ]
    else:
        blocks = [
            verdict_block(evidence, problems, gaps),
            ("p", f"{subject(evidence)} has not been sealed into a release bundle, so what "
                  f"follows is what the build recorded about it. {as_of_line(evidence)}"),
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
        bound = ("Each link is bound to the previous one by a value that cannot be edited after "
                 f'the fact. The seal names all {release["seal"]["subjects"]} files by SHA-256, '
                 "so any change to any file breaks the signature.")
        blocks += [
            ("h2", "Why the chain holds"),
            ("p", bound + (
                f' The {last["stage"]} attestation names the seal by its own digest, and covers '
                "every artifact in one action:" if last else
                " No promotion attestation names the seal yet, so the chain stops at the seal.")),
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
        blocks.append(("p", f"Start at any of these artifacts in {where} and the chain walks back "
                            "to the pull request that authorized it, one checkable hash per hop."))
    held = duty_rows(evidence)
    duty = evidence.get("duties") or {}
    if held:
        blocks += [
            ("h2", "Who acted"),
            ("p", f'{duty.get("distinct", len({r[1] for r in held}))} '
                  + ("person appears" if duty.get("distinct") == 1 else "people appear")
                  + " so far, resolved through the org identity map, so a CI token and a user "
                    "account naming one human count once."),
            ("table", ["Role", "Identity", "When (UTC)", "Recorded by"], held),
        ]
    if duty.get("separated"):
        blocks.append(("p", "The publish was authorized by someone who did not write, approve or "
                            "build these bytes."))
    claims = claim_rows(evidence)
    if claims:
        blocks += [
            ("h2", "What we can verify"),
            ("p", "Each claim, the record behind it, and which of the artifacts it holds for."),
            ("table", ["Claim", "Backed by", "Holds for"], claims),
        ]
    else:
        blocks += [
            ("h2", "What we can verify"),
            ("p", "Nothing. Every custody claim needs a seal or a promotion record, and neither "
                  "exists for this artifact."),
        ]
    if problems:
        blocks += [
            ("h2", "INCORRECT"),
            ("table", ["Finding", "What the records show"], problems),
        ]
    if gaps:
        blocks += [
            ("h2", "EVIDENCE MISSING"),
            ("p", "Each record that should exist and does not. A release that did everything "
                  "right has none of these."),
            ("table", ["Missing", "What it would prove"], gaps),
        ]
    if warning_rows(evidence):
        blocks += [
            ("h2", "WARNING"),
            ("p", "Nothing here blocks the release. The control held, a second person is in the "
                  "chain, and nobody shipped their own change. These are the places it is thinner "
                  "than it should be."),
            ("table", ["Observation", "What the records show"], warning_rows(evidence)),
        ]
    blocks += [
        ("h2", "Verify it yourself"),
        ("p", "Every claim above resolves to a request you can make yourself. Reading the build, "
              "seal and promotion records needs an account with read access to the "
              f'`{evidence["project"]}` project. Any step using `gh` needs the GitHub CLI. '
              "Run the block top to bottom, or take any command on its own."),
        ("code", verify_commands(evidence), "bash"),
    ]
    hint = substitution_hint(evidence)
    if hint:
        blocks.append(("p", hint))
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
    parser.add_argument("--as-of", default=None)
    parser.add_argument("--verdict-path", default=None)
    args = parser.parse_args()

    evidence = collect(args.target, args.about, args.as_of)
    if args.verdict_path:
        with open(args.verdict_path, "w", encoding="utf-8") as handle:
            json.dump(evidence["verdict"], handle, indent=2)
            handle.write("\n")
    if args.format == "json":
        print(json.dumps(evidence, indent=2))
    else:
        print(render_markdown(evidence, document(evidence)), end="")


if __name__ == "__main__":
    main()
