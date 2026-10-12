#!/usr/bin/env bash
# Snyk container image security scan for a promoted artifact.
#
#   SNYK_TOKEN=<token> JFROG_TOKEN=<token> ./scan.sh <image[:tag]>
#
# Reports a verdict (PASS/FAIL) and per-severity counts for one container image. Reads only:
# it tests the image and, when asked, records it in the Snyk portal. It never promotes,
# tags, or deletes anything.
#
# Needs snyk, docker, jq, python3, curl. The composite action installs a pinned snyk for you;
# run standalone with a snyk already on PATH.
#
# Configuration comes from the environment (the action maps its inputs onto these):
#   IMAGE                required   image reference to scan, host optional
#   SEVERITY_THRESHOLD   high       low | medium | high | critical
#   FAIL_ON_ISSUES       true       exit non-zero when the verdict is FAIL
#   MONITOR              true       also run `snyk container monitor`
#   PLATFORM             (unset)    e.g. linux/amd64, for a multi-arch tag
#   SARIF_OUTPUT_PATH    (unset)    write SARIF here for code-scanning upload
#   JSON_OUTPUT_PATH     (unset)    keep the raw Snyk JSON here
#   JF_URL               https://aerospike.jfrog.io
#   REGISTRY_USERNAME    (derived)  JFrog docker-login user; defaults to the token subject
#   SNYK_ORG             (unset)    Snyk org id, required only when MONITOR=true
#   TIMEOUT              (unset)    wall-clock cap for the scan (e.g. 10m); on expiry -> TIMEOUT
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${IMAGE:?set IMAGE to the container image to scan}"
SEVERITY_THRESHOLD="${SEVERITY_THRESHOLD:-high}"
FAIL_ON_ISSUES="${FAIL_ON_ISSUES:-true}"
MONITOR="${MONITOR:-true}"
PLATFORM="${PLATFORM-}"
SARIF_OUTPUT_PATH="${SARIF_OUTPUT_PATH-}"
JSON_OUTPUT_PATH="${JSON_OUTPUT_PATH-}"
JF_URL="${JF_URL:-https://aerospike.jfrog.io}"
TIMEOUT="${TIMEOUT-}"
: "${SNYK_TOKEN:?set SNYK_TOKEN to a Snyk API token}"

emit() {
    [[ -n ${GITHUB_OUTPUT-} ]] && echo "$1" >>"$GITHUB_OUTPUT"
    echo "$1"
}
mask() { [[ -n ${GITHUB_ACTIONS-} && -n $1 ]] && echo "::add-mask::$1"; }

registry="${JF_URL#*://}"
registry="${registry%%/*}"
mask "${JFROG_TOKEN-}"

# Log in so Snyk can pull a private image. A JFrog token — JWT or opaque reference — belongs to
# a subject the access API reports; the docker username is that subject's user segment, unless
# the caller set one. Login failure is a warning, not a stop: the image may be public, or the
# runner may already be authenticated (e.g. by setup-jfrog-cli).
jfrog_token="${JFROG_TOKEN-}"
if [[ -n $jfrog_token ]]; then
    user="${REGISTRY_USERNAME-}"
    if [[ -z $user ]]; then
        subject="$(curl -sS -H "Authorization: Bearer $jfrog_token" "$JF_URL/access/api/v1/tokens/me" 2>/dev/null |
            jq -r '.subject // empty' 2>/dev/null || true)"
        # subject looks like jfac@<instance>/users/<username>; fall back to the last path segment.
        if [[ $subject == *"/users/"* ]]; then user="${subject##*/users/}"; else user="${subject##*/}"; fi
    fi
    user="${user:-jfrog}"
    if echo "$jfrog_token" | docker login "$registry" --username "$user" --password-stdin >/dev/null 2>&1; then
        echo "Logged in to $registry as $user"
    else
        echo "::warning::snyk-container-scan: docker login to $registry failed; continuing (image may be public or already authenticated)"
    fi
fi

# Normalise to a fully qualified reference so the scan and the portal record agree.
image="$IMAGE"
[[ $image == *"/"* && $image != "$registry/"* && $image != *.*/* ]] && image="$registry/$image"

# Scan straight from the registry with Snyk's own fetcher rather than the local Docker daemon.
# The daemon path breaks on multi-arch manifests (Docker Desktop's containerd store cannot
# produce the manifest-list child digest Snyk asks for) and depends on local image state we do
# not control. Pointing DOCKER_HOST at a dead socket makes Snyk pull the manifest directly; it
# still reads the registry credentials docker login wrote to ~/.docker/config.json. We scan a
# registry-resident promoted artifact, so a registry pull is exactly right.
export DOCKER_HOST="unix:///nonexistent/snyk-registry-fetch.sock"

echo "Scanning $image (threshold: $SEVERITY_THRESHOLD)"
report="${JSON_OUTPUT_PATH:-$(mktemp)}"
[[ -n $JSON_OUTPUT_PATH ]] && mkdir -p "$(dirname "$JSON_OUTPUT_PATH")"

test_args=(container test "$image" "--severity-threshold=$SEVERITY_THRESHOLD" "--json-file-output=$report")
[[ -n $PLATFORM ]] && test_args+=("--platform=$PLATFORM")
if [[ -n $SARIF_OUTPUT_PATH ]]; then
    mkdir -p "$(dirname "$SARIF_OUTPUT_PATH")"
    test_args+=("--sarif-file-output=$SARIF_OUTPUT_PATH")
fi

# `snyk container test` exits 1 when it finds vulnerabilities at/above the threshold and >=2
# on an operational error. Only the operational error should abort the scan; findings are the
# expected signal and are read from the JSON. summarize.py owns the verdict.
#
# TIMEOUT caps wall-clock so a slow scan degrades instead of hanging the caller. `timeout`
# exits 124 when it fires; that becomes a TIMEOUT verdict, distinct from an operational error.
if [[ -n $TIMEOUT ]]; then
    timeout "$TIMEOUT" snyk "${test_args[@]}"
else
    snyk "${test_args[@]}"
fi
snyk_status=$?
if ((snyk_status == 124)); then
    echo "::warning::snyk-container-scan: scan of $image exceeded TIMEOUT=$TIMEOUT — reporting TIMEOUT"
    emit "verdict=TIMEOUT"
    [[ $FAIL_ON_ISSUES == "true" ]] && exit 1 || exit 0
fi
if ((snyk_status >= 2)) || [[ ! -s $report ]]; then
    echo "::error::snyk-container-scan: snyk container test failed (exit $snyk_status) — no usable report for $image"
    emit "verdict=ERROR"
    exit 1
fi

# A while-read loop, not mapfile, so this runs on bash 3.2 (macOS) as well as 4+.
verdict=""
while IFS= read -r line; do
    emit "$line"
    [[ $line == verdict=* ]] && verdict="${line#verdict=}"
done < <(python3 "$here/summarize.py" "$report" --severity-threshold "$SEVERITY_THRESHOLD")
if [[ -z $verdict ]]; then
    echo "::error::snyk-container-scan: could not summarize the report for $image"
    exit 1
fi
emit "report=$report"
if [[ -n $SARIF_OUTPUT_PATH ]]; then emit "sarif=$SARIF_OUTPUT_PATH"; else emit "sarif="; fi

monitored=""
if [[ $MONITOR == "true" ]]; then
    if [[ -z ${SNYK_ORG-} ]]; then
        echo "::warning::snyk-container-scan: MONITOR=true but SNYK_ORG is unset; skipping portal record"
    else
        project="${image##*/}"
        project="${project%%:*}"
        monitor_out="$(snyk container monitor "$image" "--org=$SNYK_ORG" "--project-name=$project" \
            ${PLATFORM:+--platform="$PLATFORM"} 2>&1 || true)"
        monitored="$(printf '%s' "$monitor_out" | grep -oE 'https?://[^ ]*app.snyk.io[^ ]*' | head -1 || true)"
        if [[ -n $monitored ]]; then
            echo "Monitored: $monitored"
        else
            # Best-effort: a failed portal record must not fail the scan, but say so, since a silent
            # empty output usually means SNYK_ORG or the token's permissions are wrong.
            echo "::warning::snyk-container-scan: monitor recorded no project — check snyk-org and that the token can access it"
        fi
    fi
fi
emit "monitored=$monitored"

echo "Verdict: ${verdict:-UNKNOWN}"
if [[ $FAIL_ON_ISSUES == "true" && $verdict == "FAIL" ]]; then
    echo "::error::snyk-container-scan: $image has findings at or above $SEVERITY_THRESHOLD"
    exit 1
fi
exit 0
