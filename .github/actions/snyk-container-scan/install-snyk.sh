#!/usr/bin/env bash
# Install a pinned, GPG-verified Snyk CLI — a fail-closed trust chain. Any failure exits non-zero
# and the binary is deleted; it never falls back to an unverified or `latest` CLI, and a snyk
# already on PATH is never trusted (that would be an unknown, unverified version).
#
#   0) minimum bake      — refuse a release younger than MIN_AGE_HOURS (verify_cli_age.py)
#   1) signing key       — import Snyk's committed key, assert its fingerprint == the pin
#   2) checksum manifest — download the release's GPG-signed sha256sums, verify the signature
#   3) binary            — download it, assert its sha256 matches the now-trusted manifest
#
# The verified binary dir is appended to GITHUB_PATH so later steps (and scan.sh) use it. Run
# standalone to stage a verified snyk — the path to add is printed at the end.
#
# Configuration comes from the environment (the action maps its inputs onto these):
#   SNYK_CLI_VERSION   (unset)  version override; else SNYK_CLI_DEFAULT_VERSION from snyk-cli.pin
#   MIN_AGE_HOURS      48       refuse a release younger than this many hours; 0 disables the check
#   GITHUB_TOKEN       (unset)  only used to avoid GitHub API rate limits on the age check
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNYK_CLI_VERSION="${SNYK_CLI_VERSION-}"
MIN_AGE_HOURS="${MIN_AGE_HOURS:-48}"

# SNYK_GPG_FINGERPRINT and SNYK_CLI_DEFAULT_VERSION. The fingerprint is the trust anchor; the
# version defaults from the pin but a caller may override it (still verified below).
# shellcheck source=/dev/null
source "$here/snyk-cli.pin"
version="${SNYK_CLI_VERSION:-$SNYK_CLI_DEFAULT_VERSION}"

# 0) Enforce the minimum bake: refuse a release younger than MIN_AGE_HOURS (default 48h), so a
#    freshly published — possibly compromised — CLI is never adopted on day zero. Backstops the
#    pin's bump policy and covers break-glass overrides. On a GitHub API hiccup we warn and
#    proceed rather than block every promotion on an outage; the pinned version is already
#    seceng-reviewed and baked. verify_cli_age.py owns the math.
if ((MIN_AGE_HOURS > 0)); then
    auth=()
    [[ -n ${GITHUB_TOKEN-} ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    set +e
    release_json="$(curl --fail --silent --show-error --location --retry 3 "${auth[@]}" \
        "https://api.github.com/repos/snyk/cli/releases/tags/${version}" 2>/dev/null)"
    age_hours="$(printf '%s' "$release_json" | python3 "$here/verify_cli_age.py" --min-age-hours "$MIN_AGE_HOURS" 2>/dev/null)"
    age_status=$?
    set -e
    case "$age_status" in
    0) echo "Snyk CLI ${version} passed the ${MIN_AGE_HOURS}h bake (${age_hours}h old)" ;;
    2)
        echo "::error title=Snyk CLI too new::${version} was published ${age_hours}h ago (< ${MIN_AGE_HOURS}h minimum bake) — refusing a day-zero release"
        exit 1
        ;;
    *) echo "::warning title=Snyk CLI age unverified::could not resolve the publish time for ${version} from GitHub; proceeding on the seceng-pinned version" ;;
    esac
fi

case "$(uname -m)" in
x86_64) asset=snyk-linux ;;
aarch64 | arm64) asset=snyk-linux-arm64 ;;
*)
    echo "::error::snyk-container-scan: unsupported runner architecture $(uname -m)"
    exit 1
    ;;
esac

work="${RUNNER_TEMP:-/tmp}/snyk-cli"
mkdir -p "$work"
export GNUPGHOME="$work/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

# 1) Import Snyk's committed signing key and assert its fingerprint. This is the whole trust
#    decision: everything downstream is only as trusted as this pinned key.
gpg --batch --quiet --import "$here/snyk-code-signing.asc"
got_fp="$(gpg --batch --with-colons --fingerprint code-signing@snyk.io | awk -F: '/^fpr:/{print $10; exit}')"
if [[ $got_fp != "$SNYK_GPG_FINGERPRINT" ]]; then
    echo "::error title=Snyk signing key mismatch::committed key is ${got_fp}, pinned ${SNYK_GPG_FINGERPRINT} — refusing to proceed"
    exit 1
fi

# 2) Fetch the release's GPG-signed checksums manifest and verify the signature. A bad signature
#    means the manifest was not published by Snyk: fail loudly.
sums="$work/sha256sums.txt.asc"
curl --fail --silent --show-error --location --retry 3 -o "$sums" \
    "https://github.com/snyk/cli/releases/download/${version}/sha256sums.txt.asc"
if ! gpg --batch --verify "$sums" 2>&1 | grep -q 'Good signature'; then
    echo "::error title=Snyk checksums signature invalid::sha256sums.txt.asc for ${version} did not verify against the pinned Snyk key"
    exit 1
fi

# 3) Download the binary and check it against the now-trusted checksum from the manifest.
want="$(gpg --batch --decrypt "$sums" 2>/dev/null | awk -v a="$asset" '$2==a{print $1; exit}')"
if [[ -z $want ]]; then
    echo "::error::snyk-container-scan: no checksum for ${asset} in the signed manifest for ${version}"
    exit 1
fi
curl --fail --silent --show-error --location --retry 3 -o "$work/snyk" \
    "https://static.snyk.io/cli/${version}/${asset}"
got="$(sha256sum "$work/snyk" | awk '{print $1}')"
if [[ $got != "$want" ]]; then
    echo "::error title=Snyk CLI checksum mismatch::${asset} ${version} expected ${want} but got ${got} — refusing to run a binary that does not match the signed manifest"
    rm -f "$work/snyk"
    exit 1
fi
chmod +x "$work/snyk"
[[ -n ${GITHUB_PATH-} ]] && echo "$work" >>"$GITHUB_PATH"
echo "Verified Snyk CLI ${version} against Snyk's signed manifest (key ${SNYK_GPG_FINGERPRINT})"
echo "Installed to ${work} — add it to PATH if running standalone."
