#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

posted=false
if [[ -z ${PAYLOAD_JSON_B64-} ]]; then
    echo "Slack notify skipped: payload_json_b64 is empty."
elif [[ ${DRY_RUN:-false} != "true" && -z ${SLACK_BOT_TOKEN-} ]]; then
    echo "Slack notify skipped: SLACK_BOT_TOKEN is not set."
else
    args=(--payload-b64 "${PAYLOAD_JSON_B64}")
    if [[ ${DRY_RUN:-false} == "true" ]]; then
        args+=(--dry-run)
    fi
    python3 "${SCRIPT_DIR}/slack_post.py" "${args[@]}"
    posted=true
fi

echo "posted=${posted}" >>"${GITHUB_OUTPUT:?}"
