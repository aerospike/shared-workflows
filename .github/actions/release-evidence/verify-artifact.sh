#!/usr/bin/env bash
# Walk the evidence chain backwards from any published artifact.
#
#   JFROG_TOKEN=<jfrog token> ./verify-artifact.sh <repo/path | full URL | sha256:HEX>
#
# For a container, point it at the tag's list.manifest.json, whose sha256 is the
# index digest that GitHub attests. Set REPO=owner/name if the artifact carries
# nothing that identifies its source repository.
#
# Needs curl, jq, and gh.
set -uo pipefail

BASE="${JF_BASE:-https://aerospike.jfrog.io}"
TOKEN="${JFROG_TOKEN:-${TOKEN-}}"
: "${TOKEN:?set JFROG_TOKEN to a JFrog access token}"
target="${1:?usage: verify-artifact.sh <repo/path | full URL | sha256:HEX>}"
path="${target#*/artifactory/}"
# Package-type endpoints are what a consumer copies: api/helm/helm/..., api/pypi/pypi/...
[[ $path == api/*/*/* ]] && path="${path#api/*/}"

jf() { curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/$1"; }
aql() { curl -sS -H "Authorization: Bearer $TOKEN" -H "Content-Type: text/plain" \
    -X POST "$BASE/artifactory/api/search/aql" --data "$1"; }
uri() { jq -rn --arg s "$1" '$s|@uri'; }
step() { printf '\n===== %s =====\n' "$1"; }

# ------------------------------------------------------------------- gather
if [[ $path == sha256:* ]]; then
    sha="${path#sha256:}"
    props='{}'
else
    sha=$(jf "artifactory/api/storage/$path" | jq -r '.checksums.sha256 // empty')
    [[ -n $sha ]] || {
        echo "no sha256 for $path" >&2
        exit 1
    }
    props=$(jf "artifactory/api/storage/$path?properties" | jq '.properties // {}')
fi

# Find every physical repo holding these bytes. This resolves a public virtual to the
# locals behind it, and the release bundle repo names the JFrog project.
hits=$(aql "items.find({\"sha256\":\"$sha\"}).include(\"repo\",\"path\",\"name\")")
rb_repo=$(jq -r '[.results[] | select(.repo|endswith("-release-bundles-v2"))][0].repo // empty' <<<"$hits")
rb_path=$(jq -r '[.results[] | select(.repo|endswith("-release-bundles-v2"))][0].path // empty' <<<"$hits")

project="${rb_repo%-release-bundles-v2}"
[[ -z $project ]] && project=$(jq -r '[.results[].repo | select(contains("-"))][0] // ""' <<<"$hits" |
    sed -E 's/-.*//')

bname=$(jq -r '(.["build.name"]   // [])[0] // empty' <<<"$props")
bnum=$(jq -r '(.["build.number"] // [])[0] // empty' <<<"$props")

vcs=''
run=''
if [[ -n $bname && -n $bnum ]]; then
    bi=$(jf "artifactory/api/build/$(uri "$bname")/$(uri "$bnum")?project=$project")
    vcs=$(jq -c '.buildInfo.vcs[0] // empty' <<<"$bi")
    run=$(jq -r '.buildInfo.url // empty' <<<"$bi")
    # A matrix pipeline keeps vcs on a metadata child, reachable through the parent.
    if [[ -z $vcs ]]; then
        pbi=$(jf "artifactory/api/build/$(uri "$bname")/$(uri "${bnum%-artifacts}")?project=$project")
        [[ -z $run ]] && run=$(jq -r '.buildInfo.url // empty' <<<"$pbi")
        child=$(jq -r '[.buildInfo.modules[]?.id | select(contains("-buildinfo-"))][0] // empty' <<<"$pbi")
        [[ -n $child ]] && vcs=$(jf "artifactory/api/build/$(uri "$bname")/$(uri "${child##*/}")?project=$project" |
            jq -c '.buildInfo.vcs[0] // empty')
    fi
fi

# Source repository: the VCS block, else the CI run URL, else an override.
gh_repo="${REPO-}"
[[ -z $gh_repo ]] && gh_repo=$(jq -r 'if (.["vcs.provider"]//[""])[0] == "github"
  then ((.["vcs.org"]//[""])[0] + "/" + (.["vcs.repo"]//[""])[0]) else "" end
  | sub("^/$";"")' <<<"$props")
[[ -z $gh_repo && -n $vcs ]] && gh_repo=$(jq -r '.url // ""' <<<"$vcs" |
    sed -E 's#^https://github.com/##; s#\.git$##')
[[ -z $gh_repo && -n $run ]] && gh_repo=$(sed -E 's#^https://github.com/([^/]+/[^/]+)/.*#\1#' <<<"$run")

# A container carries its own origin in OCI labels, which survives when the
# manifest has no build.* properties.
labels='{}'
if [[ -z $gh_repo && $path == *manifest.json ]]; then
    img="${path%/*/*}"
    dir=$(dirname "$path")
    mf=$(jf "artifactory/$path")
    if jq -e '.manifests' >/dev/null 2>&1 <<<"$mf"; then
        child=$(jq -r '[.manifests[] | select(.platform.os != "unknown")][0].digest // empty' <<<"$mf")
        dir="$img/$child"
        mf=$(jf "artifactory/$dir/manifest.json")
    fi
    cfg=$(jq -r '.config.digest // empty' <<<"$mf")
    [[ -n $cfg ]] && labels=$(jf "artifactory/$dir/${cfg/:/__}" | jq -c '.config.Labels // {}')
    gh_repo=$(jq -r '."org.opencontainers.image.source" // ""' <<<"$labels" |
        sed -E 's#^https://github.com/##')
fi

att=''
[[ -n $gh_repo ]] && att=$(gh api "repos/$gh_repo/attestations/sha256:$sha" 2>/dev/null |
    jq -r '.attestations[0].bundle.dsseEnvelope.payload // empty' | base64 -d 2>/dev/null)

# The commit: the VCS block, else the OCI label, else the attestation.
commit=''
source='nowhere: no VCS block, no image label, no attestation'
[[ -n $vcs ]] && {
    commit=$(jq -r '.revision // ""' <<<"$vcs")
    source='JFrog build-info'
}
[[ -z $commit ]] && commit=$(jq -r '."org.opencontainers.image.revision" // ""' <<<"$labels") &&
    [[ -n $commit ]] && source='OCI image labels, not in build-info'
[[ -z $commit && -n $att ]] && commit=$(jq -r \
    '.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit // ""' <<<"$att") &&
    [[ -n $commit ]] && source='GitHub attestation, not in build-info'

# ------------------------------------------------------------------- report
step "The artifact"
jq -n --arg p "$path" --arg s "$sha" --arg b "${bname-}" --arg n "${bnum-}" --arg r "${gh_repo-}" \
    '{path: $p, sha256: $s, build: $b, number: $n, source_repo: $r}'

step "Every repository holding these exact bytes"
jq -r '[.results[].repo] | unique | .[]' <<<"$hits"

step "The commit it was built from"
jq -n --arg c "${commit-}" --arg r "$run" --argjson v "${vcs:-null}" --arg s "$source" '{
  revision: (if $c == "" then null else $c end),
  message:  (($v.message // "") | split("\n")[0]),
  branch:   ($v.branch // ""),
  run:      $r,
  recorded_in: $s }'

if [[ -n $rb_repo ]]; then
    bundle=$(jq -rn --arg p "$rb_path" '$p | split("/") | .[0:2] | join("/")')
    proj="${rb_repo%-release-bundles-v2}"

    step "The seal, and whether it covers this artifact"
    jf "artifactory/$rb_repo/$bundle/release-bundle.json.evd" |
        jq --arg s "$sha" --arg b "$bundle" '.payload | @base64d | fromjson | {
      bundle:    $b,
      statement: ._type,
      predicate: .predicateType,
      files:     (.subject | length),
      covers_this_artifact: ([.subject[].digest.sha256] | index($s) != null) }'

    step "Promotion history: stage, when, and who authorized it"
    jf "lifecycle/api/v2/promotion/records/$bundle?project=$proj" |
        jq '[.promotions[] | {stage: .environment, when: .created, by: .created_by}]'
else
    step "The release bundle these bytes were sealed into"
    echo '{ "bundle": null, "note": "these bytes are in no release bundle" }'
fi

step "SLSA build provenance"
if [[ -n $att ]]; then
    jq '{predicateType,
       builder:   .predicate.runDetails.builder.id,
       buildType: .predicate.buildDefinition.buildType,
       runner:    .predicate.buildDefinition.internalParameters.github.runner_environment}' <<<"$att"
else
    echo '{ "attestation": null, "note": "no GitHub build provenance for this digest" }'
fi

step "The peer review that authorized the change"
if [[ -n $gh_repo && -n ${commit-} ]]; then
    gh api "repos/$gh_repo/commits/$commit/pulls" 2>/dev/null |
        jq '[.[] | {pr: .number, title: .title, author: .user.login, merged_at: .merged_at}]' ||
        echo '{ "note": "no pull request found for this commit" }'
else
    echo '{ "note": "no commit to look up" }'
fi
