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
def find_release(target):
    path = re.sub(r"^.*?/artifactory/", "", target)
    path = re.sub(r"^api/[^/]+/", "", path)

    if path.startswith("bundle:"):
        spec = path[len("bundle:"):]
        name_version, _, project = spec.partition("@")
        return f"{project}-release-bundles-v2", name_version, project

    if path.startswith("sha256:"):
        sha = path[len("sha256:"):]
    else:
        info = jf(f"artifactory/api/storage/{path}")
        if not info or "checksums" not in info:
            sys.exit(f"no artifact at {path}")
        sha = info["checksums"]["sha256"]

    hits = aql(f'items.find({{"sha256":"{sha}"}}).include("repo","path")')
    found = next((h for h in hits["results"]
                  if h["repo"].endswith("-release-bundles-v2")), None)
    if not found:
        sys.exit(f"{path} is in no release bundle")
    project = found["repo"][: -len("-release-bundles-v2")]
    return found["repo"], "/".join(found["path"].split("/")[:2]), project


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


def image_labels(bundle_repo, bundle, pkg_type, path):
    """OCI labels, which carry a container's origin when the manifest has no build.* properties."""
    root = f"artifactory/{bundle_repo}/{bundle}/artifacts/{pkg_type}"
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
    bundle_repo, bundle, project = find_release(target)
    record = jf(f"lifecycle/api/v2/release_bundle/records/{bundle}?project={project}") or {}
    seal = statement(jf(f"artifactory/{bundle_repo}/{bundle}/release-bundle.json.evd")) or {}
    sealed_digests = {s["digest"]["sha256"] for s in seal.get("subject", [])}

    signatures = {}
    for art in record.get("artifacts", []):
        for ext in COMPANION:
            if art["path"].endswith(ext):
                signatures[ext] = signatures.get(ext, 0) + 1

    promotions = []
    listing = jf(f"artifactory/api/storage/{bundle_repo}/{bundle}") or {}
    for child in listing.get("children", []):
        if not child["uri"].startswith("/promotion-"):
            continue
        pred = (statement(jf(f"artifactory/{bundle_repo}/{bundle}{child['uri']}"))
                or {}).get("predicate", {})
        promotions.append({
            "stage": pred.get("target", {}).get("environment"),
            "when": pred.get("timestamp"),
            "by": pred.get("createdBy"),
            "repos": pred.get("target", {}).get("includedRepositoryKeys", []),
            "mutable": pred.get("mutable"),
            "seals": (pred.get("provenance") or [{}])[0].get("digest", {}).get("sha256"),
        })
    promotions.sort(key=lambda p: p["when"] or "")

    artifacts, source = [], None
    for art in primary_artifacts(record):
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
            labels = image_labels(bundle_repo, bundle, art["package_type"], art["path"])
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
    # INTERNAL and PROD are alternative terminal stages; neither implies the other is missing.
    expected = ["DEV", "TEST", "STAGE"] if "INTERNAL" in stages else ["DEV", "TEST", "STAGE", "PROD"]

    return {
        "about": about,
        "release": {
            "name": bundle.split("/")[0], "version": bundle.split("/")[1], "bundle": bundle,
            "repo": bundle_repo, "project": project, "created": record.get("created"),
            "created_by": record.get("created_by"), "files": record.get("total_artifacts_count"),
            "seal": {"statement": seal.get("_type"), "predicate": seal.get("predicateType"),
                     "subjects": len(seal.get("subject", []))},
        },
        "signatures": signatures, "pr": pull_request, "promotions": promotions,
        "artifacts": artifacts, "source": source,
        "derived": {
            "types": types, "attested_types": attested,
            "unattested_types": [t for t in types if t not in attested],
            "stages": stages, "terminal_stage": stages[-1] if stages else None,
            "missing_stages": [s for s in expected if s not in stages],
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
        rows.append(["Peer review",
                     f'[PR #{pr["number"]}](https://github.com/{pr["repo"]}/pull/{pr["number"]}), '
                     f'written by `{pr["author"]}`, approved by '
                     f'{phrase(f"`{a}`" for a in pr["approvers"])}, merged '
                     f'{when(pr["merged_at"])} UTC as commit `{commit}`', "GitHub"])
    if evidence["source"]:
        src = evidence["source"]
        rows.append(["Build from that commit",
                     f'Build-info records `vcs.revision {src["commit"]}` and '
                     f'[the CI run]({src["run"]}), alongside {src["env"]} captured environment '
                     f"values", "JFrog build-info"])
    detail = (f'including {phrase(f"{n} `{ext}` file" + ("s" if n > 1 else "") for ext, n in sorted(evidence["signatures"].items()))}'
              if evidence["signatures"] else "each addressed by digest")
    rows.append(["Artifacts sealed", f'{release["files"]} files, {detail}', "Stage repositories"])
    rows.append(["Bundle sealed",
                 f'{when(release["created"])} UTC by `{release["created_by"]}`. A DSSE envelope '
                 f'carrying an in-toto Statement v1, naming all {release["seal"]["subjects"]} '
                 f"files by SHA-256", "`release-bundle.json.evd`"])
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
    rows.append(["These bytes are the ones a named identity authorized for release",
                 f'The {last["stage"] if last else "terminal"} promotion attestation names the '
                 "seal by digest, and the seal names this file by SHA-256", scope])
    rows.append(["The contents could not change after sealing",
                 f'A DSSE in-toto statement over all {evidence["release"]["seal"]["subjects"]} '
                 "digests, and promotion records carrying `mutable: false`", scope])
    rows.append(["The same bytes moved through every stage",
                 "The identical SHA-256 is present in each stage repository and is a subject of "
                 "the seal", scope])
    rows.append(["Every stage transition has an identity and a timestamp",
                 "One signed promotion attestation per stage", scope])
    if evidence["pr"]:
        pr = evidence["pr"]
        rows.append(["The change was approved by someone other than its author before merge",
                     f'PR #{pr["number"]}, approved by '
                     f'{phrase(f"`{a}`" for a in pr["approvers"])} against author '
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
                     f'That the {phrase(noun(t) for t in derived["unattested_types"])} were '
                     "produced by our shared CI from a given commit, signed by the build platform "
                     "rather than recorded by the build."])
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
    if derived["missing_stages"]:
        rows.append([f'A recorded {phrase(derived["missing_stages"])} transition',
                     f'That the bundle entered {phrase(derived["missing_stages"])}. This bundle '
                     f'records only {phrase(derived["stages"])}.'])
    return rows


def document(evidence):
    """The document as blocks, so markdown and Confluence cannot drift apart."""
    release, last = evidence["release"], terminal(evidence)
    ui = (f'{JF}/ui/artifactory/release-lifecycle/{release["name"]}/{release["version"]}'
          f'?repoKey={release["repo"]}')
    blocks = [
        ("panel", "info",
         f'{release["name"]} {release["version"]} shipped as {nouns(evidence)} from a single '
         "commit. Because they share one commit, one release bundle and one set of approvals, the "
         "evidence differs only where the pipeline differs."),
        ("h2", "The release"),
        ("p", f'[{release["name"]} {release["version"]}]({ui})'
              + (f', {evidence["about"]}' if evidence["about"] else "")
              + f". One commit produced {nouns(evidence)}, and every step of that path left a "
                "signed record."),
        ("h2", "Release chain of custody"),
        ("table", ["Step", "What the record says", "Where it lives"], custody_rows(evidence)),
        ("h2", "Why the chain holds"),
        ("p", "Each link is bound to the previous one by a value that cannot be edited after the "
              f'fact. The seal names all {release["seal"]["subjects"]} files by SHA-256, so any '
              "change to any file breaks the signature. The "
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
    reached = ("a public repository" if last and any("prod-public" in r for r in last["repos"])
               else f'the {last["stage"].lower() if last else "internal"} registry')
    blocks += [
        ("p", f"An auditor can therefore start at any of these artifacts in {reached} and walk "
              "back to the pull request that authorized it, checking a hash at every hop."),
        ("h2", "Segregation of duties, as recorded"),
        ("p", f'{len({r[1] for r in duty_rows(evidence)})} identities appear in this release, and '
              "the system recorded each one at the moment it acted."),
        ("table", ["Role", "Identity", "Recorded by"], duty_rows(evidence)),
    ]
    if evidence["pr"] and not evidence["derived"]["self_approved"]:
        blocks.append(("p", "The author could not approve their own change, and neither the author "
                            "nor the reviewer authorized the publish."))
    blocks += [
        ("h2", "What the evidence proves"),
        ("p", "Each row is a claim an auditor might make about this release, the record that backs "
              "it, and which of the artifacts it holds for."),
        ("table", ["Claim", "Backed by", "Holds for"], claim_rows(evidence)),
        ("h2", "Verify it yourself"),
        ("p", "One command per artifact, against the public virtual repositories a customer "
              "downloads from. Reading the build, seal and promotion records needs an account with "
              f'read access to the `{release["project"]}` project, and the review and provenance '
              "steps need the GitHub CLI."),
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
    release = evidence["release"]
    out = [f'# {release["name"]} {release["version"]}: release evidence', ""]
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
