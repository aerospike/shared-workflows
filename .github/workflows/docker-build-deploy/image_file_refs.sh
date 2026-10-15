#!/usr/bin/env bash
# Decide which pushed image refs belong in build-info. The mutable version of
# an immutable tag (the timestamp stripped) is included. latest and latest-*
# are left out. Digest refs are never written.
set -euo pipefail

usage() {
    echo "Usage: $0 image-file --digest DIGEST (--tags-csv LIST | -- REF...)" >&2
    echo "       $0 floating-property --image-name NAME --versions-override LIST" >&2
}

tag_portion() {
    local ref=$1
    if [[ $ref == *@* ]]; then
        printf '%s\n' "${ref##*@}"
        return
    fi
    if [[ $ref == */* ]]; then
        printf '%s\n' "${ref##*:}"
        return
    fi
    printf '%s\n' "$ref"
}

is_digest_ref() {
    local ref=$1 portion
    [[ $ref == *@sha256:* ]] && return 0
    portion=$(tag_portion "$ref")
    [[ $portion == sha256:* || $portion == sha256__* ]]
}

is_floating_tag() {
    local portion
    portion=$(tag_portion "$1")
    [[ $portion == latest || $portion == latest-* ]]
}

# 3.3.2_20261007T212412Z -> 3.3.2. Empty when the ref is not an immutable tag.
mutable_tag() {
    local portion=$1
    if [[ $portion =~ ^(.+)_[0-9]{8}T[0-9]{6}Z$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

MODE=${1-}
shift || true

DIGEST=""
TAGS_CSV=""
IMAGE_NAME=""
VERSIONS_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case $1 in
    --digest)
        DIGEST=$2
        shift 2
        ;;
    --tags-csv)
        TAGS_CSV=$2
        shift 2
        ;;
    --image-name)
        IMAGE_NAME=$2
        shift 2
        ;;
    --versions-override)
        VERSIONS_OVERRIDE=$2
        shift 2
        ;;
    --)
        shift
        break
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
done

REFS=()
if [[ -n $TAGS_CSV ]]; then
    IFS=',' read -ra _csv_parts <<<"$TAGS_CSV"
    for _part in "${_csv_parts[@]}"; do
        _part="${_part#"${_part%%[![:space:]]*}"}"
        _part="${_part%"${_part##*[![:space:]]}"}"
        [[ -n $_part ]] && REFS+=("$_part")
    done
    unset _csv_parts _part
fi
if (($# > 0)); then
    REFS+=("$@")
fi

case $MODE in
image-file)
    if [[ -z $DIGEST ]]; then
        echo "image-file requires --digest" >&2
        exit 1
    fi
    if [[ $DIGEST != sha256:* ]]; then
        DIGEST="sha256:${DIGEST}"
    fi
    seen=";"
    emit_ref() {
        local ref=$1
        [[ $seen == *";${ref};"* ]] && return 0
        seen+="${ref};"
        printf '%s\n' "${ref}@${DIGEST}"
    }
    if ((${#REFS[@]} > 0)); then
        for ref in "${REFS[@]}"; do
            is_digest_ref "$ref" && continue
            is_floating_tag "$ref" && continue
            emit_ref "$ref"
            portion=$(tag_portion "$ref")
            mutable=$(mutable_tag "$portion")
            [[ -n $mutable ]] || continue
            if [[ $ref == *:* ]]; then
                emit_ref "${ref%:*}:${mutable}"
            else
                emit_ref "$mutable"
            fi
        done
    fi
    ;;
floating-property)
    # Only the two names promotion can point later. A version tag does not imply them.
    result=""
    IFS=',' read -ra parts <<<"$VERSIONS_OVERRIDE"
    for part in "${parts[@]}"; do
        part="${part#"${part%%[![:space:]]*}"}"
        part="${part%"${part##*[![:space:]]}"}"
        [[ $part == latest || $part == latest-slim ]] || continue
        [[ -n $IMAGE_NAME ]] || continue
        token="${IMAGE_NAME}:${part}"
        [[ ";${result};" == *";${token};"* ]] && continue
        if [[ -z $result ]]; then
            result=$token
        else
            result="${result};${token}"
        fi
    done
    if [[ -n $result ]]; then
        printf '%s\n' "$result"
    fi
    ;;
*)
    usage
    exit 1
    ;;
esac
