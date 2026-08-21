#!/usr/bin/env bash
# Walk the evidence chain backwards from any published artifact.
#
#   JFROG_TOKEN=<jfrog token> ./verify-artifact.sh <repo/path | full URL | sha256:HEX>
#
# For a container, point it at the tag's list.manifest.json: that index digest is the one
# GitHub attests. Set REPO=owner/name when the artifact identifies no source repository.
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

jfrog() { curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/$1"; }
aql() { curl -sS -H "Authorization: Bearer $TOKEN" -H "Content-Type: text/plain" \
    -X POST "$BASE/artifactory/api/search/aql" --data "$1"; }
urlencode() { jq -rn --arg value "$1" '$value|@uri'; }
step() { printf '\n===== %s =====\n' "$1"; }

if [[ $path == sha256:* ]]; then
    sha="${path#sha256:}"
    props='{}'
else
    sha=$(jfrog "artifactory/api/storage/$path" | jq -r '.checksums.sha256 // empty')
    [[ -n $sha ]] || {
        echo "no sha256 for $path" >&2
        exit 1
    }
    props=$(jfrog "artifactory/api/storage/$path?properties" | jq '.properties // {}')
fi

# Resolves a public virtual to the locals behind it. The release bundle repo names the project.
holding_repos=$(aql "items.find({\"sha256\":\"$sha\"}).include(\"repo\",\"path\",\"name\")")
bundle_repo=$(jq -r '[.results[] | select(.repo|endswith("-release-bundles-v2"))][0].repo // empty' <<<"$holding_repos")
bundle_path=$(jq -r '[.results[] | select(.repo|endswith("-release-bundles-v2"))][0].path // empty' <<<"$holding_repos")

project="${bundle_repo%-release-bundles-v2}"
[[ -z $project ]] && project=$(jq -r '[.results[].repo | select(contains("-"))][0] // ""' <<<"$holding_repos" |
    sed -E 's/-.*//')

build_name=$(jq -r '(.["build.name"]   // [])[0] // empty' <<<"$props")
build_number=$(jq -r '(.["build.number"] // [])[0] // empty' <<<"$props")

vcs=''
run=''
if [[ -n $build_name && -n $build_number ]]; then
    build_info=$(jfrog "artifactory/api/build/$(urlencode "$build_name")/$(urlencode "$build_number")?project=$project")
    vcs=$(jq -c '.buildInfo.vcs[0] // empty' <<<"$build_info")
    run=$(jq -r '.buildInfo.url // empty' <<<"$build_info")
    # A matrix pipeline keeps vcs on a metadata child, reachable through the parent.
    if [[ -z $vcs ]]; then
        parent_build_info=$(jfrog "artifactory/api/build/$(urlencode "$build_name")/$(urlencode "${build_number%-artifacts}")?project=$project")
        [[ -z $run ]] && run=$(jq -r '.buildInfo.url // empty' <<<"$parent_build_info")
        child_build_id=$(jq -r '[.buildInfo.modules[]?.id | select(contains("-buildinfo-"))][0] // empty' <<<"$parent_build_info")
        [[ -n $child_build_id ]] && vcs=$(jfrog "artifactory/api/build/$(urlencode "$build_name")/$(urlencode "${child_build_id##*/}")?project=$project" |
            jq -c '.buildInfo.vcs[0] // empty')
    fi
fi

github_repo="${REPO-}"
[[ -z $github_repo ]] && github_repo=$(jq -r 'if (.["vcs.provider"]//[""])[0] == "github"
  then ((.["vcs.org"]//[""])[0] + "/" + (.["vcs.repo"]//[""])[0]) else "" end
  | sub("^/$";"")' <<<"$props")
[[ -z $github_repo && -n $vcs ]] && github_repo=$(jq -r '.url // ""' <<<"$vcs" |
    sed -E 's#^https://github.com/##; s#\.git$##')
[[ -z $github_repo && -n $run ]] && github_repo=$(sed -E 's#^https://github.com/([^/]+/[^/]+)/.*#\1#' <<<"$run")

# OCI labels carry the origin when a manifest has no build.* properties.
labels='{}'
if [[ -z $github_repo && $path == *manifest.json ]]; then
    image="${path%/*/*}"
    manifest_dir=$(dirname "$path")
    manifest=$(jfrog "artifactory/$path")
    if jq -e '.manifests' >/dev/null 2>&1 <<<"$manifest"; then
        child_build_id=$(jq -r '[.manifests[] | select(.platform.os != "unknown")][0].digest // empty' <<<"$manifest")
        manifest_dir="$image/$child_build_id"
        manifest=$(jfrog "artifactory/$manifest_dir/manifest.json")
    fi
    config_digest=$(jq -r '.config.digest // empty' <<<"$manifest")
    [[ -n $config_digest ]] && labels=$(jfrog "artifactory/$manifest_dir/${config_digest/:/__}" | jq -c '.config.Labels // {}')
    github_repo=$(jq -r '."org.opencontainers.image.source" // ""' <<<"$labels" |
        sed -E 's#^https://github.com/##')
fi

attestation=''
[[ -n $github_repo ]] && attestation=$(gh api "repos/$github_repo/attestations/sha256:$sha" 2>/dev/null |
    jq -r '.attestations[0].bundle.dsseEnvelope.payload // empty' | base64 -d 2>/dev/null)

commit=''
commit_source='nowhere: no VCS block, no image label, no attestation'
[[ -n $vcs ]] && {
    commit=$(jq -r '.revision // ""' <<<"$vcs")
    commit_source='JFrog build-info'
}
[[ -z $commit ]] && commit=$(jq -r '."org.opencontainers.image.revision" // ""' <<<"$labels") &&
    [[ -n $commit ]] && commit_source='OCI image labels, not in build-info'
[[ -z $commit && -n $attestation ]] && commit=$(jq -r \
    '.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit // ""' <<<"$attestation") &&
    [[ -n $commit ]] && commit_source='GitHub attestation, not in build-info'

step "The artifact"
jq -n --arg path "$path" --arg sha "$sha" --arg build "${build_name-}" \
    --arg number "${build_number-}" --arg repo "${github_repo-}" \
    '{path: $path, sha256: $sha, build: $build, number: $number, source_repo: $repo}'

step "Every repository holding these exact bytes"
jq -r '[.results[].repo] | unique | .[]' <<<"$holding_repos"

step "The commit it was built from"
jq -n --arg commit "${commit-}" --arg run "$run" --argjson vcs "${vcs:-null}" \
    --arg recorded_in "$commit_source" '{
  revision: (if $commit == "" then null else $commit end),
  message:  (($vcs.message // "") | split("\n")[0]),
  branch:   ($vcs.branch // ""),
  run:      $run,
  recorded_in: $recorded_in }'

if [[ -n $bundle_repo ]]; then
    bundle=$(jq -rn --arg path "$bundle_path" '$path | split("/") | .[0:2] | join("/")')

    step "The seal, and whether it covers this artifact"
    jfrog "artifactory/$bundle_repo/$bundle/release-bundle.json.evd" |
        jq --arg sha "$sha" --arg bundle "$bundle" '.payload | @base64d | fromjson | {
      bundle:    $bundle,
      statement: ._type,
      predicate: .predicateType,
      files:     (.subject | length),
      covers_this_artifact: ([.subject[].digest.sha256] | index($sha) != null) }'

    step "Promotion history: stage, when, and who authorized it"
    jfrog "lifecycle/api/v2/promotion/records/$bundle?project=$project" |
        jq '[.promotions[] | {stage: .environment, when: .created, by: .created_by}]'
else
    step "The release bundle these bytes were sealed into"
    echo '{ "bundle": null, "note": "these bytes are in no release bundle" }'
fi

step "SLSA build provenance"
if [[ -n $attestation ]]; then
    jq '{predicateType,
       builder:   .predicate.runDetails.builder.id,
       buildType: .predicate.buildDefinition.buildType,
       runner:    .predicate.buildDefinition.internalParameters.github.runner_environment}' <<<"$attestation"
else
    echo '{ "attestation": null, "note": "no GitHub build provenance for this digest" }'
fi

step "The peer review that authorized the change"
if [[ -n $github_repo && -n ${commit-} ]]; then
    gh api "repos/$github_repo/commits/$commit/pulls" 2>/dev/null |
        jq '[.[] | {pr: .number, title: .title, author: .user.login, merged_at: .merged_at}]' ||
        echo '{ "note": "no pull request found for this commit" }'
else
    echo '{ "note": "no commit to look up" }'
fi
